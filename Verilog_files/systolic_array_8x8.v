`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.11.2026 18:34:28
// Design Name: 
// Module Name: systolic_array_8x8
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


module systolic_array_8x8 (
    input  wire         clk,
    input  wire         rst,
    input  wire         load_weight,
    
    // Top Edge: 8 Weights (128 bits)
    input  wire [127:0] weights_in_top,
    
    // Left Edge: 8 Skewed Features (128 bits)
    input  wire [127:0] x_in_left,
    
    // Bottom Edge: 8 Skewed 51-bit Partial Sums (408 bits)
    output wire [407:0] sums_out_bottom
);

    wire signed [15:0] w_wire [0:8][0:7];
    wire signed [50:0] s_wire [0:8][0:7];
    wire signed [15:0] x_wire [0:7][0:8];

    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : EDGE_WIRING
            assign w_wire[0][i] = weights_in_top[i*16 +: 16];
            assign s_wire[0][i] = 51'sd0;
            assign x_wire[i][0] = x_in_left[i*16 +: 16];
            assign sums_out_bottom[i*51 +: 51] = s_wire[8][i];
        end
    endgenerate

    genvar r, c;
    generate
        for (r = 0; r < 8; r = r + 1) begin : ROW
            for (c = 0; c < 8; c = c + 1) begin : COL
                pe_unit u_pe (
                    .clk        (clk),
                    .rst        (rst),
                    .load_weight(load_weight),
                    .weight_in  (w_wire[r][c]),
                    .sum_in     (s_wire[r][c]),
                    .weight_out (w_wire[r+1][c]),
                    .sum_out    (s_wire[r+1][c]),
                    .x_in       (x_wire[r][c]),
                    .x_out      (x_wire[r][c+1])
                );
            end
        end
    endgenerate

endmodule