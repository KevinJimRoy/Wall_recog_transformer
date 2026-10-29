`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 27.10.2026 16:31:21
// Design Name: 
// Module Name: input_buffer
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

module input_buffer #(
    parameter DATA_W = 16
)(
    input  wire                 clk,
    input  wire                 rst,
    
    input  wire                 valid_in,
    input  wire [DATA_W-1:0]    radar_input,
    
    input  wire [6:0]           read_addr,  
    output reg  [127:0]         read_data,

    output reg                  row_ready
);


    (* ram_style = "block" *) reg [127:0] bram [0:109];

    reg [127:0] shift_reg;
    reg [2:0]   pack_cnt; // 0 to 7
    reg [6:0]   wr_addr;  // 0 to 109


    always @(posedge clk) begin
        read_data <= bram[read_addr];
    end


    always @(posedge clk) begin
        if (rst) begin
            pack_cnt  <= 0;
            wr_addr   <= 0;
            row_ready <= 0;
            shift_reg <= 0;
        end else begin
            row_ready <= 0;
            if (valid_in) begin

                shift_reg[pack_cnt*DATA_W +: DATA_W] <= radar_input;
                
                if (pack_cnt == 7) begin
    
                    bram[wr_addr] <= {radar_input, shift_reg[111:0]};
                    pack_cnt <= 0;
                    
                    if (wr_addr == 109)
                        wr_addr <= 0; 
                    else
                        wr_addr <= wr_addr + 1;
                        

                    if ((wr_addr % 11) == 10) begin
                        row_ready <= 1;
                    end
                end else begin
                    pack_cnt <= pack_cnt + 1;
                end
            end
        end
    end
endmodule