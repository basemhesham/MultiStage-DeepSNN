//==========================================================================================================================
// File        : spike_mem.sv
// Purpose     : store the data between stages (at stage3 it add its data with the prev one and store it in the same place)
// Used in     : <parent module / top level that instantiates this>
//==========================================================================================================================
// Written by  : <name>
// Editor      : <Hany>
// Last edit   : <2026-07-06>
//==========================================================================================================================

`timescale 1ns / 1ps

module spike_mem #(
    parameter int MEM_WORD   = 3200,
    parameter int ADDR_WIDTH = 6
)(
    //=======================================================
    // Controls
    //=======================================================
    input  logic                  clk,
    input  logic                  rst,
    input  logic                  wr_en,
    //=======================================================
    // Inputs
    //=======================================================
    input  logic [MEM_WORD-1:0]   bit_enable,
    input  logic                  zero_sel,
    input  logic [ADDR_WIDTH-1:0] wr_addr,
    input  logic [ADDR_WIDTH-1:0] rd_addr,
    input  logic [MEM_WORD-1:0]   wr_data,
    //=======================================================
    // outputs
    //=======================================================
    output logic [MEM_WORD-1:0]   rd_data
);
    //=======================================================
    // Local Parameters
    //=======================================================
    localparam int DEPTH = 1 << ADDR_WIDTH;

    //=======================================================
    // Internals: one single-bit memory per bit lane
    //=======================================================
    genvar i;
    generate
        for (i = 0; i < MEM_WORD; i = i + 1) begin : g_bit_lane

            (* ram_style = "distributed" *) logic mem_bit [0:DEPTH-1];

            wire lane_we   = wr_en & bit_enable[i];
            wire lane_wdat = zero_sel ? 1'b0 : wr_data[i];

            always_ff @(posedge clk) begin
                if (lane_we)
                    mem_bit[wr_addr] <= lane_wdat;
            end

            always_ff @(posedge clk or negedge rst) begin
                if (!rst)
                    rd_data[i] <= 1'b0;
                else
                    rd_data[i] <= mem_bit[rd_addr];
            end

        end
    endgenerate

endmodule