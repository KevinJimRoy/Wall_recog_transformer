`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.11.2026 19:05:59
// Design Name: 
// Module Name: system_top_wrapper
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

module system_top_wrapper #(
    parameter DATA_W = 16,
    parameter Q_FRAC = 12
)(
    input  wire              clk,
    input  wire              rst,
    
    // Serial Radar Input (into top_projection)
    input  wire              valid_in,
    input  wire [DATA_W-1:0] radar_input,
    input  wire              start_layer,
    
    // Readout Ports for Verification
    input  wire [5:0]        tb_q_raddr,
    output wire [127:0]      tb_q_rdata,
    input  wire [5:0]        tb_k_raddr,
    output wire [127:0]      tb_k_rdata,
    input  wire [5:0]        tb_v_raddr,
    output wire [127:0]      tb_v_rdata,
    
    // Status Outputs
    output wire              proj_done,
    output wire              qkv_done
);

    wire [8:0]        bridge_raddr;
    wire [DATA_W-1:0] bridge_rdata;

    // Stage 1: Existing Projection Module (10x88 -> 10x32)
    top_projection #(
        .DATA_W(DATA_W),
        .Q_FRAC(Q_FRAC)
    ) u_top_projection (
        .clk             (clk),
        .rst             (rst),
        .valid_in        (valid_in),
        .radar_input     (radar_input),
        .start_layer     (start_layer),
        .layer_done      (proj_done),
        .next_layer_raddr(bridge_raddr),
        .next_layer_rdata(bridge_rdata)
    );

    // Stage 2: Phase 1-3 Attention QKV Wrapper (10x32 -> Q, K, V)
    attention_qkv_wrapper #(
        .W_FILE("qkv_w.mem"),
        .B_FILE("qkv_b.mem")
    ) u_attention_qkv (
        .clk             (clk),
        .rst             (rst),
        .proj_layer_done (proj_done),
        .next_layer_raddr(bridge_raddr),
        .next_layer_rdata(bridge_rdata),
        .q_raddr         (tb_q_raddr),
        .q_rdata         (tb_q_rdata),
        .k_raddr         (tb_k_raddr),
        .k_rdata         (tb_k_rdata),
        .v_raddr         (tb_v_raddr),
        .v_rdata         (tb_v_rdata),
        .qkv_done        (qkv_done)
    );

endmodule