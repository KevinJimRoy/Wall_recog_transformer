`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.11.2026 19:09:11
// Design Name: 
// Module Name: tb_system_top
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


module tb_system_top();

    reg          clk;
    reg          rst;
    reg          valid_in;
    reg  [15:0]  radar_input;
    reg          start_layer;

    reg  [5:0]   tb_raddr;
    wire [127:0] tb_q_rdata;
    wire [127:0] tb_k_rdata;
    wire [127:0] tb_v_rdata;

    wire         proj_done;
    wire         qkv_done;

    system_top_wrapper #(
        .DATA_W(16),
        .Q_FRAC(12)
    ) UUT (
        .clk        (clk),
        .rst        (rst),
        .valid_in   (valid_in),
        .radar_input(radar_input),
        .start_layer(start_layer),
        .tb_q_raddr (tb_raddr),
        .tb_q_rdata (tb_q_rdata),
        .tb_k_raddr (tb_raddr),
        .tb_k_rdata (tb_k_rdata),
        .tb_v_raddr (tb_raddr),
        .tb_v_rdata (tb_v_rdata),
        .proj_done  (proj_done),
        .qkv_done   (qkv_done)
    );

    // 100 MHz Clock
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    reg [15:0]  radar_mem [0:879];
    reg [127:0] exp_q_mem [0:39];
    reg [127:0] exp_k_mem [0:39];
    reg [127:0] exp_v_mem [0:39];

    initial begin
        $readmemh("radar_input.mem", radar_mem);
        $readmemh("expected_q.mem",  exp_q_mem);
        $readmemh("expected_k.mem",  exp_k_mem);
        $readmemh("expected_v.mem",  exp_v_mem);
    end

    integer i, q_err, k_err, v_err;

    initial begin
        rst         = 1;
        valid_in    = 0;
        radar_input = 0;
        start_layer = 0;
        tb_raddr    = 0;
        q_err       = 0;
        k_err       = 0;
        v_err       = 0;

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

        // 3. Wait for Projection and QKV stages
        wait (proj_done == 1'b1);
        $display("[%0t] top_projection complete! Bridge + QKV Systolic Array running...", $time);

        wait (qkv_done == 1'b1);
        $display("[%0t] QKV Generation complete! Verifying Q, K, and V BRAMs...", $time);
        #20;

        // 4. Verify all 40 chunks (10x32) in Q, K, and V BRAMs
        for (i = 0; i < 40; i = i + 1) begin
            @(posedge clk);
            tb_raddr <= i[5:0];
            @(posedge clk); // 1-cycle synchronous BRAM read latency
            #1;
            if (tb_q_rdata !== exp_q_mem[i]) begin
                $display("Q MISMATCH at addr %0d: Exp=%h, Got=%h", i, exp_q_mem[i], tb_q_rdata);
                q_err = q_err + 1;
            end
            if (tb_k_rdata !== exp_k_mem[i]) begin
                $display("K MISMATCH at addr %0d: Exp=%h, Got=%h", i, exp_k_mem[i], tb_k_rdata);
                k_err = k_err + 1;
            end
            if (tb_v_rdata !== exp_v_mem[i]) begin
                $display("V MISMATCH at addr %0d: Exp=%h, Got=%h", i, exp_v_mem[i], tb_v_rdata);
                v_err = v_err + 1;
            end
        end

        if ((q_err + k_err + v_err) == 0)
            $display("SUCCESS! Q, K, and V BRAMs (960 elements total) match standard NumPy matmul 100%%!");
        else
            $display("FAILED! Errors -> Q:%0d, K:%0d, V:%0d", q_err, k_err, v_err);

        #50;
        $stop;
    end

endmodule