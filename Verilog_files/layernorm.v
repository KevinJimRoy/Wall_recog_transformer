`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 26.03.2026 23:05:36
// Design Name: 
// Module Name: layernorm
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

module layernorm #(
    parameter LN_W = "norm_weight.mem",
    parameter LN_B = "norm_bias.mem",
    parameter n_inputs = 32,
    parameter heads = 1,
    parameter USE_BIAS = 1
)(
    input clk,
    input rst,
    input [2:0] head_idx,
    input valid_in,
    input [(n_inputs*16)-1:0] in,
    output reg valid_out,
    output reg [(n_inputs*16)-1:0] out
);

    wire signed [15:0] w_m [0:n_inputs-1];
    wire signed [15:0] b_m [0:n_inputs-1];

    genvar g;
    generate
        if (USE_BIAS) begin : gen_bias
            reg [15:0] b_mem [0:(n_inputs*heads)-1];
            initial $readmemh(LN_B, b_mem);
            for (g = 0; g < n_inputs; g = g + 1) begin
                assign b_m[g] = b_mem[(head_idx * n_inputs) + g];
            end
        end else begin : gen_no_bias
            for (g = 0; g < n_inputs; g = g + 1) begin
                assign b_m[g] = 16'sd0;
            end
        end
        
        reg [15:0] w_mem [0:(n_inputs*heads)-1];
        initial $readmemh(LN_W, w_mem);
        for (g = 0; g < n_inputs; g = g + 1) begin
            assign w_m[g] = w_mem[(head_idx * n_inputs) + g];
        end
    endgenerate

    reg valid_stg1, valid_stg2, valid_stg3;

    reg signed [15:0] stg1_in [0:n_inputs-1];
    reg signed [15:0] stg1_w [0:n_inputs-1];
    reg signed [15:0] stg1_b [0:n_inputs-1];
    reg signed [15:0] stg1_mean;

    reg signed [15:0] stg2_norm [0:n_inputs-1];
    reg signed [15:0] stg2_w [0:n_inputs-1];
    reg signed [15:0] stg2_b [0:n_inputs-1];
    reg signed [47:0] stg2_sum_var;

    reg signed [15:0] stg3_norm [0:n_inputs-1];
    reg signed [15:0] stg3_w [0:n_inputs-1];
    reg signed [15:0] stg3_b [0:n_inputs-1];
    reg signed [15:0] stg3_var_mean;
    
    wire signed [15:0] inv_var;

    integer i;
    reg signed [47:0] temp_sum_var, temp_var;
    reg signed [31:0] temp_sum, temp_shift;
    reg signed [47:0] temp_shifted_var;

    always @(posedge clk) begin
        if (rst) begin
            valid_stg1 <= 0; valid_stg2 <= 0; valid_stg3 <= 0; valid_out <= 0;
        end else begin
            valid_stg1 <= valid_in;
            if (valid_in) begin
                temp_sum = 0;
                for (i = 0; i < n_inputs; i = i + 1) begin
                    stg1_in[i] <= in[i*16+:16];
                    stg1_w[i] <= w_m[i];
                    stg1_b[i] <= b_m[i];
                    temp_sum = temp_sum + $signed(in[i*16+:16]);
                end
                if (n_inputs == 48)      stg1_mean <= (temp_sum * 341) >>> 14;
                else if (n_inputs == 32) stg1_mean <= temp_sum >>> 5; // Divide by 32
                else if (n_inputs == 4)  stg1_mean <= temp_sum >>> 2;
                else                     stg1_mean <= temp_sum >>> 8;
            end

            valid_stg2 <= valid_stg1;
            if (valid_stg1) begin
                temp_sum_var = 0;
                for (i = 0; i < n_inputs; i = i + 1) begin
                    stg2_w[i] <= stg1_w[i];
                    stg2_b[i] <= stg1_b[i];
                    stg2_norm[i] <= $signed(stg1_in[i]) - $signed(stg1_mean);
                    
                    temp_var = $signed(stg1_in[i]) - $signed(stg1_mean);
                    temp_var = temp_var * temp_var; 
                    
                    temp_sum_var = temp_sum_var + temp_var;
                end
                stg2_sum_var <= temp_sum_var;
            end

            valid_stg3 <= valid_stg2;
            if (valid_stg2) begin
                for (i = 0; i < n_inputs; i = i + 1) begin
                    stg3_w[i] <= stg2_w[i];
                    stg3_b[i] <= stg2_b[i];
                    stg3_norm[i] <= stg2_norm[i];
                end
                
                if (n_inputs == 48)      temp_shifted_var = (stg2_sum_var * 341) >>> 26;
                else if (n_inputs == 32) temp_shifted_var = stg2_sum_var >>> 17; // Divide by 32 (12 + 5)
                else if (n_inputs == 4)  temp_shifted_var = stg2_sum_var >>> 14;
                else                     temp_shifted_var = stg2_sum_var >>> 20;

                if (temp_shifted_var > 32767) begin
                    stg3_var_mean <= 16'sd32767;
                end else begin
                    stg3_var_mean <= temp_shifted_var[15:0];
                end
            end

            valid_out <= valid_stg3;
            if (valid_stg3) begin
                for (i = 0; i < n_inputs; i = i + 1) begin
                    temp_shift = ($signed(inv_var) * $signed(stg3_norm[i])) >>> 8;
                    temp_shift = ($signed(temp_shift) * $signed(stg3_w[i])) >>> 12;
                    temp_shift = $signed(temp_shift) + $signed(stg3_b[i]);
                    
                    if (temp_shift > 32767) out[i*16+:16] <= 16'h7fff;
                    else if (temp_shift < -32768) out[i*16+:16] <= 16'h8000;
                    else out[i*16+:16] <= temp_shift[15:0];
                end
            end
        end
    end

    InvSqrt inv_sqrt_module(
        .in(stg3_var_mean),
        .out(inv_var)
    );
endmodule