`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 27.10.2026 21:33:40
// Design Name: 
// Module Name: weights_projection_88_32
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

module weights_projection_88_32 #(
    parameter W_FILE = "in_proj_w.mem"
)(
    input  wire  clk,
    input  wire [8:0]   read_addr,
    output reg  [127:0] read_data
);


    reg [127:0] packed_mem [0:351];
    

    reg [15:0] raw_mem [0:2815]; 

    integer i, j;
    initial begin
        $readmemh(W_FILE, raw_mem);
        for (i = 0; i < 352; i = i + 1) begin
            for (j = 0; j < 8; j = j + 1) begin
                packed_mem[i][j*16 +: 16] = raw_mem[i*8 + j];
            end
        end
    end

    always @(posedge clk) begin
        read_data <= packed_mem[read_addr];
    end
endmodule
