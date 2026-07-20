`timescale 1ns / 1ps

// =============================================================================
// shabaan_adder_tree_top.v
//
// Top-level integration module for the convolution accumulation and Shaaban
// processing pipeline.
//
// This module interfaces the convolution engine with the Shaaban processing
// array. It receives the MAC outputs from multiple convolution adder trees,
// selects the desired convolution stage through a configurable multiplexer,
// and routes the selected results to the corresponding Shaaban processing
// units. Each Shaaban unit then performs bias addition, weighted arithmetic,
// and spike generation to produce the final spiking outputs.
//
// Architecture:
//   • Receives 12 convolution result buses (32 outputs per bus).
//   • Selects one convolution stage using src_sel.
//   • Packs and routes the selected outputs to 32 Shaaban units.
//   • Each Shaaban unit performs neuron processing and spike generation.
//   • Produces the final spike vector and individual Shaaban spike buses.
//
// Inputs:
//   clk               - System clock.
//   rst               - Active-high synchronous reset.
//   src_sel           - Selects which convolution stage is routed.
//   mac_in            - Convolution outputs from the adder-tree array.
//   conv_bias_param   - Bias values for each Shaaban neuron.
//   mult_weight_param - Multiplication weights for each Shaaban neuron.
//   add_weight_param  - Addition weights for each Shaaban neuron.
//
// Outputs:
//   spike_out         - Final 32-bit spike output vector.
//   shaaban_spike_bus - Individual spike outputs from all Shaaban units.
//
// =============================================================================

module shaaban_adder_tree_top #(
    parameter DATA_WIDTH     = 18,
    parameter N_SHAABAN      = 32,
    parameter INPUTS_PER_SHB = 4,
    parameter N_TREES        = 12
)(
    
    // Clock and Reset
    input  logic clk,
    input  logic rst,

    
    // Control Signal
    input  logic [1:0] src_sel,    // Selects the convolution stage routed to the Shaaban units

    
    // Convolution Inputs
    // 12 adder trees × 32 MAC products per tree
    input  logic signed [DATA_WIDTH-1:0] mac_in [0:N_TREES-1][0:31],

    // Shaaban Parameters
    input  logic signed [DATA_WIDTH-1:0] conv_bias_param   [0:N_SHAABAN-1], // always 0
    input  logic signed [DATA_WIDTH-1:0] mult_weight_param [0:N_SHAABAN-1],
    input  logic signed [DATA_WIDTH-1:0] add_weight_param  [0:N_SHAABAN-1],

    // Outputs
    output logic [31:0] spike_out,                       // Final spike outputs
    output logic [0:31] shaaban_spike_bus [0:N_SHAABAN-1]// Individual Shaaban spike buses
);

    // Internal Signals
    // Packed input bus for each Shaaban unit
    logic signed [(INPUTS_PER_SHB*DATA_WIDTH)-1:0] shb_bus [0:N_SHAABAN-1];

    
    // Adder Tree Connection Module
    // Routes the selected convolution stage to the corresponding Shaaban units
    adder_tree_shaaban_connect u_connect (
        .clk          (clk),
        .rst          (rst),
        .src_sel      (src_sel),
        .mac_in       (mac_in),
        .shb_conv_bus (shb_bus)
    );

    
    // Shaaban Processing Array
    // Performs bias addition, weighted accumulation, and spike generation
    top_shaaban_array #(
        .DATA_WIDTH     (DATA_WIDTH),
        .N_SHAABAN      (N_SHAABAN),
        .INPUTS_PER_SHB (INPUTS_PER_SHB)
    ) u_shaaban_array (
        .clk               (clk),
        .rst               (rst),
        .shb_bus           (shb_bus),
        .conv_bias_param   (conv_bias_param),
        .mult_weight_param (mult_weight_param),
        .add_weight_param  (add_weight_param),
        .spike_out         (spike_out),
        .shaaban_spike_bus (shaaban_spike_bus)
    );

endmodule