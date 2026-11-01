`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.11.2026 18:18:41
// Design Name: 
// Module Name: proj_to_systolic_bridge
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


module proj_to_systolic_bridge (
    input  wire         clk,
    input  wire         rst,
    
    // Connects directly to top_projection
    input  wire         proj_layer_done,   // Triggered by top_projection.layer_done
    output reg  [8:0]   next_layer_raddr,  // Drives top_projection.next_layer_raddr (0..319)
    input  wire [15:0]  next_layer_rdata,  // Reads top_projection.next_layer_rdata
    
    // Connects to the Systolic Array QKV Controller
    output reg          bridge_done,       // 1-cycle pulse when all 40 chunks are packed
    input  wire [5:0]   vec_raddr,         // 0 to 39 (Row * 4 + Chunk)
    output reg  [127:0] vec_rdata          // 8 features (128 bits) per clock
);

    // 40 words of 128-bit (10 rows * 4 chunks of 8 features = 320 elements)
    (* ram_style = "block" *) reg [127:0] vec_ram [0:39];

    localparam S_IDLE = 2'd0;
    localparam S_READ = 2'd1;
    localparam S_LAST = 2'd2;

    reg [1:0]   state;
    reg [8:0]   req_cnt;   // Address currently being requested (0..319)
    reg [8:0]   recv_idx;  // Address whose data is currently arriving (1 cycle behind req_cnt)
    reg [111:0] pack_shift;// Holds the first 7 features while waiting for the 8th

    always @(posedge clk) begin
        if (rst) begin
            state            <= S_IDLE;
            next_layer_raddr <= 9'd0;
            bridge_done      <= 1'b0;
            req_cnt          <= 9'd0;
            recv_idx         <= 9'd0;
            pack_shift       <= 112'd0;
        end else begin
            bridge_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (proj_layer_done) begin
                        // Request Address 0 on the next clock edge
                        next_layer_raddr <= 9'd0;
                        req_cnt          <= 9'd0;
                        state            <= S_READ;
                    end
                end

                S_READ: begin
                    // Request the next address (up to 319)
                    if (req_cnt < 9'd319) begin
                        req_cnt          <= req_cnt + 9'd1;
                        next_layer_raddr <= req_cnt + 9'd1;
                    end else begin
                        state <= S_LAST;
                    end

                    // Because of 1-cycle BRAM latency, data for req_cnt=0 arrives
                    // on the cycle when req_cnt=1.
                    if (req_cnt > 9'd0) begin
                        recv_idx = req_cnt - 9'd1;
                        if (recv_idx[2:0] == 3'd7) begin
                            // 8th feature arrived: write full 128-bit chunk to vec_ram
                            vec_ram[recv_idx[8:3]] <= {next_layer_rdata, pack_shift};
                        end else begin
                            // Store features 0..6 into holding register
                            pack_shift[recv_idx[2:0]*16 +: 16] <= next_layer_rdata;
                        end
                    end
                end

                S_LAST: begin
                    // Capture the final element (Address 319 -> Chunk 39, Feature 7)
                    vec_ram[6'd39] <= {next_layer_rdata, pack_shift};
                    bridge_done    <= 1'b1;
                    state          <= S_IDLE;
                end
            endcase
        end
    end

    // Synchronous 128-bit Read Port for the Systolic Array
    always @(posedge clk) begin
        vec_rdata <= vec_ram[vec_raddr];
    end

endmodule