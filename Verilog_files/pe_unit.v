`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.11.2026 18:34:28
// Design Name: 
// Module Name: pe_unit
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


module pe_unit (
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 load_weight,
    
    // Vertical Ports (Top to Bottom)
    input  wire signed [15:0]   weight_in,
    input  wire signed [50:0]   sum_in,
    output reg  signed [15:0]   weight_out,
    output reg  signed [50:0]   sum_out,
    
    // Horizontal Ports (Left to Right)
    input  wire signed [15:0]   x_in,
    output reg  signed [15:0]   x_out
);

    reg  signed [15:0] weight_reg;
    wire signed [31:0] product;

    // 16-bit Q4.12 * 16-bit Q4.12 = 32-bit Q8.24
    assign product = x_in * weight_reg;

    always @(posedge clk) begin
        if (rst) begin
            weight_reg <= 16'sd0;
            weight_out <= 16'sd0;
            sum_out    <= 51'sd0;
            x_out      <= 16'sd0;
        end else if (load_weight) begin
            // Phase A: Shift weights top-to-bottom
            weight_reg <= weight_in;
            weight_out <= weight_in;
            sum_out    <= 51'sd0;
            x_out      <= 16'sd0;
        end else begin
            // Phase B: Systolic Multiply-Accumulate
            x_out   <= x_in;
            sum_out <= sum_in + product; // Sign-extended 32-bit added to 51-bit
        end
    end

endmodule
