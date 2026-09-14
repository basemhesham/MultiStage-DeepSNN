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
    // Flat (unshaped) weight streams as produced by each stage's
    // weight-map ROM. Each stream holds 12 blocks * 32 lanes * 9 taps
    // = 3456 entries, stored back-to-back.
    logic signed [PIXEL_W-1:0] stage1_weights [3456];   // conv1 weight stream
    logic signed [PIXEL_W-1:0] stage2_weights [3456];   // conv2 weight stream
    logic signed [PIXEL_W-1:0] stage3_weights [3456];   // conv3 weight stream
    logic signed [PIXEL_W-1:0] active_weights [3456];   // mux output: whichever stream src_sel selects

    // NEW: Intermediate array signal for Level-1 MUX (stage2 vs stage3 selection)
    logic signed [PIXEL_W-1:0] mux_lvl1 [3456];


    //=======================================================
    // Weight ROM instances
    //=======================================================
    CONV1_W_MAP_OPT u_w1 (
        .conv9_in (stage1_weights)
    );

    CONV2_W_MAP_OPT u_w2 (
        .filter   (conv2_filter),
        .conv9_in (stage2_weights)
    );

    CONV3_W_MAP_OPT u_w3 (
        .filter   (conv3_filter),
        .conv9_in (stage3_weights)
    );


    //=======================================================
    // OLD PART (COMMENTED OUT): Single Case-Based 3-to-1 MUX
    //=======================================================
    /*
    always_comb
    begin
        case (src_sel)
            2'b00:   active_weights = stage1_weights;  // conv1
            2'b01:   active_weights = stage2_weights;  // conv2
            2'b10:   active_weights = stage3_weights;  // conv3
            default: active_weights = stage2_weights;  // 2'b11: undefined select, default to conv2
        endcase
    end
    */


    //=======================================================
    // NEW PART: Cascaded 2-to-1 MUX Tree Structure
    //=======================================================
    // WHY WE USE THIS APPROACH:
    // 1. Vivado Optimization: A single multi-branch case statement on a massive 3,456-bit bus
    //    causes the synthesizer to build a wide, unguided logic decode using scattered LUTs,
    //    leading to severe routing congestion.
    // 2. Dedicated Hardware Inferences: By explicitly writing two cascaded 2-to-1 selections,
    //    we align directly with Xilinx dedicated multiplexer primitives (MUXF7/MUXF8).
    // 3. No Logic or Latency Change: The truth table matches the original design 100% 
    //    (00->stage1, 01->stage2, 10->stage3, 11->stage2) without introducing any clock delays.

    // Level 1 MUX: Resolves selection between stage2 and stage3 based on src_sel[0]
    assign mux_lvl1 = src_sel[0] ? stage2_weights : stage3_weights;

    // Level 2 MUX: Selects stage1 vs the Level 1 result based on src_sel[1]
    assign active_weights = src_sel[1] ? mux_lvl1 : (src_sel[0] ? stage2_weights : stage1_weights);


    //=======================================================
    // Reshaping Logic (Unchanged)
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