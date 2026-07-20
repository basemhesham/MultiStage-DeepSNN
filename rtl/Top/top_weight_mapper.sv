//===========================================================
// File        : top_weight_mapper.sv
// Purpose     : Selects the active convolution stage (conv1/conv2/conv3)
//               weight ROM output and reshapes its flat 3456-entry
//               stream into a 3D array [block][lane][tap] = [12][32][9]
//               for consumption by the DSP48E2-based conv9 datapath.
//               Stage-1 weights require an extra per-block lane
//               reordering step (stage1_idx lookup) to undo the
//               interleaved packing used when the stage-1 weight ROM
//               was generated. Reorder logic was refactored from an
//               automatic function into a combinational always_comb
//               lookup table (see stage1_idx below).
// Used in     : Top-level convolution engine (instantiates the three
//               weight-map ROMs and feeds weights_mapped into conv9.sv)
//===========================================================
// Written by  : 
// Editor      : Boutros George Sabri
// Last edit   : 2026-7-8
//===========================================================

`timescale 1ns / 1ps

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
    input  logic [5:0]                conv2_filter,    // filter/kernel select index fed into the conv2 weight ROM
    input  logic [6:0]                conv3_filter,    // filter/kernel select index fed into the conv3 weight ROM
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
    logic signed [PIXEL_W-1:0] stage1_weights [3456];   // conv1 weight stream (needs lane reorder, see stage1_idx)
    logic signed [PIXEL_W-1:0] stage2_weights [3456];   // conv2 weight stream (already in physical order)
    logic signed [PIXEL_W-1:0] stage3_weights [3456];   // conv3 weight stream (already in physical order)
    logic signed [PIXEL_W-1:0] active_weights [3456];   // mux output: whichever stream src_sel selects (used for stage2/stage3 path)

    //=======================================================
    // Weight ROM instances
    //=======================================================
    // One ROM per convolution stage. Only conv2/conv3 take a filter
    // select input; conv1 has a single fixed weight set.
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
    // active_weights mux
    //=======================================================
    // Selects the flat stream for the currently active stage.
    // Only actually used downstream when src_sel != 2'b00 (stage1
    // is read directly from stage1_weights via the stage1_idx
    // lookup instead, see gen_wmap_* below).
    always_comb
    begin
        case (src_sel)
            2'b00:   active_weights = stage1_weights;  // conv1 (unused on this path, kept for completeness)
            2'b01:   active_weights = stage2_weights;  // conv2
            2'b10:   active_weights = stage3_weights;  // conv3
            default: active_weights = stage2_weights;  // 2'b11: undefined select, default to conv2
        endcase
    end

    //=======================================================
    // stage1_idx lookup (formerly stage1_stream_index function)
    //=======================================================
    // Stage-1 weights are packed into stage1_weights using a
    // 3-block-periodic lane rotation instead of straight physical
    // (block*32 + lane) order. Rather than a procedural for loop
    // inside one always_comb, this uses the same generate/genvar
    // style as the rest of the file: one always_comb is replicated
    // 12*32 = 384 times at elaboration time (once per block/lane
    // pair), each instance computing exactly one entry of the
    // stage1_idx lookup table:
    //   block % 3 == 0 : identity            (no rotation)
    //   block % 3 == 1 : lanes rotated left by 1  (lane -> lane+1, wraps 30/31 -> 0)
    //   block % 3 == 2 : lanes rotated left by 2  (lane -> lane+2, wraps last two -> 0/1)
    logic [11:0] stage1_idx [0:11][0:31];

    genvar gi, ci;
    generate
        for (gi = 0; gi < 12; gi++) begin : gen_stage1_idx_row     // gi: block index (0-11)
            for (ci = 0; ci < 32; ci++) begin : gen_stage1_idx_col // ci: lane index within block (0-31)
                always_comb begin
                    case (gi % 3)
                        //===========================================
                        // Rotation 0: no shift, physical == logical
                        //===========================================
                        0: stage1_idx[gi][ci] = (gi * 32) + ci;

                        //===========================================
                        // Rotation 1: shift lanes left by 1, with
                        // lane 30 -> 0 and lane 31 -> unused/last slot
                        //===========================================
                        1: stage1_idx[gi][ci] = (gi * 32) +
                                                ((ci < 30) ? ci + 1 :
                                                 (ci == 30) ? 0 : 31);

                        //===========================================
                        // Rotation 2: shift lanes left by 2, wrapping
                        // the top two lanes back to 0/1
                        //===========================================
                        default:
                           stage1_idx[gi][ci] = (gi * 32) +
                                                ((ci < 30) ? ci + 2 : ci - 30);
                    endcase
                end
            end
        end
    endgenerate

    //=======================================================
    // weights_mapped reshape (block x lane x tap)
    //=======================================================
    // Unrolls the flat 3456-entry stream(s) into the 3D
    // weights_mapped cube expected by the conv9 datapath.
    // Stage-1 reads through the stage1_idx lookup to undo the
    // ROM's interleaved packing; all other stages read
    // active_weights directly using straight physical indexing
    // (block * 32 + lane) * 9 + tap.
    genvar gw, cw, tw;
    generate
        for (gw = 0; gw < 12; gw++) begin : gen_wmap_row       // gw: block index (0-11)
            for (cw = 0; cw < 32; cw++) begin : gen_wmap_col   // cw: lane index within block (0-31)
                for (tw = 0; tw < 9; tw++) begin : gen_wmap_tap // tw: tap index within a 3x3 kernel, flattened (0-8)

                    // Straight physical index for non-stage1 sources
                    localparam int PHYSICAL_INDEX = (gw * 32) + cw;

                    always_comb begin
                        if (src_sel == 2'b00) begin
                            //===================================
                            // Stage1 path: use reordered index
                            // from the stage1_idx lookup table
                            //===================================
                            weights_mapped[gw][cw][tw] =
                                $signed(stage1_weights[
                                    (stage1_idx[gw][cw] * 9) + tw
                                ]);
                        end else begin
                            //===================================
                            // Stage2/Stage3 path: straight index
                            //===================================
                            weights_mapped[gw][cw][tw] =
                                $signed(active_weights[
                                    (PHYSICAL_INDEX * 9) + tw
                                ]);
                        end
                    end

                end
            end
        end
    endgenerate
    //=======================================================

endmodule