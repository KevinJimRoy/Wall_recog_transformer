`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 02.11.2026 00:33:51
// Design Name: 
// Module Name: attention_qkv_soft_wrapper
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps

module attention_qkv_soft_wrapper #(
    parameter W_FILE = "qkv_w.mem",
    parameter B_FILE = "qkv_b.mem"
)(
    input  wire         clk,
    input  wire         rst,
    
    // Interface to top_projection
    input  wire         proj_layer_done,
    output wire [8:0]   next_layer_raddr,
    input  wire [15:0]  next_layer_rdata,
    
    // Readout Ports for Q, K, V BRAMs
    input  wire [5:0]   tb_q_raddr,
    output wire [127:0] q_rdata,
    input  wire [5:0]   tb_k_raddr,
    output wire [127:0] k_rdata,
    input  wire [5:0]   tb_v_raddr,
    output wire [127:0] v_rdata,
    
    // Readout Port for 10x10 Scaled Attention Scores (Phase 4A)
    input  wire [3:0]   tb_score_raddr,
    output wire [159:0] score_row_rdata,
    
    // Readout Port for 10x10 Softmax Probabilities (Phase 4B)
    input  wire [3:0]   tb_prob_raddr,
    output wire [159:0] prob_row_rdata,
    
    // Readout Port for Final 10x32 Attention Context Output (Phase 4C)
    input  wire [5:0]   tb_attn_raddr,
    output wire [127:0] attn_out_rdata,
    
    output wire         qkv_done,
    output wire         qkt_done,
    output wire         softmax_done,
    output wire         attn_done
);

    // Phase 1 Bridge & ROM wires
    wire         bridge_done;
    wire [5:0]   vec_raddr;
    wire [127:0] vec_rdata;
    wire [8:0]   w_raddr;
    wire [127:0] w_rdata;
    wire [3:0]   b_raddr;
    wire [127:0] b_rdata;

    // Phase 3 (QKV), Phase 4A (QKT), and Phase 4C (PV) Systolic Core control wires
    wire         qkv_load_weight, qkt_load_weight, pv_load_weight;
    wire [127:0] qkv_core_w_in,   qkt_core_w_in,   pv_core_w_in;
    wire [127:0] qkv_core_x_in,   qkt_core_x_in,   pv_core_x_in;
    wire         qkt_core_active, pv_core_active;

    // 3-Way Multiplexer for the Shared 8x8 Systolic Core
    wire         mux_load_weight = pv_core_active  ? pv_load_weight  :
                                   qkt_core_active ? qkt_load_weight : qkv_load_weight;
    wire [127:0] mux_core_w_in   = pv_core_active  ? pv_core_w_in    :
                                   qkt_core_active ? qkt_core_w_in   : qkv_core_w_in;
    wire [127:0] mux_core_x_in   = pv_core_active  ? pv_core_x_in    :
                                   qkt_core_active ? qkt_core_x_in   : qkv_core_x_in;

    // BRAM Read Address Multiplexers (Internal controllers when active, else Testbench)
    wire [5:0]   qkt_q_raddr, qkt_k_raddr, pv_v_raddr;
    wire [5:0]   mux_q_raddr = qkt_core_active ? qkt_q_raddr : tb_q_raddr;
    wire [5:0]   mux_k_raddr = qkt_core_active ? qkt_k_raddr : tb_k_raddr;
    wire [5:0]   mux_v_raddr = pv_core_active  ? pv_v_raddr  : tb_v_raddr;

    wire [3:0]   sm_score_raddr;
    wire [3:0]   mux_score_raddr = (qkt_done || !softmax_done) ? sm_score_raddr : tb_score_raddr;
    // Note: Once softmax_done is finished, allow testbench to read score_ram freely:
    reg          sm_active;
    always @(posedge clk) begin
        if (rst)               sm_active <= 1'b0;
        else if (qkt_done)     sm_active <= 1'b1;
        else if (softmax_done) sm_active <= 1'b0;
    end
    wire [3:0]   final_score_raddr = sm_active ? sm_score_raddr : tb_score_raddr;

    wire [3:0]   pv_prob_raddr;
    wire [3:0]   final_prob_raddr  = pv_core_active ? pv_prob_raddr : tb_prob_raddr;

    // Systolic Core Datapath wires
    wire [127:0] skewed_x;
    wire [407:0] skewed_sums;
    wire [407:0] aligned_sums;

    // QKV BRAM Write wires
    wire         q_we, k_we, v_we;
    wire [5:0]   qkv_waddr;
    wire [127:0] qkv_wdata;

    // 1. Phase 1: 16-to-128 Bit Bridge
    proj_to_systolic_bridge u_bridge (
        .clk             (clk),
        .rst             (rst),
        .proj_layer_done (proj_layer_done),
        .next_layer_raddr(next_layer_raddr),
        .next_layer_rdata(next_layer_rdata),
        .bridge_done     (bridge_done),
        .vec_raddr       (vec_raddr),
        .vec_rdata       (vec_rdata)
    );

    // 2. Phase 1: QKV Weight & Bias ROM
    qkv_weight_bias_rom #(.W_FILE(W_FILE), .B_FILE(B_FILE)) u_rom (
        .clk    (clk),
        .w_raddr(w_raddr),
        .w_rdata(w_rdata),
        .b_raddr(b_raddr),
        .b_rdata(b_rdata)
    );

    // 3. Phase 2: Shared Systolic Skew Buffer
    systolic_skew_buffer u_skew (
        .clk       (clk),
        .rst       (rst),
        .flat_in   (mux_core_x_in),
        .skewed_out(skewed_x)
    );

    // 4. Phase 2: Shared 8x8 Systolic Array
    systolic_array_8x8 u_array (
        .clk            (clk),
        .rst            (rst),
        .load_weight    (mux_load_weight),
        .weights_in_top (mux_core_w_in),
        .x_in_left      (skewed_x),
        .sums_out_bottom(skewed_sums)
    );

    // 5. Phase 2: Shared Systolic Deskew Buffer
    systolic_deskew_buffer u_deskew (
        .clk             (clk),
        .rst             (rst),
        .skewed_sums_in  (skewed_sums),
        .aligned_sums_out(aligned_sums)
    );

    // 6. Phase 3: QKV Controller
    qkv_controller u_qkv_ctrl (
        .clk          (clk),
        .rst          (rst),
        .start_qkv    (bridge_done),
        .vec_raddr    (vec_raddr),
        .vec_rdata    (vec_rdata),
        .w_raddr      (w_raddr),
        .w_rdata      (w_rdata),
        .b_raddr      (b_raddr),
        .b_rdata      (b_rdata),
        .load_weight  (qkv_load_weight),
        .core_w_in    (qkv_core_w_in),
        .core_x_in    (qkv_core_x_in),
        .core_sums_out(aligned_sums),
        .q_we         (q_we),
        .k_we         (k_we),
        .v_we         (v_we),
        .qkv_waddr    (qkv_waddr),
        .qkv_wdata    (qkv_wdata),
        .qkv_done     (qkv_done)
    );

    // 7. Phase 3: Dedicated Q, K, V BRAMs
    qkv_tensor_brams u_qkv_brams (
        .clk    (clk),
        .q_we   (q_we),
        .k_we   (k_we),
        .v_we   (v_we),
        .waddr  (qkv_waddr),
        .wdata  (qkv_wdata),
        .q_raddr(mux_q_raddr),
        .q_rdata(q_rdata),
        .k_raddr(mux_k_raddr),
        .k_rdata(k_rdata),
        .v_raddr(mux_v_raddr),
        .v_rdata(v_rdata)
    );

    // 8. Phase 4A: Q * K^T Controller
    qkt_controller u_qkt_ctrl (
        .clk            (clk),
        .rst            (rst),
        .start_qkt      (qkv_done),
        .q_raddr        (qkt_q_raddr),
        .q_rdata        (q_rdata),
        .k_raddr        (qkt_k_raddr),
        .k_rdata        (k_rdata),
        .core_active    (qkt_core_active),
        .load_weight    (qkt_load_weight),
        .core_w_in      (qkt_core_w_in),
        .core_x_in      (qkt_core_x_in),
        .core_sums_out  (aligned_sums),
        .score_row_raddr(final_score_raddr),
        .score_row_rdata(score_row_rdata),
        .qkt_done       (qkt_done)
    );

    // 9. Phase 4B: Softmax Controller (Wraps Seniors' Softmax.v, Exp.v, Ln.v)
    softmax_controller u_sm_ctrl (
        .clk            (clk),
        .rst            (rst),
        .start_softmax  (qkt_done),
        .score_row_raddr(sm_score_raddr),
        .score_row_rdata(score_row_rdata),
        .prob_row_raddr (final_prob_raddr),
        .prob_row_rdata (prob_row_rdata),
        .softmax_done   (softmax_done)
    );

    // 10. Phase 4C: Probs * V Context Controller
    pv_controller u_pv_ctrl (
        .clk           (clk),
        .rst           (rst),
        .start_pv      (softmax_done),
        .prob_row_raddr(pv_prob_raddr),
        .prob_row_rdata(prob_row_rdata),
        .v_raddr       (pv_v_raddr),
        .v_rdata       (v_rdata),
        .core_active   (pv_core_active),
        .load_weight   (pv_load_weight),
        .core_w_in     (pv_core_w_in),
        .core_x_in     (pv_core_x_in),
        .core_sums_out (aligned_sums),
        .attn_out_raddr(tb_attn_raddr),
        .attn_out_rdata(attn_out_rdata),
        .attn_done     (attn_done)
    );

endmodule