`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04.11.2026 02:31:30
// Design Name: 
// Module Name: out_proj_res_ln_controller
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

module out_proj_res_ln_controller #(
    parameter WO_FILE   = "out_proj_w.mem",
    parameter BO_FILE   = "out_proj_b.mem",
    parameter LN_W_FILE = "ln1_w.mem",
    parameter LN_B_FILE = "ln1_b.mem"
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         start_out_proj,   // Triggered by attn_done
    
    // Read Interface to Phase 4C Attention Context (attn_out_ram, 40 x 128-bit)
    output reg  [5:0]   attn_raddr,       // 0 to 39
    input  wire [127:0] attn_rdata,
    
    // Read Interface to Phase 1 Bridge (Original X_proj for Residual Add, 40 x 128-bit)
    output reg  [5:0]   res_vec_raddr,    // 0 to 39
    input  wire [127:0] res_vec_rdata,
    
    // Interface to Shared 8x8 Systolic Core
    output reg          core_active,      // 1 when Out_Proj owns the Systolic Core
    output reg          load_weight,
    output wire [127:0] core_w_in,
    output wire [127:0] core_x_in,
    input  wire [407:0] core_sums_out,
    
    // Readout Port for Post-LayerNorm Output (40 chunks of 128-bit, 10x32)
    input  wire [5:0]   ln1_out_raddr,    // 0 to 39
    output reg  [127:0] ln1_out_rdata,
    
    output reg          ln1_done
);

    // 1. W_O (128 lines of 128-bit) and B_O (32 lines of 16-bit) ROMs
    (* ram_style = "block" *) reg [127:0] wo_rom [0:127];
    reg [15:0] bo_rom [0:31];

    initial begin
        $readmemh(WO_FILE, wo_rom);
        $readmemh(BO_FILE, bo_rom);
    end

    reg  [6:0]   wo_raddr;
    reg  [127:0] wo_rdata;
    reg  [1:0]   bo_tile;
    wire [127:0] bo_rdata;

    always @(posedge clk) begin
        wo_rdata <= wo_rom[wo_raddr];
    end

    genvar b_idx;
    generate
        for (b_idx = 0; b_idx < 8; b_idx = b_idx + 1) begin : PACK_BO
            assign bo_rdata[b_idx*16 +: 16] = bo_rom[(bo_tile * 8) + b_idx];
        end
    endgenerate

    localparam S_IDLE    = 3'd0;
    localparam S_LOAD_W  = 3'd1;
    localparam S_STREAM  = 3'd2;
    localparam S_NEXT    = 3'd3;
    localparam S_FEED_LN = 3'd4;
    localparam S_WAIT_LN = 3'd5;

    reg [2:0] state;
    reg [1:0] out_tile; // 0..3 (32 output cols)
    reg [1:0] in_chunk; // 0..3 (32 input cols)
    reg [3:0] load_cnt; // 0..8
    reg [4:0] cyc_cnt;  // 0..24
    reg       feed_valid;

    assign core_w_in = wo_rdata;
    assign core_x_in = feed_valid ? attn_rdata : 128'd0;

    // 51-bit Partial Sum Accumulator (10 rows x 8 cols)
    reg signed [50:0] tile_acc [0:9][0:7];

    // 10 rows of 512-bit (32 features * 16-bit) holding (Context * W_O + B_O) + X_proj
    reg [511:0] res1_ram [0:9];

    wire [3:0] out_row      = cyc_cnt - 5'd15; // Valid 0..9 during cyc_cnt 15..24
    wire [3:0] prefetch_row = cyc_cnt - 5'd13; // Valid 0..9 during cyc_cnt 13..22 (2-cycle BRAM read latency)

    // Combinational Bias + Shift + Residual Add (with Q4.12 saturation)
    reg signed [50:0] new_sum    [0:7];
    reg signed [50:0] biased_sum [0:7];
    reg signed [50:0] proj_q412  [0:7];
    reg signed [50:0] res_sum    [0:7];
    reg signed [15:0] bias_val   [0:7];
    reg signed [15:0] x_res_val  [0:7];
    reg        [127:0] formatted_res;

    integer c;
    always @(*) begin
        for (c = 0; c < 8; c = c + 1) begin
            bias_val[c]   = bo_rdata[c*16 +: 16];
            x_res_val[c]  = res_vec_rdata[c*16 +: 16];
            new_sum[c]    = ((in_chunk == 2'd0) ? 51'sd0 : tile_acc[out_row][c])
                            + $signed(core_sums_out[c*51 +: 51]);
            biased_sum[c] = new_sum[c] + ($signed(bias_val[c]) <<< 12);
            proj_q412[c]  = biased_sum[c] >>> 12;

            if (proj_q412[c] > 51'sd32767)       proj_q412[c] = 51'sd32767;
            else if (proj_q412[c] < -51'sd32768) proj_q412[c] = -51'sd32768;

            res_sum[c] = proj_q412[c] + $signed(x_res_val[c]);

            if (res_sum[c] > 51'sd32767)
                formatted_res[c*16 +: 16] = 16'h7FFF;
            else if (res_sum[c] < -51'sd32768)
                formatted_res[c*16 +: 16] = 16'h8000;
            else
                formatted_res[c*16 +: 16] = res_sum[c][15:0];
        end
    end

    // Instantiate Seniors' LayerNorm for n_inputs = 32 (512-bit row bus)
    reg          ln_valid_in;
    reg  [511:0] ln_in_bus;
    wire         ln_valid_out;
    wire [511:0] ln_out_bus;

    layernorm #(
        .LN_W(LN_W_FILE),
        .LN_B(LN_B_FILE),
        .n_inputs(32),
        .heads(1),
        .USE_BIAS(1)
    ) u_layernorm (
        .clk      (clk),
        .rst      (rst),
        .head_idx (3'd0),
        .valid_in (ln_valid_in),
        .in       (ln_in_bus),
        .valid_out(ln_valid_out),
        .out      (ln_out_bus)
    );

    // Final Post-LayerNorm Output BRAM (40 words of 128-bit)
    (* ram_style = "block" *) reg [127:0] ln1_ram [0:39];
    reg [3:0] ln_feed_cnt;
    reg [3:0] ln_out_cnt;

    always @(posedge clk) begin
        ln1_out_rdata <= ln1_ram[ln1_out_raddr];
    end

    always @(posedge clk) begin
        if (rst) begin
            state         <= S_IDLE;
            core_active   <= 1'b0;
            out_tile      <= 2'd0;
            in_chunk      <= 2'd0;
            load_cnt      <= 4'd0;
            cyc_cnt       <= 5'd0;
            feed_valid    <= 1'b0;
            load_weight   <= 1'b0;
            attn_raddr    <= 6'd0;
            res_vec_raddr <= 6'd0;
            wo_raddr      <= 7'd0;
            bo_tile       <= 2'd0;
            ln_valid_in   <= 1'b0;
            ln_in_bus     <= 512'd0;
            ln_feed_cnt   <= 4'd0;
            ln_out_cnt    <= 4'd0;
            ln1_done      <= 1'b0;
        end else begin
            ln1_done <= 1'b0;

            if (ln_valid_out) begin
                ln1_ram[{ln_out_cnt, 2'd0}] <= ln_out_bus[127:0];
                ln1_ram[{ln_out_cnt, 2'd1}] <= ln_out_bus[255:128];
                ln1_ram[{ln_out_cnt, 2'd2}] <= ln_out_bus[383:256];
                ln1_ram[{ln_out_cnt, 2'd3}] <= ln_out_bus[511:384];
                if (ln_out_cnt == 4'd9) begin
                    ln1_done <= 1'b1;
                    state    <= S_IDLE;
                end else begin
                    ln_out_cnt <= ln_out_cnt + 4'd1;
                end
            end

            case (state)
                S_IDLE: begin
                    ln_valid_in <= 1'b0;
                    if (start_out_proj) begin
                        core_active <= 1'b1;
                        out_tile    <= 2'd0;
                        in_chunk    <= 2'd0;
                        load_cnt    <= 4'd0;
                        bo_tile     <= 2'd0;
                        wo_raddr    <= 7'd7;
                        state       <= S_LOAD_W;
                    end
                end

                S_LOAD_W: begin
                    load_weight <= 1'b1;
                    load_cnt    <= load_cnt + 4'd1;

                    if (load_cnt < 4'd7) begin
                        wo_raddr <= ((out_tile * 4 + in_chunk) * 8) + (4'd6 - load_cnt);
                    end else if (load_cnt == 4'd7) begin
                        attn_raddr <= {4'd0, in_chunk};
                    end else if (load_cnt == 4'd8) begin
                        load_weight <= 1'b0;
                        feed_valid  <= 1'b1;
                        cyc_cnt     <= 5'd0;
                        attn_raddr  <= {4'd1, in_chunk};
                        state       <= S_STREAM;
                    end
                end

                S_STREAM: begin
                    cyc_cnt <= cyc_cnt + 5'd1;

                    if (cyc_cnt < 5'd8) begin
                        attn_raddr <= {(cyc_cnt[3:0] + 4'd2), in_chunk};
                    end else if (cyc_cnt == 5'd9) begin
                        feed_valid <= 1'b0;
                    end

                    // Pre-fetch Residual X_proj 2 cycles before cyc_cnt = 15..24
                    // (1 cycle for res_vec_raddr register + 1 cycle for synchronous BRAM vec_rdata)
                    if (in_chunk == 2'd3 && cyc_cnt >= 5'd13 && cyc_cnt <= 5'd22) begin
                        res_vec_raddr <= {prefetch_row, out_tile};
                    end

                    // Capture aligned outputs at cyc_cnt = 15..24
                    if (cyc_cnt >= 5'd15 && cyc_cnt <= 5'd24) begin
                        for (c = 0; c < 8; c = c + 1) begin
                            tile_acc[out_row][c] <= new_sum[c];
                        end

                        if (in_chunk == 2'd3) begin
                            res1_ram[out_row][out_tile*128 +: 128] <= formatted_res;
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
                        wo_raddr <= ((out_tile * 4 + (in_chunk + 2'd1)) * 8) + 7'd7;
                        state    <= S_LOAD_W;
                    end else begin
                        in_chunk <= 2'd0;
                        if (out_tile < 2'd3) begin
                            out_tile <= out_tile + 2'd1;
                            bo_tile  <= out_tile + 2'd1;
                            wo_raddr <= (((out_tile + 2'd1) * 4) * 8) + 7'd7;
                            state    <= S_LOAD_W;
                        end else begin
                            core_active <= 1'b0;
                            ln_feed_cnt <= 4'd0;
                            ln_out_cnt  <= 4'd0;
                            state       <= S_FEED_LN;
                        end
                    end
                end

                S_FEED_LN: begin
                    ln_valid_in <= 1'b1;
                    ln_in_bus   <= res1_ram[ln_feed_cnt];
                    if (ln_feed_cnt == 4'd9) begin
                        state <= S_WAIT_LN;
                    end else begin
                        ln_feed_cnt <= ln_feed_cnt + 4'd1;
                    end
                end

                S_WAIT_LN: begin
                    ln_valid_in <= 1'b0;
                end
            endcase
        end
    end

endmodule