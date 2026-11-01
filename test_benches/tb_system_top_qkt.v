`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.11.2026 23:28:39
// Design Name: 
// Module Name: tb_system_top_qkt
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

module tb_system_top_qkt();

    reg          clk;
    reg          rst;
    reg          valid_in;
    reg  [15:0]  radar_input;
    reg          start_layer;

    reg  [5:0]   tb_raddr;
    wire [127:0] tb_q_rdata;
    wire [127:0] tb_k_rdata;
    wire [127:0] tb_v_rdata;

    reg  [3:0]   tb_score_raddr;
    wire [159:0] tb_score_rdata;

    wire         proj_done;
    wire         qkv_done;
    wire         qkt_done;

    system_top_wrapper_1 #(
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
        .tb_score_raddr(tb_score_raddr),
        .tb_score_rdata(tb_score_rdata),
        .proj_done     (proj_done),
        .qkv_done      (qkv_done),
        .qkt_done      (qkt_done)
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

    initial begin
        $readmemh("test_input.mem",      radar_mem);
        $readmemh("expected_q.mem",      exp_q_mem);
        $readmemh("expected_k.mem",      exp_k_mem);
        $readmemh("expected_v.mem",      exp_v_mem);
        $readmemh("expected_scores.mem", exp_score_mem);
    end

    integer i, q_err, k_err, v_err, s_err;

    initial begin
        rst            = 1;
        valid_in       = 0;
        radar_input    = 0;
        start_layer    = 0;
        tb_raddr       = 0;
        tb_score_raddr = 0;
        q_err          = 0;
        k_err          = 0;
        v_err          = 0;
        s_err          = 0;

        #100;
        rst = 0;
        #20;

        // 1. Stream 880 inputs into top_projection
        $display("[%0t] Streaming 880 radar inputs...", $time);
        for (i = 0; i < 880; i = i + 1) begin
            @(posedge clk);
            valid_in    <= 1'b1;
            radar_input <= radar_mem[i];
        end
        @(posedge clk);
        valid_in <= 1'b0;

        // 2. Pulse start_layer
        #20;
        @(posedge clk);
        start_layer <= 1'b1;
        @(posedge clk);
        start_layer <= 1'b0;

        // 3. Wait for Projection, QKV, and Q*K^T stages
        wait (proj_done == 1'b1);
        $display("[%0t] Stage 1: top_projection complete!", $time);

        wait (qkv_done == 1'b1);
        $display("[%0t] Stage 2: QKV Generation complete! Reusing Systolic Array for Q*K^T...", $time);

        wait (qkt_done == 1'b1);
        $display("[%0t] Stage 3: Q*K^T Attention Scores complete! Verifying memories...", $time);
        #20;

        // 4. Verify Q, K, V BRAMs
        for (i = 0; i < 40; i = i + 1) begin
            @(posedge clk);
            tb_raddr <= i[5:0];
            @(posedge clk);
            #1;
            if (tb_q_rdata !== exp_q_mem[i]) q_err = q_err + 1;
            if (tb_k_rdata !== exp_k_mem[i]) k_err = k_err + 1;
            if (tb_v_rdata !== exp_v_mem[i]) v_err = v_err + 1;
        end

        // 5. Verify 10x10 Attention Score RAM (10 rows of 160-bit)
        for (i = 0; i < 10; i = i + 1) begin
            @(posedge clk);
            tb_score_raddr <= i[3:0];
            @(posedge clk);
            #1;
            if (tb_score_rdata !== exp_score_mem[i]) begin
                $display("SCORE MISMATCH at Row %0d:\n  Exp=%h\n  Got=%h", i, exp_score_mem[i], tb_score_rdata);
                s_err = s_err + 1;
            end
        end

        if ((q_err + k_err + v_err + s_err) == 0)
            $display("SUCCESS! Q, K, V, and all 100 Attention Scores (Q*K^T / sqrt(32)) matched NumPy 100%%!");
        else
            $display("FAILED! Errors -> Q:%0d, K:%0d, V:%0d, Scores:%0d", q_err, k_err, v_err, s_err);

        #50;
        $stop;
    end

endmodule
