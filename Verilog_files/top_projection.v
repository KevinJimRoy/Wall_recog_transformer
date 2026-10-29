`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 27.10.2026 22:25:52
// Design Name: 
// Module Name: top_projection
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

module top_projection #(
    parameter DATA_W = 16,
    parameter Q_FRAC = 12
)(
    input  wire                 clk,
    input  wire                 rst,
    
    // Interface 1: Serial Radar Input
    input  wire                 valid_in,
    input  wire [DATA_W-1:0]    radar_input,
    
    // Interface 2: Control Signals
    input  wire                 start_layer,
    output wire                 layer_done,
    
    // Interface 3: Downstream Read (For the next Attention Layer)
    input  wire [8:0]           next_layer_raddr,
    output wire [DATA_W-1:0]    next_layer_rdata
);

    // -----------------------------------------------------------------
    // Internal Wires connecting the Master Controller to the Slaves
    // -----------------------------------------------------------------
    wire [6:0]        buf_read_addr;
    wire [127:0]      buf_read_data;
    
    wire [8:0]        w_read_addr;
    wire [127:0]      w_read_data;
    
    wire              bram_we;
    wire [8:0]        bram_waddr;
    wire [DATA_W-1:0] bram_wdata;

    // -----------------------------------------------------------------
    // Module 1: The Input Buffer (Slave)
    // -----------------------------------------------------------------
    input_buffer #(.DATA_W(DATA_W)) input_buffer_inst (
        .clk(clk),
        .rst(rst),
        .valid_in(valid_in),
        .radar_input(radar_input),
        .read_addr(buf_read_addr),   // Driven by Controller
        .read_data(buf_read_data),   // Feeds into Controller
        .row_ready()                 // Left unconnected (we use start_layer manually)
    );

    // -----------------------------------------------------------------
    // Module 2: The Weight ROM (Slave)
    // -----------------------------------------------------------------
    weights_projection_88_32 #(.W_FILE("in_proj_w.mem")) weight_rom_inst (
        .clk(clk),
        .read_addr(w_read_addr),     // Driven by Controller
        .read_data(w_read_data)      // Feeds into Controller
    );

    // -----------------------------------------------------------------
    // Module 3: The Folded MAC Engine (Master)
    // -----------------------------------------------------------------
    projection_mac #(
        .DATA_W(DATA_W),
        .Q_FRAC(Q_FRAC),
        .B_FILE("in_proj_b.mem"),
        .P_FILE("pos_enc.mem")
    ) mac_master_inst (
        .clk(clk),
        .rst(rst),
        .start_layer(start_layer),
        .layer_done(layer_done),
        .buf_read_addr(buf_read_addr),
        .buf_read_data(buf_read_data),
        .w_read_addr(w_read_addr),
        .w_read_data(w_read_data),
        .bram_we(bram_we),
        .bram_waddr(bram_waddr),
        .bram_wdata(bram_wdata)
    );

    // -----------------------------------------------------------------
    // Module 4: The Output Tensor BRAM (Slave)
    // -----------------------------------------------------------------
    projection_out_bram #(
        .DATA_W(DATA_W),
        .DEPTH(320)
    ) output_bram_inst (
        .clk(clk),
        .we_a(bram_we),              // Driven by Controller
        .addr_a(bram_waddr),         // Driven by Controller
        .din_a(bram_wdata),          // Driven by Controller
        .addr_b(next_layer_raddr),   // Driven by NEXT layer (or testbench)
        .dout_b(next_layer_rdata)    // Feeds to NEXT layer (or testbench)
    );

endmodule
