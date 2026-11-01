`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.11.2026 18:53:41
// Design Name: 
// Module Name: qkv_controller
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

module qkv_controller (
    input  wire         clk,
    input  wire         rst,
    input  wire         start_qkv,        // Connected to bridge_done
    
    // Interface to proj_to_systolic_bridge
    output reg  [5:0]   vec_raddr,        // 0 to 39
    input  wire [127:0] vec_rdata,
    
    // Interface to qkv_weight_bias_rom
    output reg  [8:0]   w_raddr,          // 0 to 383
    input  wire [127:0] w_rdata,
    output reg  [3:0]   b_raddr,          // 0 to 11
    input  wire [127:0] b_rdata,
    
    // Interface to systolic_core_top
    output reg          load_weight,
    output wire [127:0] core_w_in,
    output wire [127:0] core_x_in,
    input  wire [407:0] core_sums_out,
    
    // Interface to qkv_tensor_brams
    output reg          q_we,
    output reg          k_we,
    output reg          v_we,
    output reg  [5:0]   qkv_waddr,        // 0 to 39
    output reg  [127:0] qkv_wdata,
    
    output reg          qkv_done
);

    localparam S_IDLE   = 2'd0;
    localparam S_LOAD_W = 2'd1;
    localparam S_STREAM = 2'd2;
    localparam S_NEXT   = 2'd3;

    reg [1:0] state;
    reg [3:0] out_tile; // 0..11 (0..3 = Q, 4..7 = K, 8..11 = V)
    reg [1:0] in_chunk; // 0..3  (4 chunks of 8 features = 32 features)
    reg [3:0] load_cnt; // 0..8
    reg [4:0] cyc_cnt;  // 0..25
    reg       feed_valid;

    assign core_w_in = w_rdata;
    assign core_x_in = feed_valid ? vec_rdata : 128'd0;

    // 51-bit Partial Sum Accumulator for 10 rows x 8 cols across the 4 input chunks
    reg signed [50:0] tile_acc [0:9][0:7];

    wire [3:0] out_row = cyc_cnt - 5'd15; // Valid 0..9 when cyc_cnt is 15..24

    // Combinational Accumulation, Bias Addition, Shift (>>> 12), and Saturation
    reg signed [50:0] new_sum    [0:7];
    reg signed [50:0] biased_sum [0:7];
    reg signed [50:0] scaled_sum [0:7];
    reg signed [15:0] bias_val   [0:7];
    reg        [127:0] formatted_word;

    integer c;
    always @(*) begin
        for (c = 0; c < 8; c = c + 1) begin
            bias_val[c]   = b_rdata[c*16 +: 16];
            new_sum[c]    = ((in_chunk == 2'd0) ? 51'sd0 : tile_acc[out_row][c]) 
                            + $signed(core_sums_out[c*51 +: 51]);
            biased_sum[c] = new_sum[c] + ($signed(bias_val[c]) <<< 12);
            scaled_sum[c] = biased_sum[c] >>> 12;

            if (scaled_sum[c] > 51'sd32767)
                formatted_word[c*16 +: 16] = 16'h7FFF;
            else if (scaled_sum[c] < -51'sd32768)
                formatted_word[c*16 +: 16] = 16'h8000;
            else
                formatted_word[c*16 +: 16] = scaled_sum[c][15:0];
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            out_tile    <= 4'd0;
            in_chunk    <= 2'd0;
            load_cnt    <= 4'd0;
            cyc_cnt     <= 5'd0;
            feed_valid  <= 1'b0;
            load_weight <= 1'b0;
            vec_raddr   <= 6'd0;
            w_raddr     <= 9'd0;
            b_raddr     <= 4'd0;
            q_we        <= 1'b0;
            k_we        <= 1'b0;
            v_we        <= 1'b0;
            qkv_waddr   <= 6'd0;
            qkv_wdata   <= 128'd0;
            qkv_done    <= 1'b0;
        end else begin
            q_we     <= 1'b0;
            k_we     <= 1'b0;
            v_we     <= 1'b0;
            qkv_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start_qkv) begin
                        out_tile <= 4'd0;
                        in_chunk <= 2'd0;
                        load_cnt <= 4'd0;
                        b_raddr  <= 4'd0;
                        // Request Weight Row 7 first so it shifts to the bottom of the 8x8 array
                        w_raddr  <= 9'd7;
                        state    <= S_LOAD_W;
                    end
                end

                S_LOAD_W: begin
                    load_weight <= 1'b1; // Hold high for 8 clocks while w_rdata streams in
                    load_cnt    <= load_cnt + 4'd1;

                    if (load_cnt < 4'd7) begin
                        w_raddr <= ((out_tile * 4 + in_chunk) * 8) + (4'd6 - load_cnt);
                    end else if (load_cnt == 4'd7) begin
                        // Pre-fetch Row 0 from Bridge so vec_rdata is ready on cyc_cnt = 0
                        vec_raddr <= {4'd0, in_chunk};
                    end else if (load_cnt == 4'd8) begin
                        // All 8 weight rows are now locked in the PEs!
                        load_weight <= 1'b0;
                        feed_valid  <= 1'b1;
                        cyc_cnt     <= 5'd0;
                        vec_raddr   <= {4'd1, in_chunk}; // Pre-fetch Row 1 for cyc_cnt = 1
                        state       <= S_STREAM;
                    end
                end

                S_STREAM: begin
                    cyc_cnt <= cyc_cnt + 5'd1;

                    // Pre-fetch Rows 2..9 during cyc_cnt 0..7
                    if (cyc_cnt < 5'd8) begin
                        vec_raddr <= {(cyc_cnt[3:0] + 4'd2), in_chunk};
                    end else if (cyc_cnt == 5'd9) begin
                        // After cyc_cnt = 9 (Row 9 fed), switch core_x_in to 0s
                        feed_valid <= 1'b0;
                    end

                    // Capture aligned outputs at cyc_cnt = 15..24 (15 cycles after cyc_cnt = 0..9)
                    if (cyc_cnt >= 5'd15 && cyc_cnt <= 5'd24) begin
                        for (c = 0; c < 8; c = c + 1) begin
                            tile_acc[out_row][c] <= new_sum[c];
                        end

                        if (in_chunk == 2'd3) begin
                            qkv_wdata <= formatted_word;
                            // Address inside Q, K, or V BRAM is (Row * 4) + (out_tile % 4)
                            qkv_waddr <= {out_row, out_tile[1:0]};
                            
                            if (out_tile < 4'd4)       q_we <= 1'b1;
                            else if (out_tile < 4'd8)  k_we <= 1'b1;
                            else                       v_we <= 1'b1;
                        end
                    end

                    if (cyc_cnt == 5'd24) begin
                        state <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    load_cnt <= 4'd0;
                    if (in_chunk < 2'd3) begin
                        in_chunk <= in_chunk + 2'd1;
                        w_raddr  <= ((out_tile * 4 + (in_chunk + 2'd1)) * 8) + 9'd7;
                        state    <= S_LOAD_W;
                    end else begin
                        in_chunk <= 2'd0;
                        if (out_tile < 4'd11) begin
                            out_tile <= out_tile + 4'd1;
                            b_raddr  <= out_tile + 4'd1;
                            w_raddr  <= (((out_tile + 4'd1) * 4) * 8) + 9'd7;
                            state    <= S_LOAD_W;
                        end else begin
                            qkv_done <= 1'b1;
                            state    <= S_IDLE;
                        end
                    end
                end
            endcase
        end
    end

endmodule