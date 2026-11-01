`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.11.2026 18:34:28
// Design Name: 
// Module Name: systolic_skew_buffer
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



module systolic_skew_buffer (
    input  wire         clk,
    input  wire         rst,
    input  wire [127:0] flat_in,
    output wire [127:0] skewed_out
);

    // Row 0: 0 clock delay
    assign skewed_out[15:0] = flat_in[15:0];

    // Delay registers for Rows 1..7
    reg [15:0] d1 [0:0];
    reg [15:0] d2 [0:1];
    reg [15:0] d3 [0:2];
    reg [15:0] d4 [0:3];
    reg [15:0] d5 [0:4];
    reg [15:0] d6 [0:5];
    reg [15:0] d7 [0:6];

    integer k;
    always @(posedge clk) begin
        if (rst) begin
            d1[0] <= 16'd0;
            for (k = 0; k < 2; k = k + 1) d2[k] <= 16'd0;
            for (k = 0; k < 3; k = k + 1) d3[k] <= 16'd0;
            for (k = 0; k < 4; k = k + 1) d4[k] <= 16'd0;
            for (k = 0; k < 5; k = k + 1) d5[k] <= 16'd0;
            for (k = 0; k < 6; k = k + 1) d6[k] <= 16'd0;
            for (k = 0; k < 7; k = k + 1) d7[k] <= 16'd0;
        end else begin
            d1[0] <= flat_in[31:16];

            d2[0] <= flat_in[47:32];
            d2[1] <= d2[0];

            d3[0] <= flat_in[63:48];
            for (k = 1; k < 3; k = k + 1) d3[k] <= d3[k-1];

            d4[0] <= flat_in[79:64];
            for (k = 1; k < 4; k = k + 1) d4[k] <= d4[k-1];

            d5[0] <= flat_in[95:80];
            for (k = 1; k < 5; k = k + 1) d5[k] <= d5[k-1];

            d6[0] <= flat_in[111:96];
            for (k = 1; k < 6; k = k + 1) d6[k] <= d6[k-1];

            d7[0] <= flat_in[127:112];
            for (k = 1; k < 7; k = k + 1) d7[k] <= d7[k-1];
        end
    end

    assign skewed_out[31:16]   = d1[0];
    assign skewed_out[47:32]   = d2[1];
    assign skewed_out[63:48]   = d3[2];
    assign skewed_out[79:64]   = d4[3];
    assign skewed_out[95:80]   = d5[4];
    assign skewed_out[111:96]  = d6[5];
    assign skewed_out[127:112] = d7[6];

endmodule