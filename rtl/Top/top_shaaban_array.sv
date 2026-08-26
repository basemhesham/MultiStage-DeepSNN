`timescale 1ns / 1ps

// =====================================================================================
// Module name : top_shaaban_array
// Purpose     : Array wrapper that instantiates N_SHAABAN parallel Shaaban units.
//               ** HIERARCHY EDIT: fetch and BRAM_LIF_Mem_0 are no longer owned
//               anywhere under this array - deep_snn_top now instantiates 32
//               individual fetch + 32 individual BRAM_LIF_Mem_0 pairs directly and
//               exchanges hist_in/hist_out with this array on a per-lane basis.
//               ADDR_WIDTH/DEPTH and frame_start are dropped since neither address
//               generation nor storage lives under this hierarchy anymore. **
// =====================================================================================

module top_shaaban_array #(
    parameter int DATA_WIDTH     = 18,
    parameter int N_SHAABAN      = 32,
    parameter int INPUTS_PER_SHB = 4,
    parameter signed [DATA_WIDTH-1:0] THRESHOLD = 18'd512,
    parameter signed [DATA_WIDTH-1:0] ZERO      = 18'd0
)(
    input  logic                                      clk,
    input  logic                                      rst,

    // Control Signals for Time-Multiplexed LIF
    input  logic                                      first_frame, // High during Frame 0
    input  logic                                      new_data_en [0:N_SHAABAN-1]  , // High when data is a new valid stride
    
    // Data and Parameter Inputs
    input  wire logic signed [(INPUTS_PER_SHB*DATA_WIDTH)-1:0] shb_bus [0:N_SHAABAN-1],
    input  wire logic signed [DATA_WIDTH-1:0]              conv_bias_param   [0:N_SHAABAN-1],
    input  wire logic signed [DATA_WIDTH-1:0]              mult_weight_param [0:N_SHAABAN-1],
    input  wire logic signed [DATA_WIDTH-1:0]              add_weight_param  [0:N_SHAABAN-1],

    // Memory-facing interface: one BRAM per lane, instantiated in deep_snn_top
    input  wire logic signed [DATA_WIDTH-1:0]              hist_in  [0:N_SHAABAN-1], // H[t-1] per lane, from external BRAM
    output wire logic signed [DATA_WIDTH-1:0]              hist_out [0:N_SHAABAN-1], // H[t] per lane, to external BRAM
    
    // Spike Outputs
    output wire logic        [N_SHAABAN-1:0]               spike_out,
    output wire logic        /*[0:31]*/                    shaaban_spike_bus [0:N_SHAABAN-1],

    output wire logic signed [DATA_WIDTH-1:0]              hist_out_dbg [0:N_SHAABAN-1] // Debug history
);

    genvar s;
    generate
        for (s = 0; s < N_SHAABAN; s++) begin : gen_shaaban_array
            shaban_unit_top #(
                .DATA_WIDTH         (DATA_WIDTH),
                .conv_bias_relu_num (INPUTS_PER_SHB),
                .batch_norm_num     (INPUTS_PER_SHB),
                .pool_num           (2),
                .THRESHOLD          (THRESHOLD),
                .ZERO               (ZERO)
            ) u_shb (
                .clk          (clk),
                .rst          (rst),
                
                // Binding the control signals 
                // (Broadcast globally to all parallel units)
                .first_frame  (first_frame),
                .new_data_en  (new_data_en[s]),
                
                .conv_in      (shb_bus[s]),
                .conv_bias    (conv_bias_param[s]),
                .mult_wight   (mult_weight_param[s]),
                .add_wight    (add_weight_param[s]),

                // Per-lane memory interface
                .hist_in      (hist_in[s]),
                .hist_out     (hist_out[s]),
                
                // Binding the outputs to arrays
                .hist_out_dbg (hist_out_dbg[s]),
                .spike        (spike_out[s])
            );

            // Legacy spike bus assignment
            assign shaaban_spike_bus[s] = spike_out[s];
        end
    endgenerate

endmodule