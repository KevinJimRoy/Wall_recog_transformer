`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.11.2026 18:53:41
// Design Name: 
// Module Name: qkv_tensor_brams
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

module qkv_tensor_brams (
    input  wire         clk,
    
    // Shared Write Bus from QKV Controller (writes 128-bit chunks, addr 0..39)
    input  wire         q_we,
    input  wire         k_we,
    input  wire         v_we,
    input  wire [5:0]   waddr,   // 0 to 39 (Row * 4 + Tile_within_matrix)
    input  wire [127:0] wdata,
    
    // Independent 128-bit Read Ports for Phase 4 (Q*K^T and Score*V)
    input  wire [5:0]   q_raddr,
    output reg  [127:0] q_rdata,
    
    input  wire [5:0]   k_raddr,
    output reg  [127:0] k_rdata,
    
    input  wire [5:0]   v_raddr,
    output reg  [127:0] v_rdata
);

    (* ram_style = "block" *) reg [127:0] q_ram [0:39];
    (* ram_style = "block" *) reg [127:0] k_ram [0:39];
    (* ram_style = "block" *) reg [127:0] v_ram [0:39];

    always @(posedge clk) begin
        if (q_we) q_ram[waddr] <= wdata;
        if (k_we) k_ram[waddr] <= wdata;
        if (v_we) v_ram[waddr] <= wdata;

        q_rdata <= q_ram[q_raddr];
        k_rdata <= k_ram[k_raddr];
        v_rdata <= v_ram[v_raddr];
    end

endmodule