`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.11.2026 23:53:37
// Design Name: 
// Module Name: pv_controller
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

module pv_controller (
    input  wire         clk,
    input  wire         rst,
    input  wire         start_pv,         // Triggered by softmax_done
    
    // Read Interface to Softmax prob_ram (10 rows of 160-bit)
    output reg  [3:0]   prob_row_raddr,   // 0 to 9
    input  wire [159:0] prob_row_rdata,
    
    // Read Interface to V_BRAM (40 words of 128-bit)
    output reg  [5:0]   v_raddr,          // 0 to 39
    input  wire [127:0] v_rdata,
    
    // Interface to Shared 8x8 Systolic Core
    output reg          core_active,      // 1 when PV Controller owns Systolic Core
    output reg          load_weight,
    output reg  [127:0] core_w_in,
    output reg  [127:0] core_x_in,
    input  wire [407:0] core_sums_out,
    
    // Readout Port for Final 10x32 Attention Output (40 words of 128-bit)
    input  wire [5:0]   attn_out_raddr,   // 0 to 39
    output reg  [127:0] attn_out_rdata,
    
    output reg          attn_done
);

    localparam S_IDLE   = 2'd0;
    localparam S_LOAD_V = 2'd1;
    localparam S_STREAM = 2'd2;
    localparam S_NEXT   = 2'd3;

    reg [1:0] state;
    reg [1:0] out_tile; // 0..3 (4 tiles of 8 columns = 32 output features)
    reg       in_chunk; // 0 (Probs cols 0..7, V rows 0..7) or 1 (Probs cols 8..9, V rows 8..9)
    reg [3:0] load_cnt; // 0..8
    reg [4:0] cyc_cnt;  // 0..24
    reg       feed_valid;
    reg       v_zero_mask; // 1 when loading padded rows (rows 10..15 in chunk 1)

    //Combinational mux for core_w_in and core_x_in
    always @(*) begin
        core_w_in = v_zero_mask ? 128'd0 : v_rdata;
        if (!feed_valid) begin
            core_x_in = 128'd0;
        end else if (in_chunk == 1'b0) begin
            core_x_in = prob_row_rdata[127:0]; // Cols 0..7
        end else begin
            core_x_in = {96'd0, prob_row_rdata[159:128]}; // Cols 8..9 + 6 zero cols
        end
    end

    // 51-bit Partial Sum Accumulator (10 rows x 8 cols)
    reg signed [50:0] tile_acc [0:9][0:7];

    // Final 10x32 Attention Output BRAM (40 words of 128-bit)
    (* ram_style = "block" *) reg [127:0] attn_out_ram [0:39];
    reg         attn_we;
    reg [5:0]   attn_waddr;
    reg [127:0] attn_wdata;

    always @(posedge clk) begin
        if (attn_we) attn_out_ram[attn_waddr] <= attn_wdata;
        attn_out_rdata <= attn_out_ram[attn_out_raddr];
    end

    wire [3:0] out_row = cyc_cnt - 5'd15; // Valid 0..9 when cyc_cnt is 15..24

    reg signed [50:0] new_sum    [0:7];
    reg signed [50:0] scaled_sum [0:7];
    reg        [127:0] formatted_out;

    integer c;
    always @(*) begin
        for (c = 0; c < 8; c = c + 1) begin
            new_sum[c]    = ((in_chunk == 1'b0) ? 51'sd0 : tile_acc[out_row][c])
                            + $signed(core_sums_out[c*51 +: 51]);
            scaled_sum[c] = new_sum[c] >>> 12;

            if (scaled_sum[c] > 51'sd32767)
                formatted_out[c*16 +: 16] = 16'h7FFF;
            else if (scaled_sum[c] < -51'sd32768)
                formatted_out[c*16 +: 16] = 16'h8000;
            else
                formatted_out[c*16 +: 16] = scaled_sum[c][15:0];
        end
    end

    wire [3:0] target_v_row = (in_chunk ? 4'd8 : 4'd0) + (4'd6 - load_cnt);

    always @(posedge clk) begin
        if (rst) begin
            state          <= S_IDLE;
            core_active    <= 1'b0;
            out_tile       <= 2'd0;
            in_chunk       <= 1'b0;
            load_cnt       <= 4'd0;
            cyc_cnt        <= 5'd0;
            feed_valid     <= 1'b0;
            v_zero_mask    <= 1'b0;
            load_weight    <= 1'b0;
            prob_row_raddr <= 4'd0;
            v_raddr        <= 6'd0;
            attn_we        <= 1'b0;
            attn_waddr     <= 6'd0;
            attn_wdata     <= 128'd0;
            attn_done      <= 1'b0;
        end else begin
            attn_we   <= 1'b0;
            attn_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start_pv) begin
                        core_active <= 1'b1;
                        out_tile    <= 2'd0;
                        in_chunk    <= 1'b0;
                        load_cnt    <= 4'd0;
                        // Request V Row 7, Tile 0 first so it shifts to bottom row of PEs
                        v_raddr     <= {4'd7, 2'd0};
                        v_zero_mask <= 1'b0;
                        state       <= S_LOAD_V;
                    end
                end

                S_LOAD_V: begin
                    load_weight <= 1'b1;
                    load_cnt    <= load_cnt + 4'd1;

                    if (load_cnt < 4'd7) begin
                        // For in_chunk == 1, rows 10..15 don't exist in V_BRAM (only rows 8..9 exist)
                        if (in_chunk == 1'b1 && target_v_row > 4'd9) begin
                            v_raddr     <= 6'd0;
                            v_zero_mask <= 1'b1;
                        end else begin
                            v_raddr     <= {target_v_row, out_tile};
                            v_zero_mask <= 1'b0;
                        end
                    end else if (load_cnt == 4'd7) begin
                        // Pre-fetch Prob Row 0 for upcoming stream
                        prob_row_raddr <= 4'd0;
                    end else if (load_cnt == 4'd8) begin
                        load_weight    <= 1'b0;
                        feed_valid     <= 1'b1;
                        cyc_cnt        <= 5'd0;
                        prob_row_raddr <= 4'd1; // Pre-fetch Prob Row 1
                        state          <= S_STREAM;
                    end
                end

                S_STREAM: begin
                    cyc_cnt <= cyc_cnt + 5'd1;

                    if (cyc_cnt < 5'd8) begin
                        prob_row_raddr <= cyc_cnt[3:0] + 4'd2;
                    end else if (cyc_cnt == 5'd9) begin
                        feed_valid <= 1'b0;
                    end

                    // Capture aligned outputs 15 cycles later (cyc_cnt = 15..24)
                    if (cyc_cnt >= 5'd15 && cyc_cnt <= 5'd24) begin
                        for (c = 0; c < 8; c = c + 1) begin
                            tile_acc[out_row][c] <= new_sum[c];
                        end

                        if (in_chunk == 1'b1) begin
                            attn_we    <= 1'b1;
                            attn_waddr <= {out_row, out_tile};
                            attn_wdata <= formatted_out;
                        end
                    end

                    if (cyc_cnt == 5'd24) begin
                        state <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    load_cnt <= 4'd0;
                    if (in_chunk == 1'b0) begin
                        in_chunk    <= 1'b1;
                        // For in_chunk = 1, first row loaded is row 15 (which is > 9, so zero-masked)
                        v_raddr     <= 6'd0;
                        v_zero_mask <= 1'b1;
                        state       <= S_LOAD_V;
                    end else begin
                        in_chunk <= 1'b0;
                        if (out_tile < 2'd3) begin
                            out_tile    <= out_tile + 2'd1;
                            v_raddr     <= {4'd7, (out_tile + 2'd1)};
                            v_zero_mask <= 1'b0;
                            state       <= S_LOAD_V;
                        end else begin
                            core_active <= 1'b0;
                            attn_done   <= 1'b1;
                            state       <= S_IDLE;
                        end
                    end
                end
            endcase
        end
    end

endmodule