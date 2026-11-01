`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.11.2026 18:34:28
// Design Name: 
// Module Name: systolic_deskew_buffer
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

module systolic_deskew_buffer (
    input  wire         clk,
    input  wire         rst,
    input  wire [407:0] skewed_sums_in, // 8 x 51-bit staggered outputs
    output wire [407:0] aligned_sums_out // 8 x 51-bit time-aligned outputs
);

    // Col 0 exits first, so it waits 7 cycles for Col 7 to finish
    reg signed [50:0] d0 [0:6];
    reg signed [50:0] d1 [0:5];
    reg signed [50:0] d2 [0:4];
    reg signed [50:0] d3 [0:3];
    reg signed [50:0] d4 [0:2];
    reg signed [50:0] d5 [0:1];
    reg signed [50:0] d6 [0:0];

    integer k;
    always @(posedge clk) begin
        if (rst) begin
            for (k = 0; k < 7; k = k + 1) d0[k] <= 51'sd0;
            for (k = 0; k < 6; k = k + 1) d1[k] <= 51'sd0;
            for (k = 0; k < 5; k = k + 1) d2[k] <= 51'sd0;
            for (k = 0; k < 4; k = k + 1) d3[k] <= 51'sd0;
            for (k = 0; k < 3; k = k + 1) d4[k] <= 51'sd0;
            for (k = 0; k < 2; k = k + 1) d5[k] <= 51'sd0;
            d6[0] <= 51'sd0;
        end else begin
            d0[0] <= skewed_sums_in[0*51 +: 51];
            for (k = 1; k < 7; k = k + 1) d0[k] <= d0[k-1];

            d1[0] <= skewed_sums_in[1*51 +: 51];
            for (k = 1; k < 6; k = k + 1) d1[k] <= d1[k-1];

            d2[0] <= skewed_sums_in[2*51 +: 51];
            for (k = 1; k < 5; k = k + 1) d2[k] <= d2[k-1];

            d3[0] <= skewed_sums_in[3*51 +: 51];
            for (k = 1; k < 4; k = k + 1) d3[k] <= d3[k-1];

            d4[0] <= skewed_sums_in[4*51 +: 51];
            for (k = 1; k < 3; k = k + 1) d4[k] <= d4[k-1];

            d5[0] <= skewed_sums_in[5*51 +: 51];
            for (k = 1; k < 2; k = k + 1) d5[k] <= d5[k-1];

            d6[0] <= skewed_sums_in[6*51 +: 51];
        end
    end

    assign aligned_sums_out[0*51 +: 51] = d0[6];
    assign aligned_sums_out[1*51 +: 51] = d1[5];
    assign aligned_sums_out[2*51 +: 51] = d2[4];
    assign aligned_sums_out[3*51 +: 51] = d3[3];
    assign aligned_sums_out[4*51 +: 51] = d4[2];
    assign aligned_sums_out[5*51 +: 51] = d5[1];
    assign aligned_sums_out[6*51 +: 51] = d6[0];
    // Col 7 has 0 delay
    assign aligned_sums_out[7*51 +: 51] = skewed_sums_in[7*51 +: 51];

endmodule