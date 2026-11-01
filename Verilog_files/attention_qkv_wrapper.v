`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.11.2026 19:05:59
// Design Name: 
// Module Name: attention_qkv_wrapper
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

module attention_qkv_wrapper #(
    parameter W_FILE = "qkv_w.mem",
    parameter B_FILE = "qkv_b.mem"
)(
    input  wire         clk,
    input  wire         rst,
    
    // Interface to top_projection
    input  wire         proj_layer_done,
    output wire [8:0]   next_layer_raddr,
    input  wire [15:0]  next_layer_rdata,
    
    // Readout Ports for Q, K, V BRAMs (40 chunks of 128-bit each)
    input  wire [5:0]   q_raddr,
    output wire [127:0] q_rdata,
    input  wire [5:0]   k_raddr,
    output wire [127:0] k_rdata,
    input  wire [5:0]   v_raddr,
    output wire [127:0] v_rdata,
    
    output wire         qkv_done
);

    // Bridge <-> Controller wires
    wire         bridge_done;
    wire [5:0]   vec_raddr;
    wire [127:0] vec_rdata;

    // ROM <-> Controller wires
    wire [8:0]   w_raddr;
    wire [127:0] w_rdata;
    wire [3:0]   b_raddr;
    wire [127:0] b_rdata;

    // Controller <-> Systolic Core wires
    wire         load_weight;
    wire [127:0] core_w_in;
    wire [127:0] core_x_in;
    wire [127:0] skewed_x;
    wire [407:0] skewed_sums;
    wire [407:0] aligned_sums;

    // Controller <-> QKV BRAM wires
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

    // 3. Phase 2: Systolic Skew Buffer
    systolic_skew_buffer u_skew (
        .clk       (clk),
        .rst       (rst),
        .flat_in   (core_x_in),
        .skewed_out(skewed_x)
    );

    // 4. Phase 2: 8x8 Systolic Array (instantiates 64 pe_unit blocks)
    systolic_array_8x8 u_array (
        .clk            (clk),
        .rst            (rst),
        .load_weight    (load_weight),
        .weights_in_top (core_w_in),
        .x_in_left      (skewed_x),
        .sums_out_bottom(skewed_sums)
    );

    // 5. Phase 2: Systolic Deskew Buffer
    systolic_deskew_buffer u_deskew (
        .clk             (clk),
        .rst             (rst),
        .skewed_sums_in  (skewed_sums),
        .aligned_sums_out(aligned_sums)
    );

    // 6. Phase 3: QKV Controller FSM
    qkv_controller u_ctrl (
        .clk          (clk),
        .rst          (rst),
        .start_qkv    (bridge_done),
        .vec_raddr    (vec_raddr),
        .vec_rdata    (vec_rdata),
        .w_raddr      (w_raddr),
        .w_rdata      (w_rdata),
        .b_raddr      (b_raddr),
        .b_rdata      (b_rdata),
        .load_weight  (load_weight),
        .core_w_in    (core_w_in),
        .core_x_in    (core_x_in),
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
        .q_raddr(q_raddr),
        .q_rdata(q_rdata),
        .k_raddr(k_raddr),
        .k_rdata(k_rdata),
        .v_raddr(v_raddr),
        .v_rdata(v_rdata)
    );

endmodule