`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 02.11.2026 00:38:54
// Design Name: 
// Module Name: tb_system_top_qkv_qkt_soft
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

module tb_system_top_qkv_qkt_soft();

    reg          clk;
    reg          rst;
    reg          valid_in;
    reg  [15:0]  radar_input;
    reg          start_layer;

    reg  [5:0]   tb_raddr;
    wire [127:0] tb_q_rdata, tb_k_rdata, tb_v_rdata, tb_attn_rdata;

    reg  [3:0]   tb_row_raddr;
    wire [159:0] tb_score_rdata, tb_prob_rdata;

    wire         proj_done, qkv_done, qkt_done, softmax_done, attn_done;

    system_top_wrapper_2 #(
        .DATA_W(16),
        .Q_FRAC(12)
    ) UUT (
        .clk           (clk),
        .rst           (rst),
        .valid_in      (valid_in),
        .radar_input   (radar_input),
        .start_layer   (start_layer),
        .tb_q_raddr    (tb_raddr),
        .tb_q_rdata    (tb_q_rdata),
        .tb_k_raddr    (tb_raddr),
        .tb_k_rdata    (tb_k_rdata),
        .tb_v_raddr    (tb_raddr),
        .tb_v_rdata    (tb_v_rdata),
        .tb_score_raddr(tb_row_raddr),
        .tb_score_rdata(tb_score_rdata),
        .tb_prob_raddr (tb_row_raddr),
        .tb_prob_rdata (tb_prob_rdata),
        .tb_attn_raddr (tb_raddr),
        .tb_attn_rdata (tb_attn_rdata),
        .proj_done     (proj_done),
        .qkv_done      (qkv_done),
        .qkt_done      (qkt_done),
        .softmax_done  (softmax_done),
        .attn_done     (attn_done)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    reg [15:0]  radar_mem     [0:879];
    reg [127:0] exp_q_mem     [0:39];
    reg [127:0] exp_k_mem     [0:39];
    reg [127:0] exp_v_mem     [0:39];
    reg [159:0] exp_score_mem [0:9];
    reg [159:0] exp_prob_mem  [0:9];
    reg [127:0] exp_attn_mem  [0:39];

    initial begin
        $readmemh("test_input.mem",      radar_mem);
        $readmemh("expected_q.mem",      exp_q_mem);
        $readmemh("expected_k.mem",      exp_k_mem);
        $readmemh("expected_v.mem",      exp_v_mem);
        $readmemh("expected_scores.mem", exp_score_mem);
        $readmemh("expected_probs.mem",  exp_prob_mem);
        $readmemh("expected_attn.mem",   exp_attn_mem);
    end

    integer i, c, q_err, k_err, v_err, s_err, p_err, a_err;
    reg signed [15:0] got_val, exp_val;
    integer diff;

    initial begin
        rst          = 1;
        valid_in     = 0;
        radar_input  = 0;
        start_layer  = 0;
        tb_raddr     = 0;
        tb_row_raddr = 0;
        q_err = 0; k_err = 0; v_err = 0; s_err = 0; p_err = 0; a_err = 0;

        #100;
        rst = 0;
        #20;

        for (i = 0; i < 880; i = i + 1) begin
            @(posedge clk);
            valid_in    <= 1'b1;
            radar_input <= radar_mem[i];
        end
        @(posedge clk);
        valid_in <= 1'b0;

        #20;
        @(posedge clk); start_layer <= 1'b1;
        @(posedge clk); start_layer <= 1'b0;

        wait (proj_done == 1'b1);
        $display("[%0t] Stage 1: top_projection complete!", $time);

        wait (qkv_done == 1'b1);
        $display("[%0t] Stage 2: QKV complete!", $time);

        wait (qkt_done == 1'b1);
        $display("[%0t] Stage 3: Q*K^T Scores complete!", $time);

        wait (softmax_done == 1'b1);
        $display("[%0t] Stage 4B: Seniors' Softmax complete!", $time);

        wait (attn_done == 1'b1);
        $display("[%0t] Stage 4C: Final Attention Context (Probs * V) complete!", $time);
        #20;

        // 1. Verify Q, K, V, and Final Attention Output (40 chunks)
        for (i = 0; i < 40; i = i + 1) begin
            @(posedge clk);
            tb_raddr <= i[5:0];
            @(posedge clk);
            #1;
            if (tb_q_rdata !== exp_q_mem[i]) q_err = q_err + 1;
            if (tb_k_rdata !== exp_k_mem[i]) k_err = k_err + 1;
            if (tb_v_rdata !== exp_v_mem[i]) v_err = v_err + 1;

            for (c = 0; c < 8; c = c + 1) begin
                got_val = tb_attn_rdata[c*16 +: 16];
                exp_val = exp_attn_mem[i][c*16 +: 16];
                diff    = (got_val > exp_val) ? (got_val - exp_val) : (exp_val - got_val);
                if (diff > 16 || (^got_val === 1'bx)) begin
                    $display("ATTN DIFF at chunk %0d col %0d: Exp=%0d, Got=%0d (Diff=%0d LSBs)", i, c, exp_val, got_val, diff);
                    a_err = a_err + 1;
                end
            end
        end

        // 2. Verify Scores (exact) and Softmax Probabilities (against pure float Softmax)
        for (i = 0; i < 10; i = i + 1) begin
            @(posedge clk);
            tb_row_raddr <= i[3:0];
            @(posedge clk);
            #1;
            if (tb_score_rdata !== exp_score_mem[i]) s_err = s_err + 1;

            for (c = 0; c < 10; c = c + 1) begin
                got_val = tb_prob_rdata[c*16 +: 16];
                exp_val = exp_prob_mem[i][c*16 +: 16];
                diff    = (got_val > exp_val) ? (got_val - exp_val) : (exp_val - got_val);
                if (diff > 16 || (^got_val === 1'bx)) begin
                    $display("PROB DIFF at row %0d col %0d: Exp=%0d, Got=%0d (Diff=%0d LSBs)", i, c, exp_val, got_val, diff);
                    p_err = p_err + 1;
                end
            end
        end

        $display("==========================================================");
        $display("VERIFICATION SUMMARY:");
        $display("  Exact Matches -> Q_err:%0d, K_err:%0d, V_err:%0d, Score_err:%0d", q_err, k_err, v_err, s_err);
        $display("  LUT Tolerance -> Softmax_Prob_err:%0d, Final_Attn_err:%0d", p_err, a_err);
        if ((q_err + k_err + v_err + s_err + p_err + a_err) == 0)
            $display("  FULL ATTENTION LAYER PASSED 100%%!");
        $display("==========================================================");

        #50;
        $stop;
    end

endmodule
