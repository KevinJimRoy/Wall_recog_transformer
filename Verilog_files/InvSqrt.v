`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 03.04.2026 13:12:18
// Design Name: 
// Module Name: InvSqrt
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


module InvSqrt(
    input [15:0] in,
    output reg [15:0] out
    );
    
    reg [15:0] sqrt [0:65535];
    initial
    begin
        $readmemh("inv_sqrt.mem", sqrt);
    end
    integer i;
    always @(*)
    begin
        out<=sqrt[in];
    end
endmodule
