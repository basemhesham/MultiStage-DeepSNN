`timescale 1ns / 1ps
//===========================================================
// File        : adder_tree_shaaban_connect.sv
// Purpose     : <one line description of what the module does>
// Used in     : <parent module / top level that instantiates this>
//===========================================================
// Written by  : <name>
// Editor      : <Ahmed Essam, if reviewed / modified by someone else>
// Last edit   : <2026-07-06>
//===========================================================

// =============================================================================
// adder_tree_shaaban_connect.sv
// -----------------------------------------------------------------------------
// TOP-LEVEL GLUE: Adder Trees → Shaaban Units
//
// SYSTEM CONTEXT
//   This module is the datapath bridge for Stage 1 of the MultiStage-DeepSNN
//   CNN-SNN hybrid. It sits between:
//     ← 12 adder_tree_10_4_1_1 instances  (receive 384 MAC products)
//     → 32 shaban_unit_top instances       (produce 32 spike outputs)
//
//   The same 32 Shaaban units are REUSED across all three pipeline stages
//   via a 3-way MUX controlled by src_sel. Only the input source changes.
//
// STAGE ROUTING  (src_sel)
//  ┌──────────┬─────────┬──────────────────────────────────────────────────┐
//  │ src_sel  │  Stage  │ Description                                      │
//  ├──────────┼─────────┼──────────────────────────────────────────────────┤
//  │  2'b00   │    1    │ 128 conv25 outputs → all 32 Shaabans (4 each)    │
//  │  2'b01   │    2    │ 12 tree finals → Shaabans 0,1,2 only (4 each)    │
//  │  2'b10   │    3    │ 4 accumulated sums → Shaaban 0 slots 0..3        │
//  └──────────┴─────────┴──────────────────────────────────────────────────┘
//
// STAGE 1 ASSEMBLY — WHY 120 TAPS ARE NOT ENOUGH
//   12 trees × 10 L1 taps = 120 direct conv25 results.
//   32 Shaabans × 4 inputs = 128 inputs needed.
//   The missing 8 come from ext_sum_correction (the orphan correction layer).
//
//   flat_s1 layout (128 entries):
//   ┌──────────────────────────────────────────────────────────────────────┐
//   │ Trees 0–7  (stride 11): flat_s1[t*11 .. t*11+9]  = taps[0..9]        │
//   │                         flat_s1[t*11 + 10]        = corr_out[t]      │
//   │ Trees 8–11 (stride 10): flat_s1[88+(t-8)*10 .. ] = taps[0..9]        │
//   └──────────────────────────────────────────────────────────────────────┘
//   Shaaban s ← flat_s1[s*4 .. s*4+3]
// =============================================================================

`timescale 1ns / 1ps

