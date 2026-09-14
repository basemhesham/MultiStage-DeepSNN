//===========================================================
// File        : top_weight_mapper.sv
// Purpose     : Selects the active convolution stage (conv1/conv2/conv3)
//               weight output and reshapes its flat 3456-entry stream
//               into a 3D array [block][lane][tap] = [12][32][9] for
//               consumption by the DSP48E2-based conv9 datapath.
//
// Architecture (post shared-index optimization for stage2/stage3):
//   - Stage1 (conv1) is unchanged: CONV1_W_MAP_OPT outputs real
//     18-bit weight values directly, no index/lookup involved.
//   - Stage2 (conv2) and Stage3 (conv3) now come from CONV2_W_MAP_IDX /
//     CONV3_W_MAP_IDX, which output 9-bit INDICES into a single
//     shared table (conv23_shared_pkg::SHARED_STAGE23_WEIGHTS, 378
//     entries merged from the two stages' original value tables).
//   - Level 1 mux selects between the two 9-bit index streams
//     (narrow mux, src_sel[0]) instead of two full 18-bit value
//     streams -- this is the actual congestion win: half the bits
//     passing through the mux compared to the old value-based mux.
//   - A single shared-table lookup (one per flat position) then
//     converts the selected index back to its real 18-bit value.
//   - Level 2 mux picks between stage1's direct value and the
//     shared-lookup result, based on whether src_sel selects stage1
//     at all (src_sel == 2'b00) or one of stage2/stage3 (everything
//     else, including the 2'b11 default case, which still correctly
//     resolves to stage2 through the Level 1 mux's src_sel[0]==1 path).
//   - Truth table is identical to the original single case-based mux:
//       00 -> stage1, 01 -> stage2, 10 -> stage3, 11 -> stage2 (default)
//     Verified by hand for all four src_sel values before this file
//     was written.
//
// Used in     : Top-level convolution engine (instantiates the three
//               weight-map sources and feeds weights_mapped into conv9.sv)
//===========================================================
// Editor      : congestion-optimized rewrite (shared stage2/stage3 index table)
//===========================================================

`timescale 1ns / 1ps

import conv23_shared_pkg::*;

module top_weight_mapper
#(
    parameter int PIXEL_W = 18      // bit width of a single signed weight value
)
(
    //=======================================================
    // Controls
    //=======================================================
    input  logic [1:0]                src_sel,        // 00: conv1 (stage1), 01: conv2 (stage2), 10: conv3 (stage3), 11: unused (defaults to stage2)
    //=======================================================
    // Inputs
    //=======================================================
    input  logic [5:0]                conv2_filter,    // filter/kernel select index fed into the conv2 weight source
    input  logic [6:0]                conv3_filter,    // filter/kernel select index fed into the conv3 weight source
    //=======================================================
    // Outputs
    //=======================================================
    // Reshaped weight cube: [block 0:11][lane 0:31][tap 0:8].
    // Driven combinationally (see gen_wmap_* generate block below),
    // so it is declared as plain "output logic", not "output reg".
    output logic signed [PIXEL_W-1:0] weights_mapped [0:11][0:31][0:8]
);

    //=======================================================
    // Internals
    //=======================================================
    // Stage1: real 18-bit values, straight from CONV1_W_MAP_OPT (unchanged).
    logic signed [PIXEL_W-1:0] stage1_weights [3456];

    // Stage2 / Stage3: 9-bit indices into the shared value table,
    // not real values -- must be looked up before use.
    logic [8:0] stage2_idx [3456];
    logic [8:0] stage3_idx [3456];

    // Level 1 mux result: still just an index (9 bits), selecting
    // which of stage2_idx/stage3_idx applies at each position.
    logic [8:0] stage23_idx [3456];

    // Real 18-bit value recovered from the shared table for whichever
    // index stage23_idx selected -- one lookup per flat position.
    logic signed [PIXEL_W-1:0] shared_val [3456];

    // Level 2 mux result: final selected stream (stage1 direct value,
    // or the shared-table lookup result for stage2/stage3).
    logic signed [PIXEL_W-1:0] active_weights [3456];

    //=======================================================
    // Weight sources
    //=======================================================
    CONV1_W_MAP_OPT u_w1 (
        .conv9_in (stage1_weights)
    );

    CONV2_W_MAP_IDX u_w2 (
        .filter    (conv2_filter),
        .conv9_idx (stage2_idx)
    );

    CONV3_W_MAP_IDX u_w3 (
        .filter    (conv3_filter),
        .conv9_idx (stage3_idx)
    );

    //=======================================================
    // Level 1 MUX (narrow, 9-bit): stage2 vs stage3 index select
    //=======================================================
    // src_sel[0]=1 -> stage2_idx, src_sel[0]=0 -> stage3_idx.
    // Correct for all cases that need it: 01->stage2, 10->stage3,
    // 11->stage2 (default). The 00 case doesn't need this result at
    // all (Level 2 mux below bypasses it for stage1), so its value
    // here is a don't-care when src_sel==00.
    assign stage23_idx = src_sel[0] ? stage2_idx : stage3_idx;

    //=======================================================
    // Shared-table lookup: index -> real 18-bit value
    //=======================================================
    genvar k;
    generate
        for (k = 0; k < 3456; k++) begin : g_shared_lookup
            assign shared_val[k] = SHARED_STAGE23_WEIGHTS[stage23_idx[k]];
        end
    endgenerate

    //=======================================================
    // Level 2 MUX (wide, 18-bit): stage1 direct value vs shared lookup
    //=======================================================
    // src_sel==2'b00 -> stage1_weights (direct, no lookup involved).
    // Anything else (01/10/11) -> shared_val, which Level 1 already
    // resolved to the correct stage2/stage3 value.
    assign active_weights = (src_sel == 2'b00) ? stage1_weights : shared_val;

    //=======================================================
    // Reshaping Logic (unchanged)
    //=======================================================
    genvar tree, conv9, in;
    generate
        for (tree = 0; tree < 12; tree++) begin
            for (conv9 = 0; conv9 < 32; conv9++) begin
                for (in = 0; in < 9; in++) begin
                    assign weights_mapped[tree][conv9][in] = active_weights[(tree*32*9)+(conv9*9)+in];
                end
            end
        end
    endgenerate

endmodule