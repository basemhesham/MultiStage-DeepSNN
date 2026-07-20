//==================================================================================================
// File        : bias_bn_params.sv
// Purpose     : <it gives a cinst values difined by software to make the values not centered at 0>
// Used in     : <parent module / top level that instantiates this>
//==================================================================================================
// Written by  : <name>
// Editor      : <Hany>
// Last edit   : <2026-07-07>
//==================================================================================================

`timescale 1ns / 1ps

module bias_bn_params #(
    parameter int DATA_WIDTH     = 18,
    parameter int N_SHAABAN      = 32,
    parameter int CONV2_FILTER_W = 6,
    parameter int CONV3_FILTER_W = 7
)(   
    //=======================================================
    // Controls
    //=======================================================
    input  logic [1:0]                         stage,
    //=======================================================
    // Inputs
    //=======================================================
    input  logic [CONV2_FILTER_W-1:0]          conv2_filter,
    input  logic [CONV3_FILTER_W-1:0]          conv3_filter,
    //=======================================================
    // Outputs
    //=======================================================
    output logic signed [DATA_WIDTH-1:0]       conv_bias   [0:N_SHAABAN-1],
    output logic signed [DATA_WIDTH-1:0]       mult_weight [0:N_SHAABAN-1],
    output logic signed [DATA_WIDTH-1:0]       add_weight  [0:N_SHAABAN-1]
);

    //=======================================================
    // Internals
    //=======================================================
(* keep_hierarchy = "yes" *)
    generate
        if (1) begin : bn1_weight_table
            `include "BN1_WEIGHTS.sv"
        end

        if (1) begin : bn1_bias_table
            `include "BN1_BIAS.sv"
        end

        if (1) begin : bn2_weight_table
            `include "BN2_WEIGHTS.sv"
        end

        if (1) begin : bn2_bias_table
            `include "BN2_BIAS.sv"
        end

        if (1) begin : bn3_weight_table
            `include "BN3_WEIGHTS.sv"
        end

        if (1) begin : bn3_bias_table
            `include "BN3_BIAS.sv"
        end
    endgenerate

    genvar shb;
    generate
        for (shb = 0; shb < N_SHAABAN; shb = shb + 1) begin : gen_shb_bn_sel

            always_comb begin
                //===================================================
                // Defaults
                //===================================================
                conv_bias[shb]   = '0;
                mult_weight[shb] = '0;
                add_weight[shb]  = '0;

                //===================================================
                // Stage Case
                //===================================================
                unique case (stage)
                    2'b00: begin
                        //========================================================
                        // Stage 0 : passing required weights for 32 shaban units
                        //========================================================
                        mult_weight[shb] = bn1_weight_table.BN1_WEIGHTS[shb];
                        add_weight[shb]  = bn1_bias_table.BN1_BIAS[shb];
                    end

                    2'b01: begin
                        //========================================================================
                        // Stage 1 : passing required weights for 3 shaban units used for Stage 1
                        //========================================================================
                        if (shb < 3) begin
                            mult_weight[shb] = bn2_weight_table.BN2_WEIGHTS[conv2_filter];
                            add_weight[shb]  = bn2_bias_table.BN2_BIAS[conv2_filter];
                        end
                    end

                    2'b10: begin
                        //========================================================================
                        // Stage 2 : passing required weights for 1 shaban units used for Stage 2
                        //========================================================================
                        if (shb == 0) begin
                            mult_weight[shb] = bn3_weight_table.BN3_WEIGHTS[conv3_filter];
                            add_weight[shb]  = bn3_bias_table.BN3_BIAS[conv3_filter];
                        end
                    end

                    default: begin
                        conv_bias[shb]   = '0;
                        mult_weight[shb] = '0;
                        add_weight[shb]  = '0;
                    end
                endcase
            end
        end : gen_shb_bn_sel
    endgenerate

endmodule