module adder_tree_shaaban_connect #(
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
    input  wire logic        clk,
    input  wire logic        rst,
    input  wire logic [1:0]  src_sel,   // 00=Stage1  01=Stage2  10=Stage3

    // 12 trees × 32 MAC products from Convolution Array
    input  wire logic signed [DATA_WIDTH-1:0] mac_in [0:N_TREES-1][0:31],

    // Output bus to the 32 Shaaban Units (each carries 4 inputs)
    output logic signed [(INPUTS_PER_SHB*DATA_WIDTH)-1:0] shb_conv_bus [0:N_SHAABAN-1]
);

    // =========================================================================
    // 1. ADDER TREE & CORRECTION LOGIC
    // =========================================================================
    wire logic signed [DATA_WIDTH-1:0] tree_tap   [0:N_TREES-1][0:TAPS_PER_TREE-1];
    wire logic signed [DATA_WIDTH-1:0] tree_final [0:N_TREES-1];
    wire logic signed [DATA_WIDTH-1:0] s3_results [0:3];

    genvar t, i;
    generate
        for (t = 0; t < N_TREES; t++) begin : gen_trees
            adder_tree_10_4_1_1 u_tree (
                .in_1 (mac_in[t][0]),  .in_2 (mac_in[t][1]),  .in_3 (mac_in[t][2]),
                .in_4 (mac_in[t][3]),  .in_5 (mac_in[t][4]),  .in_6 (mac_in[t][5]),
                .in_7 (mac_in[t][6]),  .in_8 (mac_in[t][7]),  .in_9 (mac_in[t][8]),
                .in_10(mac_in[t][9]),  .in_11(mac_in[t][10]), .in_12(mac_in[t][11]),
                .in_13(mac_in[t][12]), .in_14(mac_in[t][13]), .in_15(mac_in[t][14]),
                .in_16(mac_in[t][15]), .in_17(mac_in[t][16]), .in_18(mac_in[t][17]),
                .in_19(mac_in[t][18]), .in_20(mac_in[t][19]), .in_21(mac_in[t][20]),
                .in_22(mac_in[t][21]), .in_23(mac_in[t][22]), .in_24(mac_in[t][23]),
                .in_25(mac_in[t][24]), .in_26(mac_in[t][25]), .in_27(mac_in[t][26]),
                .in_28(mac_in[t][27]), .in_29(mac_in[t][28]), .in_30(mac_in[t][29]),
                .in_31(mac_in[t][30]), .in_32(mac_in[t][31]),

                .conv25_1 (tree_tap[t][0]), .conv25_2 (tree_tap[t][1]),
                .conv25_3 (tree_tap[t][2]), .conv25_4 (tree_tap[t][3]),
                .conv25_5 (tree_tap[t][4]), .conv25_6 (tree_tap[t][5]),
                .conv25_7 (tree_tap[t][6]), .conv25_8 (tree_tap[t][7]),
                .conv25_9 (tree_tap[t][8]), .conv25_10(tree_tap[t][9]),

                .final_output(tree_final[t])
            );
        end
        
        // Stage 3 Pairwise Summation: four 64-channel 3x3 window sums.
        // Add two trees to have 64-channel
        for (i = 0; i < 4; i++) begin : gen_s3_sums
            assign s3_results[i] = tree_final[2*i] + tree_final[2*i+1];
        end
    endgenerate
    // =========================================================================
    // 2. SEPARATE INPUT LOGIC: EXTERNAL SUM CORRECTION
    // -------------------------------------------------------------------------
    // Consumes the 24 "extra" MAC products (indices 30 and 31 from 12 trees) 
    // in a continuous flat sequence to feed 8 adders (3 inputs each).
    // For any correction 'c', its 3 inputs have global pool indices: 3c, 3c+1, 3c+2.
    // Tree Index = (global_index) / 2
    // Port Index = 30 + ((global_index) % 2)
    // =========================================================================
    wire logic signed [DATA_WIDTH-1:0] non_tap [0:(N_TREES*2)-1];   // the last 2 conv in each tree
    wire logic signed [DATA_WIDTH-1:0] ext_sum_correction [0:N_CORRECTION-1]; 

    genvar c;
    generate
        for (c = 0; c < N_TREES; c++) begin : gen_correction
            assign non_tap[2*c]   = mac_in[c][30];
            assign non_tap[2*c+1] = mac_in[c][31];
        end
    endgenerate

    sum_correction #(.DATA_WIDTH(DATA_WIDTH), .N_TREES(N_TREES), .N_CORRECTION(N_CORRECTION))
               sum_corr (.non_tap(non_tap), .corr_out(ext_sum_correction));

    // =========================================================================
    // 3. STAGE 1 DATA ASSEMBLY
    // -------------------------------------------------------------------------
    // Each three-tree shift group produces 32 ordered CONV25 results:
    //   tree 3g taps, correction 2g,
    //   tree 3g+1 taps, correction 2g+1,
    //   tree 3g+2 taps.
    // For simplification to put the addition from different trees in its right order
    // the special case for stage 1
    // =========================================================================
    wire logic signed [DATA_WIDTH-1:0] flat_s1 [0:TOTAL_S1_INPUTS-1];

    order_correction #(.DATA_WIDTH(DATA_WIDTH), .N_TREES(N_TREES), .INPUTS_PER_SHB(INPUTS_PER_SHB),
                       .N_SHAABAN(N_SHAABAN), .TAPS_PER_TREE  (TAPS_PER_TREE))
            order_corr(.tree_tap(tree_tap), .ext_sum_correction(ext_sum_correction), .flat_s1(flat_s1));

    // =========================================================================
    // 4. BUS MAPPING & MUXING
    // =========================================================================

    mapping_muxing #(.DATA_WIDTH(DATA_WIDTH), .N_TREES(N_TREES),
                     .INPUTS_PER_SHB(INPUTS_PER_SHB), .N_SHAABAN(N_SHAABAN))
            map_mux( .flat_s1(flat_s1), .tree_final(tree_final), .s3_results(s3_results), .src_sel(src_sel),
                     .shb_conv_bus(shb_conv_bus));

endmodule
