`timescale 1ns / 1ps

//===========================================================
// File        : sum_correction.sv
// Purpose     : ext_sum_correction
// Used in     : adder_tree_shaaban_connect.sv
//===========================================================
// Written by  : 
// Editor      : <Ahmed Essam, if reviewed / modified by someone else>
// Last edit   : <2026-07-06>
//===========================================================

// =============================================================================
// ext_sum_correction.sv
// -----------------------------------------------------------------------------
// PURPOSE
//   Each adder_tree_10_4_1_1 uses slots 0-29 for its 10 Layer-1 adders
//   (groups of 3). Slots 30 and 31 (the last two inputs of every tree) are
//   "orphans" — they are fed into a DSP macro inside the tree but that path
//   produces a biased result due to a bit-range bug in the tree's final_output.
//
//   This module collects those 24 orphan MACs (2 per tree × 12 trees) into a
//   flat pool and groups them sequentially by 3 to produce 8 corrected partial
//   sums. Each corrected sum is an accurate 18-bit conv25 partial result that
//   can be directly fed to a Shaaban unit alongside the standard L1 taps.
//
//
// CORRECTION ADDER GROUPING  (8 adders, 3 orphans each)
//   corr[0]: pool[0,1,2]   = tree0[30], tree0[31], tree1[30]
//   corr[1]: pool[3,4,5]   = tree1[31], tree2[30], tree2[31]
//   corr[2]: pool[6,7,8]   = tree3[30], tree3[31], tree4[30]
//   corr[3]: pool[9,10,11] = tree4[31], tree5[30], tree5[31]
//   corr[4]: pool[12,13,14]= tree6[30], tree6[31], tree7[30]
//   corr[5]: pool[15,16,17]= tree7[31], tree8[30], tree8[31]
//   corr[6]: pool[18,19,20]= tree9[30], tree9[31], tree10[30]
//   corr[7]: pool[21,22,23]= tree10[31],tree11[30],tree11[31]
//
// BIT WIDTHS
//   Input:  DATA_WIDTH bits (18) signed
//   Raw sum: DATA_WIDTH+2 bits (20) signed — 3 terms need 2 extra bits
//   Output: DATA_WIDTH bits (18) signed — truncate LSB (right-shift 1)
//           This matches the normalization applied to L1 taps inside the tree.
//
// COMBINATIONAL — no clock, no state.
// =============================================================================

module sum_correction #(
    parameter int N_TREES      = 12,    // must match top-level
    parameter int N_CORRECTION = 8,     // = N_SHAABAN*INPUTS_PER_SHB - N_TREES*TAPS_PER_TREE
    parameter int DATA_WIDTH   = 18     // signed fixed-point
)(
    // 12 trees × 32 MAC products (full array passed in; module only reads [30] and [31])
    input wire logic signed [DATA_WIDTH-1:0] non_tap [0:(N_TREES*2)-1],   // the last 2 conv in each tree

    // 8 corrected partial sums, truncated to DATA_WIDTH
    output logic signed [DATA_WIDTH-1:0] corr_out [0:N_CORRECTION-1]
);

    // -------------------------------------------------------------------------
    // Raw sums (20-bit to hold overflow of three 18-bit signed additions)
    // -------------------------------------------------------------------------
    logic signed [DATA_WIDTH+1:0] raw_sum [0:N_CORRECTION-1];

    genvar c;
    generate
        for (c = 0; c < N_CORRECTION; c++) begin : gen_correction

            // ------------------------------------------------------------------
            // Map the three global orphan indices for this correction adder
            // to (tree, port) pairs using the pool formula:

            adder_layer1 u_correction_adder (
                .add_1    (non_tap[3*c]),
                .add_2    (non_tap[3*c+1]),
                .add_3    (non_tap[3*c+2]),
                .adder_out(raw_sum[c])
            );

            // Truncate: right-shift by 1 to match adder_tree Layer-1 normalization,
            // then take the lower DATA_WIDTH bits.
            assign corr_out[c] = raw_sum[c][DATA_WIDTH-1:0];  // bits [17:0] of 20-bit sum

        end
    endgenerate

endmodule
