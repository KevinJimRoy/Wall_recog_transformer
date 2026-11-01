`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.11.2026 18:18:41
// Design Name: 
// Module Name: qkv_weight_bias_rom
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



module qkv_weight_bias_rom #(
    parameter W_FILE = "qkv_w.mem",
    parameter B_FILE = "qkv_b.mem"
)(
    input  wire         clk,
    
    // Weight Read Port: 384 words of 128-bit (12 tiles * 4 chunks * 8 rows)
    input  wire [8:0]   w_raddr,
    output reg  [127:0] w_rdata,
    
    // Bias Read Port: 12 words of 128-bit (12 tiles of 8 columns)
    input  wire [3:0]   b_raddr,
    output reg  [127:0] b_rdata
);

    (* ram_style = "block" *) reg [127:0] w_rom [0:383];
    (* ram_style = "block" *) reg [127:0] b_rom [0:11];

    initial begin
        $readmemh(W_FILE, w_rom);
        $readmemh(B_FILE, b_rom);
    end

    always @(posedge clk) begin
        w_rdata <= w_rom[w_raddr];
        b_rdata <= b_rom[b_raddr];
    end

endmodule