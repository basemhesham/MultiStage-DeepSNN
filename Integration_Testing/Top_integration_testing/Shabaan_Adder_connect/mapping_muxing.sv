`timescale 1ns / 1ps

//===========================================================
// File        : mapping_muxing.sv
// Purpose     : BUS MAPPING & MUXING
// Used in     : adder_tree_shaaban_connect.sv
//===========================================================
// Written by  : Ahmed Essam
// Editor      : <, if reviewed / modified by someone else>
// Last edit   : <2026-07-06>
//===========================================================

    // =========================================================================
    // 4. BUS MAPPING & MUXING
    // =========================================================================

module mapping_muxing #(
    parameter int N_TREES        = 12,
    parameter int N_SHAABAN      = 32,
    parameter int INPUTS_PER_SHB = 4,       // For Pooling each input has MUX to determine the stage.
    parameter int DATA_WIDTH     = 18,

    // Derived parameters
    parameter int TOTAL_S1_INPUTS  = N_SHAABAN * INPUTS_PER_SHB       // 128
)(
    input  wire logic [1:0]  src_sel,   // 00=Stage1  01=Stage2  10=Stage3
    input  wire logic signed [DATA_WIDTH-1:0] flat_s1 [0:TOTAL_S1_INPUTS-1],
    input  wire logic signed [DATA_WIDTH-1:0] tree_final [0:N_TREES-1],
    input  wire logic signed [DATA_WIDTH-1:0] s3_results [0:3],

    // Output bus to the 32 Shaaban Units (each carries 4 inputs)
    output logic signed [(INPUTS_PER_SHB*DATA_WIDTH)-1:0] shb_conv_bus [0:N_SHAABAN-1]
);

    genvar s, p;
    generate
        for (s = 0; s < N_SHAABAN; s++) begin : gen_shb_bus
            wire logic signed [(INPUTS_PER_SHB*DATA_WIDTH)-1:0] src_s1, src_s2, src_s3;

            for (p = 0; p < INPUTS_PER_SHB; p++) begin : map_sources
                // Stage 1: 10 Taps + Correction
                assign src_s1[p*DATA_WIDTH +: DATA_WIDTH] = flat_s1[s * INPUTS_PER_SHB + p];
                
                // Stage 2: Tree Finals
                if (s < 3) // 12 trees / 4 inputs = 3 units
                    assign src_s2[p*DATA_WIDTH +: DATA_WIDTH] = tree_final[s * INPUTS_PER_SHB + p];
                else 
                    assign src_s2[p*DATA_WIDTH +: DATA_WIDTH] = '0;

                // Stage 3: four pairwise sums feed Shaaban 0 only.
                if (s == 0)
                    assign src_s3[p*DATA_WIDTH +: DATA_WIDTH] = s3_results[p];
                else
                    assign src_s3[p*DATA_WIDTH +: DATA_WIDTH] = '0;
            end

            always_comb begin
                unique case (src_sel)
                    2'b00:   shb_conv_bus[s] = src_s1;
                    2'b01:   shb_conv_bus[s] = src_s2;
                    2'b10:   shb_conv_bus[s] = src_s3;
                    default: shb_conv_bus[s] = '0;
                endcase
            end
        end
    endgenerate

endmodule : mapping_muxing