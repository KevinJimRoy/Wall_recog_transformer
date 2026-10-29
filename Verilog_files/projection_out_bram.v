`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 27.10.2026 22:13:47
// Design Name: 
// Module Name: projection_out_bram
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

module projection_out_bram #(
    parameter DATA_W = 16,
    parameter DEPTH  = 320 
)(
    input  wire clk,
    

    input  wire   we_a,
    input  wire [8:0]   addr_a,
    input  wire [DATA_W-1:0]    din_a,
    

    input  wire [8:0]  addr_b,
    output reg  [DATA_W-1:0]    dout_b
);

    (* ram_style = "block" *) reg [DATA_W-1:0] ram [0:DEPTH-1];

    always @(posedge clk) begin
        if (we_a) begin
            ram[addr_a] <= din_a;
        end
    end

    always @(posedge clk) begin
        dout_b <= ram[addr_b];
    end

endmodule
