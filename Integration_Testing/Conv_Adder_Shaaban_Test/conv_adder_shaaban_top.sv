`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// Module Name : conv_Adder_shaaban_top
// Description :
//    - Top-level processing pipeline for one CNN/SNN stage.
//    - Connects the convolution array to the adder-tree network and finally
//      to the Shaaban processing array.
//    - Processing flow:
//          Pixels + Weights
//                 ↓
//            top_conv9_array
//                 ↓
//             12 × 32 MAC Results
//                 ↓
//        shaaban_adder_tree_top
//                 ↓
//      Adder Tree → Stage Mapping →
//      Bias + ReLU → BatchNorm →
//      MaxPool → LIF
//                 ↓
//              Spike Outputs
//------------------------------------------------------------------------------

module conv_Adder_shaaban_top #(
    parameter DATA_WIDTH     = 18,
    parameter N_SHAABAN      = 32,
    parameter MAC_OUT_W      = 40,
    parameter INPUTS_PER_SHB = 4,
    parameter N_TREES        = 12
)(
    input  logic clk,
    input  logic rst,

    // Stage selector
    input  logic [1:0] src_sel,

    //-------------------------------------------------------------------------
    // Shaaban Parameters
    //-------------------------------------------------------------------------
    input  logic signed [DATA_WIDTH-1:0] conv_bias_param   [0:N_SHAABAN-1], // Usually zero
    input  logic signed [DATA_WIDTH-1:0] mult_weight_param [0:N_SHAABAN-1],
    input  logic signed [DATA_WIDTH-1:0] add_weight_param  [0:N_SHAABAN-1],

    //-------------------------------------------------------------------------
    // Convolution Inputs
    //-------------------------------------------------------------------------
    input  logic signed [DATA_WIDTH-1:0] pixels_mapped  [0:N_TREES-1][0:N_SHAABAN-1][0:8],
    input  logic signed [DATA_WIDTH-1:0] weights_mapped [0:N_TREES-1][0:N_SHAABAN-1][0:8],

    //-------------------------------------------------------------------------
    // Outputs
    //-------------------------------------------------------------------------
    output logic [N_SHAABAN-1:0] spike_out,
    output logic [0:N_SHAABAN-1] shaaban_spike_bus [0:N_SHAABAN-1]
);

    //-------------------------------------------------------------------------
    // Internal Signals
    //-------------------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0] mac_to_connect [0:N_TREES-1][0:N_SHAABAN-1];

    //-------------------------------------------------------------------------
    // Convolution Array
    // Computes all Conv9 MAC results.
    //-------------------------------------------------------------------------
    top_conv9_array #(
        .PIXEL_W    (DATA_WIDTH),
        .MAC_OUT_W  (MAC_OUT_W),
        .DATA_WIDTH (DATA_WIDTH)
    ) u_conv9_array (
        .clk            (clk),
        .pixels_mapped  (pixels_mapped),
        .weights_mapped (weights_mapped),
        .mac_to_connect (mac_to_connect)
    );

    //-------------------------------------------------------------------------
    // Adder Tree + Shaaban Processing
    // Performs:
    //   • Adder Trees
    //   • Stage-dependent routing
    //   • Bias + ReLU
    //   • BatchNorm
    //   • MaxPool
    //   • LIF neuron
    //-------------------------------------------------------------------------
    shaaban_adder_tree_top #(
        .DATA_WIDTH     (DATA_WIDTH),
        .N_SHAABAN      (N_SHAABAN),
        .INPUTS_PER_SHB (INPUTS_PER_SHB),
        .N_TREES        (N_TREES)
    ) u_shaaban_adder_tree (
        .clk               (clk),
        .rst               (rst),
        .src_sel           (src_sel),

        .mac_in            (mac_to_connect),

        .conv_bias_param   (conv_bias_param),
        .mult_weight_param (mult_weight_param),
        .add_weight_param  (add_weight_param),

        .spike_out         (spike_out),
        .shaaban_spike_bus (shaaban_spike_bus)
    );

endmodule