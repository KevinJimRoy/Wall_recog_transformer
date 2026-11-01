`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.11.2026 23:17:49
// Design Name: 
// Module Name: qkt_controller
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
module qkt_controller (
    input  wire         clk,
    input  wire         rst,
    input  wire         start_qkt,        // Triggered by qkv_done!
    
    // Read Interface to Q_BRAM and K_BRAM (from qkv_tensor_brams)
    output reg  [5:0]   q_raddr,          // 0 to 39
    input  wire [127:0] q_rdata,
    output reg  [5:0]   k_raddr,          // 0 to 39
    input  wire [127:0] k_rdata,
    
    // Interface to Shared 8x8 Systolic Core
    output reg           core_active,      // 1 when QKT owns the Systolic Core
    output reg          load_weight,
    output reg  [127:0] core_w_in,
    output wire [127:0] core_x_in,
    input  wire [407:0] core_sums_out,
    
    // Output Read Port for the 10x10 Score Matrix (10 rows of 10x16-bit = 160 bits per row)
    input  wire [3:0]   score_row_raddr,  // 0 to 9 (Timestep row)
    output reg  [159:0] score_row_rdata,  // {Score[r][9], Score[r][8], ..., Score[r][0]}
    
    output reg          qkt_done
);

    localparam S_IDLE    = 3'd0;
    localparam S_FETCH_K = 3'd1; // Read 8 rows of K into 8x8 transpose register
    localparam S_LOAD_KT = 3'd2; // Push transposed K^T into systolic_array_8x8
    localparam S_STREAM  = 3'd3; // Stream 10 rows of Q through systolic_skew_buffer
    localparam S_NEXT    = 3'd4;

    reg [2:0] state;
    reg       out_tile;   // 0 (K cols 0..7) or 1 (K cols 8..9)
    reg [1:0] in_chunk;   // 0..3 (4 chunks of 8 features = 32 features)
    reg [3:0] step_cnt;   // 0..8 counter for K fetch and K^T load
    reg [4:0] cyc_cnt;    // 0..24 counter for Q streaming & 15-cycle drain
    reg       feed_valid;

    assign core_x_in = feed_valid ? q_rdata : 128'd0;

    // -----------------------------------------------------------------
    // 1. 8x8 Hardware Transpose Buffer for K -> K^T
    // -----------------------------------------------------------------
    // k_tile_buf[k_col][feat_in_chunk]
    reg [15:0] k_tile_buf [0:7][0:7];

    // -----------------------------------------------------------------
    // 2. 51-bit Partial Sum Accumulator (10 Q-rows x 8 K-cols)
    // -----------------------------------------------------------------
    reg signed [50:0] tile_acc [0:9][0:7];

    // -----------------------------------------------------------------
    // 3. Final 10x10 Score Memory (10 rows, each row holds ten 16-bit Q4.12 scores)
    // -----------------------------------------------------------------
    reg [159:0] score_ram [0:9];

    always @(posedge clk) begin
        score_row_rdata <= score_ram[score_row_raddr];
    end

    wire [3:0] out_row = cyc_cnt - 5'd15; // Valid 0..9 during cyc_cnt 15..24

    // Combinational Dot-Product Accumulation + 1/sqrt(32) Scaling
    // INV_SQRT_32 in Q4.12 = round(4096 / sqrt(32)) = 724
    localparam signed [50:0] INV_SQRT_32 = 51'sd724;

    reg signed [50:0] new_sum     [0:7];
    reg signed [50:0] dot_q412    [0:7];
    reg signed [50:0] scaled_prod [0:7];
    reg        [127:0] formatted_scores;

    integer c, f;
    always @(*) begin
        for (c = 0; c < 8; c = c + 1) begin
            new_sum[c]     = ((in_chunk == 2'd0) ? 51'sd0 : tile_acc[out_row][c])
                             + $signed(core_sums_out[c*51 +: 51]);
            // Step A: Shift Q8.24 dot product back to Q4.12
            dot_q412[c]    = new_sum[c] >>> 12;
            // Step B: Multiply by 1/sqrt(32) (724 in Q4.12) and shift right by 12
            scaled_prod[c] = (dot_q412[c] * INV_SQRT_32) >>> 12;

            if (scaled_prod[c] > 51'sd32767)
                formatted_scores[c*16 +: 16] = 16'h7FFF;
            else if (scaled_prod[c] < -51'sd32768)
                formatted_scores[c*16 +: 16] = 16'h8000;
            else
                formatted_scores[c*16 +: 16] = scaled_prod[c][15:0];
        end
    end

    wire [3:0] fetch_k_row = (out_tile ? 4'd8 : 4'd0) + step_cnt[2:0];
    wire [3:0] recv_k_col  = step_cnt - 4'd1;

    always @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            core_active <= 1'b0;
            out_tile    <= 1'b0;
            in_chunk    <= 2'd0;
            step_cnt    <= 4'd0;
            cyc_cnt     <= 5'd0;
            feed_valid  <= 1'b0;
            load_weight <= 1'b0;
            q_raddr     <= 6'd0;
            k_raddr     <= 6'd0;
            core_w_in   <= 128'd0;
            qkt_done    <= 1'b0;
        end else begin
            qkt_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start_qkt) begin
                        core_active <= 1'b1;
                        out_tile    <= 1'b0;
                        in_chunk    <= 2'd0;
                        step_cnt    <= 4'd0;
                        // Pre-fetch K Row 0, Chunk 0
                        k_raddr     <= 6'd0;
                        state       <= S_FETCH_K;
                    end
                end

                // Read 8 rows of K from K_BRAM into k_tile_buf[0..7][0..7]
                S_FETCH_K: begin
                    step_cnt <= step_cnt + 4'd1;

                    // Request next K row (for Tile 1, rows 10..15 don't exist, so clamp address)
                    if (step_cnt < 4'd7) begin
                        if ((out_tile == 1'b0) || (step_cnt < 4'd1))
                            k_raddr <= {((out_tile ? 4'd8 : 4'd0) + step_cnt[3:0] + 4'd1), in_chunk};
                        else
                            k_raddr <= 6'd0;
                    end

                    // Capture arriving k_rdata (1 cycle after k_raddr)
                    if (step_cnt >= 4'd1 && step_cnt <= 4'd8) begin
                        for (f = 0; f < 8; f = f + 1) begin
                            // For Tile 1, only cols 0 and 1 (K-rows 8 and 9) are valid; pad cols 2..7 with 0
                            if (out_tile == 1'b1 && recv_k_col >= 4'd2)
                                k_tile_buf[recv_k_col[2:0]][f] <= 16'd0;
                            else
                                k_tile_buf[recv_k_col[2:0]][f] <= k_rdata[f*16 +: 16];
                        end
                    end

                    if (step_cnt == 4'd8) begin
                        step_cnt <= 4'd0;
                        state    <= S_LOAD_KT;
                    end
                end

                // Push transposed K^T into top of systolic array (Feature 7 down to Feature 0)
                S_LOAD_KT: begin
                    if (step_cnt < 4'd8) begin
                        load_weight <= 1'b1;
                        step_cnt    <= step_cnt + 4'd1;
                        for (c = 0; c < 8; c = c + 1) begin
                            core_w_in[c*16 +: 16] <= k_tile_buf[c][3'd7 - step_cnt[2:0]];
                        end
                        if (step_cnt == 4'd7) begin
                            // Pre-fetch Q Row 0 for upcoming stream
                            q_raddr <= {4'd0, in_chunk};
                        end
                    end else begin
                        // All 8 transposed rows locked in PEs!
                        load_weight <= 1'b0;
                        feed_valid  <= 1'b1;
                        cyc_cnt     <= 5'd0;
                        q_raddr     <= {4'd1, in_chunk}; // Pre-fetch Q Row 1
                        state       <= S_STREAM;
                    end
                end

                // Stream 10 rows of Q and capture aligned sums 15 cycles later
                S_STREAM: begin
                    cyc_cnt <= cyc_cnt + 5'd1;

                    if (cyc_cnt < 5'd8) begin
                        q_raddr <= {(cyc_cnt[3:0] + 4'd2), in_chunk};
                    end else if (cyc_cnt == 5'd9) begin
                        feed_valid <= 1'b0;
                    end

                    // Aligned sums arrive at cyc_cnt = 15..24
                    if (cyc_cnt >= 5'd15 && cyc_cnt <= 5'd24) begin
                        for (c = 0; c < 8; c = c + 1) begin
                            tile_acc[out_row][c] <= new_sum[c];
                        end

                        // On final feature chunk (in_chunk == 3), save scaled scores to score_ram
                        if (in_chunk == 2'd3) begin
                            if (out_tile == 1'b0) begin
                                // Save cols 0..7 (128 bits)
                                score_ram[out_row][127:0] <= formatted_scores;
                            end else begin
                                // Save cols 8..9 (32 bits)
                                score_ram[out_row][159:128] <= formatted_scores[31:0];
                            end
                        end
                    end

                    if (cyc_cnt == 5'd24) begin
                        state <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    step_cnt <= 4'd0;
                    if (in_chunk < 2'd3) begin
                        in_chunk <= in_chunk + 2'd1;
                        k_raddr  <= {(out_tile ? 4'd8 : 4'd0), (in_chunk + 2'd1)};
                        state    <= S_FETCH_K;
                    end else begin
                        in_chunk <= 2'd0;
                        if (out_tile == 1'b0) begin
                            out_tile <= 1'b1;
                            k_raddr  <= {4'd8, 2'd0};
                            state    <= S_FETCH_K;
                        end else begin
                            core_active <= 1'b0;
                            qkt_done    <= 1'b1;
                            state       <= S_IDLE;
                        end
                    end
                end
            endcase
        end
    end

endmodule
