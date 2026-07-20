`timescale 1ns / 1ps

//===========================================================
// File        : order_correction.sv
// Purpose     : SEPARATE INPUT LOGIC: EXTERNAL SUM CORRECTION
// Used in     : adder_tree_shaaban_connect.sv
//===========================================================
// Written by  : Ahmed Essam
// Editor      : <, if reviewed / modified by someone else>
// Last edit   : <2026-07-06>
//===========================================================

// =========================================================================
// Consumes the 24 "extra" MAC products (indices 30 and 31 from 12 trees) 
// in a continuous flat sequence to feed 8 adders (3 inputs each).
// For any correction 'c', its 3 inputs have global pool indices: 3c, 3c+1, 3c+2.
// Tree Index = (global_index) / 2
// Port Index = 30 + ((global_index) % 2)
// =========================================================================

module order_correction #(
    parameter int N_TREES        = 12,
    parameter int TAPS_PER_TREE  = 10,
    parameter int N_SHAABAN      = 32,
    parameter int INPUTS_PER_SHB = 4,       // For Pooling each input has MUX to determine the stage.
    parameter int DATA_WIDTH     = 18,

    // Derived parameters
    parameter int TOTAL_S1_INPUTS  = N_SHAABAN * INPUTS_PER_SHB,       // 128
    parameter int TOTAL_TAPS       = N_TREES * TAPS_PER_TREE,          // 120
    //the needed number of adders for the last 2 conv in each tree (which is 24) each adder has 3 inputs
    parameter int N_CORRECTION     = TOTAL_S1_INPUTS - TOTAL_TAPS      // 8
)(
    input  wire logic signed [DATA_WIDTH-1:0] tree_tap   [0:N_TREES-1][0:TAPS_PER_TREE-1],
    input wire logic signed [DATA_WIDTH-1:0] ext_sum_correction [0:N_CORRECTION-1],

    output logic signed [DATA_WIDTH-1:0] flat_s1 [0:TOTAL_S1_INPUTS-1]
);

    genvar group_index, k;
    generate
        for (group_index = 0; group_index < 4; group_index++) begin : gen_s1_group
            for (k = 0; k < TAPS_PER_TREE; k++) begin : gen_s1_taps
                assign flat_s1[(group_index * 32) + k] =
                    tree_tap[(group_index * 3)][k];

                assign flat_s1[(group_index * 32) + 11 + k] =
                    tree_tap[(group_index * 3) + 1][k];

                assign flat_s1[(group_index * 32) + 22 + k] =
                    tree_tap[(group_index * 3) + 2][k];
            end

            assign flat_s1[(group_index * 32) + 10] =
                ext_sum_correction[group_index * 2];
            assign flat_s1[(group_index * 32) + 21] =
                ext_sum_correction[(group_index * 2) + 1];
        end
    endgenerate

endmodule : order_correction