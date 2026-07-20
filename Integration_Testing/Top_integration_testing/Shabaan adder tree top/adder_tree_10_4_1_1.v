`timescale 1ns / 1ps
// =============================================================================
// adder_tree_10_4_1_1.v
// 32-input adder tree using explicit DSP48E2 arithmetic blocks
//
// Structure:
//   Layer 1: 10 x adder_layer1  (3 inputs each ? 30 of 32 inputs)
//            in_31, in_32 are orphans handled in layer2__4
//   Layer 2: 4 x adder_layer2   (3 inputs each, last group uses orphans)
//   Layer 3: 1 x adder_layer3   (3 inputs ? L2_1, L2_2, L2_3)
//   Layer 4: 1 x adder_layer4   (2 inputs ? L2_4 + L3)
//   Output:  final_output = 18-bit Q8.9 sum
// =============================================================================

module adder_tree_10_4_1_1(
    input  wire signed [17:0] in_1,  in_2,  in_3,  in_4,
    input  wire signed [17:0] in_5,  in_6,  in_7,  in_8,
    input  wire signed [17:0] in_9,  in_10, in_11, in_12,
    input  wire signed [17:0] in_13, in_14, in_15, in_16,
    input  wire signed [17:0] in_17, in_18, in_19, in_20,
    input  wire signed [17:0] in_21, in_22, in_23, in_24,
    input  wire signed [17:0] in_25, in_26, in_27, in_28,
    input  wire signed [17:0] in_29, in_30, in_31, in_32,

    output wire signed [17:0] conv25_1,
    output wire signed [17:0] conv25_2,
    output wire signed [17:0] conv25_3,
    output wire signed [17:0] conv25_4,
    output wire signed [17:0] conv25_5,
    output wire signed [17:0] conv25_6,
    output wire signed [17:0] conv25_7,
    output wire signed [17:0] conv25_8,
    output wire signed [17:0] conv25_9,
    output wire signed [17:0] conv25_10,

    output wire signed [17:0] final_output
);

    // =========================================================================
    // Layer 1: 10 x 3-input adders  (18-bit in ? 20-bit out)
    // =========================================================================
    wire signed [19:0] L1_1, L1_2, L1_3, L1_4, L1_5;
    wire signed [19:0] L1_6, L1_7, L1_8, L1_9, L1_10;

    adder_layer1 layer_1__1  (.add_1(in_1),  .add_2(in_2),  .add_3(in_3),  .adder_out(L1_1)  );
    adder_layer1 layer_1__2  (.add_1(in_4),  .add_2(in_5),  .add_3(in_6),  .adder_out(L1_2)  );
    adder_layer1 layer_1__3  (.add_1(in_7),  .add_2(in_8),  .add_3(in_9),  .adder_out(L1_3)  );
    adder_layer1 layer_1__4  (.add_1(in_10), .add_2(in_11), .add_3(in_12), .adder_out(L1_4)  );
    adder_layer1 layer_1__5  (.add_1(in_13), .add_2(in_14), .add_3(in_15), .adder_out(L1_5)  );
    adder_layer1 layer_1__6  (.add_1(in_16), .add_2(in_17), .add_3(in_18), .adder_out(L1_6)  );
    adder_layer1 layer_1__7  (.add_1(in_19), .add_2(in_20), .add_3(in_21), .adder_out(L1_7)  );
    adder_layer1 layer_1__8  (.add_1(in_22), .add_2(in_23), .add_3(in_24), .adder_out(L1_8)  );
    adder_layer1 layer_1__9  (.add_1(in_25), .add_2(in_26), .add_3(in_27), .adder_out(L1_9)  );
    adder_layer1 layer_1__10 (.add_1(in_28), .add_2(in_29), .add_3(in_30), .adder_out(L1_10) );

    // Inputs are already converted back to Q8.9 by top_conv9_array.
    assign conv25_1  = L1_1 [17:0];
    assign conv25_2  = L1_2 [17:0];
    assign conv25_3  = L1_3 [17:0];
    assign conv25_4  = L1_4 [17:0];
    assign conv25_5  = L1_5 [17:0];
    assign conv25_6  = L1_6 [17:0];
    assign conv25_7  = L1_7 [17:0];
    assign conv25_8  = L1_8 [17:0];
    assign conv25_9  = L1_9 [17:0];
    assign conv25_10 = L1_10[17:0];

    // =========================================================================
    // Layer 2: 4 x 3-input adders  (20-bit in ? 22-bit out)
    // Group 4 handles the 2 orphan inputs (in_31, in_32) + L1_10
    // =========================================================================
    wire signed [21:0] L2_1, L2_2, L2_3;
    wire signed [21:0] L2_4;   // was [20:0] - fix width to match layer2

    adder_layer2 layer_2__1 (.add_1(L1_1),  .add_2(L1_2),  .add_3(L1_3),  .adder_out(L2_1));
    adder_layer2 layer_2__2 (.add_1(L1_4),  .add_2(L1_5),  .add_3(L1_6),  .adder_out(L2_2));
    adder_layer2 layer_2__3 (.add_1(L1_7),  .add_2(L1_8),  .add_3(L1_9),  .adder_out(L2_3));

    // Orphan group: L1_10 + in_31 + in_32
    // Sign-extend in_31, in_32 from 18-bit to 20-bit to match adder_layer2 IN_WIDTH
    wire signed [19:0] in_31_ext;
    assign in_31_ext = {{2{in_31[17]}}, in_31} ;   
   
    wire signed [19:0] in_32_ext ;
    assign in_32_ext = {{2{in_32[17]}}, in_32};

    adder_layer2 layer_2__4 (.add_1(L1_10), .add_2(in_31_ext), .add_3(in_32_ext), .adder_out(L2_4));

    // =========================================================================
    // Layer 3: 1 x 3-input adder  (22-bit in ? 24-bit out)
    // =========================================================================
    wire signed [23:0] L3;

    adder_layer3 layer_3 (
        .add_1(L2_1),
        .add_2(L2_2),
        .add_3(L2_3),
        .adder_out(L3)
    );

    // =========================================================================
    // Layer 4: 1 x 2-input adder  (24-bit + 22-bit ? 25-bit out)
    // =========================================================================
    wire signed [24:0] L4;

    adder_layer4 layer_4 (
        .add_1(L3),
        .add_2(L2_4),
        .adder_out(L4)
    );

    // =========================================================================
    // The inputs are already Q8.9 values. Adding channels increases the
    // integer width, not the number of fractional bits, so keep bits [17:0].
    // =========================================================================
    assign final_output = L4[17:0];

endmodule
