`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 27.10.2026 21:33:40
// Design Name: 
// Module Name: projection_mac
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

module projection_mac #(
    parameter DATA_W = 16,
    parameter Q_FRAC = 12,
    parameter B_FILE = "in_proj_b.mem",
    parameter P_FILE = "pos_enc.mem"
)(
    input  wire   clk,
    input  wire   rst,
    

    input  wire   start_layer, 
    output reg   layer_done,
    
    output reg  [6:0]    buf_read_addr,
    input  wire [127:0]    buf_read_data,

    output reg  [8:0]   w_read_addr,
    input  wire [127:0]   w_read_data,

    output reg     bram_we,
    output reg  [8:0]   bram_waddr,
    output reg  [DATA_W-1:0]    bram_wdata
);

    reg signed [15:0] bias_mem [0:31];
    reg signed [15:0] pos_enc_mem [0:319];
    
    initial begin
        $readmemh(B_FILE, bias_mem);
        $readmemh(P_FILE, pos_enc_mem);
    end

    reg signed [50:0] acc;


    localparam S_IDLE  = 0;
    localparam S_FETCH = 1; 
    localparam S_MAC   = 2; 
    localparam S_DONE  = 3; 

    reg [1:0] state;
    reg [3:0] chunk_idx; 
    reg [4:0] feat_idx;  
    reg [3:0] row_idx;   
    
    wire signed [15:0] in_arr [0:7];
    wire signed [15:0] w_arr [0:7];
    
    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin
            assign in_arr[g] = buf_read_data[g*16 +: 16];
            assign w_arr[g]  = w_read_data[g*16 +: 16];
        end
    endgenerate

    reg signed [50:0] dot_sum;
    reg signed [50:0] shifted_acc;
    reg signed [50:0] final_val;

    always @(posedge clk) begin
        if (rst) begin
            state         <= S_IDLE;
            bram_we       <= 0;
            layer_done    <= 0;
            buf_read_addr <= 0;
            w_read_addr   <= 0;
            chunk_idx     <= 0;
            feat_idx      <= 0;
            row_idx       <= 0;
            acc           <= 0;
        end else begin
            bram_we    <= 0; 
            layer_done <= 0;
            
            case (state)
                S_IDLE: begin
                    if (start_layer) begin
                        row_idx       <= 0;
                        feat_idx      <= 0;
                        chunk_idx     <= 0;
                        acc           <= 0;
                        buf_read_addr <= 0; 
                        w_read_addr   <= 0; 
                        state         <= S_FETCH;
                    end
                end

                S_FETCH: begin
                    state <= S_MAC;
                end

                S_MAC: begin
                    dot_sum = (in_arr[0] * w_arr[0]) + (in_arr[1] * w_arr[1]) + 
                              (in_arr[2] * w_arr[2]) + (in_arr[3] * w_arr[3]) + 
                              (in_arr[4] * w_arr[4]) + (in_arr[5] * w_arr[5]) + 
                              (in_arr[6] * w_arr[6]) + (in_arr[7] * w_arr[7]);
                    
                    acc <= acc + dot_sum;

                    if (chunk_idx == 10) begin
                        state <= S_DONE; 
                    end else begin
                        chunk_idx     <= chunk_idx + 1;
                        buf_read_addr <= buf_read_addr + 1;
                        w_read_addr   <= w_read_addr + 1;
                        state         <= S_FETCH;
                    end
                end

                S_DONE: begin
                    shifted_acc = (acc + (bias_mem[feat_idx] <<< Q_FRAC)) >>> Q_FRAC;

                    final_val = shifted_acc + $signed(pos_enc_mem[(row_idx * 32) + feat_idx]);

                    if (final_val > 32767)       bram_wdata <= 16'h7FFF;
                    else if (final_val < -32768) bram_wdata <= 16'h8000;
                    else                         bram_wdata <= final_val[15:0];

                    bram_we    <= 1;
                    bram_waddr <= (row_idx * 32) + feat_idx;

                    if (feat_idx == 31) begin
                        if (row_idx == 9) begin
                            layer_done <= 1; 
                            state      <= S_IDLE;
                        end else begin
                            row_idx       <= row_idx + 1;
                            feat_idx      <= 0;
                            chunk_idx     <= 0;
                            acc           <= 0;
                            buf_read_addr <= (row_idx + 1) * 11;
                            w_read_addr   <= 0;
                            state         <= S_FETCH;
                        end
                    end else begin
                        feat_idx      <= feat_idx + 1;
                        chunk_idx     <= 0;
                        acc           <= 0;
                        buf_read_addr <= row_idx * 11;
                        w_read_addr   <= w_read_addr + 1;
                        state         <= S_FETCH;
                    end
                end
            endcase
        end
    end
endmodule