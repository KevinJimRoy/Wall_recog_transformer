`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.11.2026 23:53:37
// Design Name: 
// Module Name: softmax_controller
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

`timescale 1ns / 1ps

module softmax_controller (
    input  wire         clk,
    input  wire         rst,
    input  wire         start_softmax,   // Triggered by qkt_done
    
    // Read Interface to qkt_controller's 10x10 Score RAM
    output reg  [3:0]   score_row_raddr, // 0 to 9
    input  wire [159:0] score_row_rdata,
    
    // Read Interface for Phase 4C (PV Controller) & Testbench
    input  wire [3:0]   prob_row_raddr,  // 0 to 9
    output reg  [159:0] prob_row_rdata,
    
    output reg          softmax_done
);

    localparam S_IDLE = 2'd0;
    localparam S_FEED = 2'd1;
    localparam S_WAIT = 2'd2;

    reg [1:0] state;
    reg [3:0] feed_cnt; // 0 to 10 (accounts for 1-cycle score_ram read latency)
    reg [3:0] out_cnt;  // 0 to 9  (counts valid_out rows from Softmax)

    reg          sm_valid_in;
    wire         sm_valid_out;
    wire [159:0] sm_out;

    // Instantiate Seniors' Softmax with n_inputs = 10 (160-bit bus)
    Softmax #(
        .n_inputs(10)
    ) u_softmax (
        .clk      (clk),
        .rst      (rst),
        .valid_in (sm_valid_in),
        .in       (score_row_rdata),
        .valid_out(sm_valid_out),
        .out      (sm_out)
    );

    // 10x10 Probability RAM (10 rows of 160-bit)
    reg [159:0] prob_ram [0:9];

    always @(posedge clk) begin
        prob_row_rdata <= prob_ram[prob_row_raddr];
    end

    always @(posedge clk) begin
        if (rst) begin
            state           <= S_IDLE;
            score_row_raddr <= 4'd0;
            feed_cnt        <= 4'd0;
            out_cnt         <= 4'd0;
            sm_valid_in     <= 1'b0;
            softmax_done    <= 1'b0;
        end else begin
            softmax_done <= 1'b0;

            // Capture streaming outputs from Softmax pipeline
            if (sm_valid_out) begin
                prob_ram[out_cnt] <= sm_out;
                if (out_cnt == 4'd9) begin
                    softmax_done <= 1'b1;
                    state        <= S_IDLE;
                end else begin
                    out_cnt <= out_cnt + 4'd1;
                end
            end

            case (state)
                S_IDLE: begin
                    sm_valid_in <= 1'b0;
                    if (start_softmax) begin
                        score_row_raddr <= 4'd0; // Request Row 0
                        feed_cnt        <= 4'd0;
                        out_cnt         <= 4'd0;
                        state           <= S_FEED;
                    end
                end

                S_FEED: begin
                    // On feed_cnt = 0..9, score_row_rdata has Row (feed_cnt) ready!
                    sm_valid_in <= 1'b1;
                    feed_cnt    <= feed_cnt + 4'd1;

                    if (feed_cnt < 4'd9) begin
                        score_row_raddr <= feed_cnt + 4'd1;
                    end else begin
                        state <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    sm_valid_in <= 1'b0;
                    // Wait for sm_valid_out to finish writing all 10 rows
                end
            endcase
        end
    end

endmodule