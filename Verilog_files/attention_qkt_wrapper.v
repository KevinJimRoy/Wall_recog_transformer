`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.11.2026 23:25:00
// Design Name: 
// Module Name: attention_qkt_wrapper
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

module attention_qkt_wrapper #(
    parameter W_FILE = "qkv_w.mem",
    parameter B_FILE = "qkv_b.mem"
)(
    input  wire         clk,
    input  wire         rst,
    
    // Interface to top_projection
    input  wire         proj_layer_done,
    output wire [8:0]   next_layer_raddr,
    input  wire [15:0]  next_layer_rdata,
    
    // Readout Ports for Q, K, V BRAMs (for Testbench verification when QKT is idle)
    input  wire [5:0]   tb_q_raddr,
    output wire [127:0] q_rdata,
    input  wire [5:0]   tb_k_raddr,
    output wire [127:0] k_rdata,
    input  wire [5:0]   tb_v_raddr,
    output wire [127:0] v_rdata,
    
    // Readout Port for 10x10 Scaled Attention Scores (10 rows of 160-bit)
    input  wire [3:0]   score_row_raddr,
    output wire [159:0] score_row_rdata,
    
    output wire         qkv_done,
    output wire         qkt_done
);

    // Bridge <-> QKV Controller wires
    wire         bridge_done;
    wire [5:0]   vec_raddr;
    wire [127:0] vec_rdata;

    // ROM <-> QKV Controller wires
    wire [8:0]   w_raddr;
    wire [127:0] w_rdata;
    wire [3:0]   b_raddr;
    wire [127:0] b_rdata;

    // QKV Controller <-> Systolic Core wires
    wire         qkv_load_weight;
    wire [127:0] qkv_core_w_in;
    wire [127:0] qkv_core_x_in;

    // QKT Controller <-> Systolic Core & BRAM wires
    wire         qkt_core_active;
    wire         qkt_load_weight;
    wire [127:0] qkt_core_w_in;
    wire [127:0] qkt_core_x_in;
    wire [5:0]   qkt_q_raddr;
    wire [5:0]   qkt_k_raddr;

    // Shared Systolic Core Multiplexers
    wire         mux_load_weight = qkt_core_active ? qkt_load_weight : qkv_load_weight;
    wire [127:0] mux_core_w_in   = qkt_core_active ? qkt_core_w_in   : qkv_core_w_in;
    wire [127:0] mux_core_x_in   = qkt_core_active ? qkt_core_x_in   : qkv_core_x_in;

    // Shared Q & K BRAM Read Address Multiplexers (QKT controller when active, else Testbench)
    wire [5:0]   mux_q_raddr     = qkt_core_active ? qkt_q_raddr     : tb_q_raddr;
    wire [5:0]   mux_k_raddr     = qkt_core_active ? qkt_k_raddr     : tb_k_raddr;

    // Internal Systolic Datapath wires
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
    qkv_weight_bias_rom #(
        .W_FILE(W_FILE),
        .B_FILE(B_FILE)
    ) u_rom (
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

    // 6. Phase 3: QKV Controller FSM
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
        .v_raddr(tb_v_raddr),
        .v_rdata(v_rdata)
    );

    // 8. Phase 4A: Q * K^T Controller FSM & Score RAM
    qkt_controller u_qkt_ctrl (
        .clk            (clk),
        .rst            (rst),
        .start_qkt      (qkv_done),      // Automatically starts when QKV finishes!
        .q_raddr        (qkt_q_raddr),
        .q_rdata        (q_rdata),
        .k_raddr        (qkt_k_raddr),
        .k_rdata        (k_rdata),
        .core_active    (qkt_core_active),
        .load_weight    (qkt_load_weight),
        .core_w_in      (qkt_core_w_in),
        .core_x_in      (qkt_core_x_in),
        .core_sums_out  (aligned_sums),
        .score_row_raddr(score_row_raddr),
        .score_row_rdata(score_row_rdata),
        .qkt_done       (qkt_done)
    );

endmodule