// =====================================================================================
// Module name : shaban_unit_top
// Purpose     : Top-level wrapper for a single Shaaban Unit. Connects the
//               Convolution, Batch Norm, Pooling, and the LIF (via lif_mem_top's
//               re-timing wrapper) modules.
//               ** HIERARCHY EDIT: fetch and BRAM_LIF_Mem_0 are no longer
//               instantiated anywhere under this module - they now live directly
//               in deep_snn_top (x32 each), one pair per Shaaban unit. This module
//               now exchanges hist_in/hist_out with that external per-lane BRAM
//               instance instead of owning its own fetch+BRAM pair. ADDR_WIDTH/
//               DEPTH and frame_start are dropped since neither address generation
//               nor storage lives here anymore. **
// =====================================================================================

module shaban_unit_top #(
    parameter DATA_WIDTH = 18, 
    parameter conv_bias_relu_num = 4, 
    parameter batch_norm_num = 4, 
    parameter pool_num = 2,
    
    // Parameters for lif_mem_top
    parameter signed [DATA_WIDTH-1:0] THRESHOLD = 18'd512,
    parameter signed [DATA_WIDTH-1:0] ZERO      = 18'd0
) (
    input  wire clk,
    input  wire rst, // Note: This connects to arst_n in lif_mem_top

    // Control Signals for Time-Multiplexed LIF
    input  wire first_frame, // High during Frame 0
    input  wire new_data_en, // High when data is not an overlap

    input  wire signed [(conv_bias_relu_num*DATA_WIDTH)-1:0] conv_in,
    input  wire signed [DATA_WIDTH-1:0] conv_bias,
    input  wire signed [DATA_WIDTH-1:0] mult_wight,
    input  wire signed [DATA_WIDTH-1:0] add_wight,

    // Memory-facing interface (now driven from the per-lane BRAM instance in
    // deep_snn_top, routed through top_shaaban_array)
    input  wire signed [DATA_WIDTH-1:0] hist_in,      // H[t-1], from the external BRAM
    output wire signed [DATA_WIDTH-1:0] hist_out,      // H[t], to the external BRAM

    // Outputs from lif_mem_top
    output wire                    spike,        // S[t] output
    output wire signed [DATA_WIDTH-1:0] hist_out_dbg // H[t] debug output (= hist_out)
);

    // --------------------------------------------------------------
    // Internal Signals
    // --------------------------------------------------------------
    wire signed [DATA_WIDTH-1:0] conv_bias_relu_out [0:conv_bias_relu_num-1];
    wire signed [DATA_WIDTH-1:0] batch_norm_out [0:batch_norm_num-1];
    wire signed [DATA_WIDTH-1:0] max_pool_out [0:pool_num-1];
    wire signed [DATA_WIDTH-1:0] final_pool_out;

    genvar i;

    // --------------------------------------------------------------
    // Convolution, Bias, and ReLU Stage
    // --------------------------------------------------------------
    generate 
        for (i = 0; i < conv_bias_relu_num; i = i+1) begin : gen_conv
            conv_bias_Relu conv_bias_Relu_inst(
                .conv_in   (conv_in[i*DATA_WIDTH +: DATA_WIDTH]),
                .conv_bias (conv_bias),
                .conv_out  (conv_bias_relu_out[i]) 
            );
        end
    endgenerate

    // --------------------------------------------------------------
    // Batch Normalization Stage
    // --------------------------------------------------------------
    generate 
        for (i = 0; i < batch_norm_num; i = i+1) begin : gen_bn
            Batch_Norm Batch_Norm_inst (
                .Batch_Norm_in (conv_bias_relu_out[i]),
                .mult_wight    (mult_wight),
                .add_wight     (add_wight),
                .Batch_Norm_out(batch_norm_out[i]) 
            );
        end
    endgenerate

    // --------------------------------------------------------------
    // Max Pooling Stage
    // --------------------------------------------------------------
    Max_pooling Max_pooling_inst0 (
        .pool_in1(batch_norm_out[0]),
        .pool_in2(batch_norm_out[1]),
        .pool_out(max_pool_out[0]) 
    );
        
    Max_pooling Max_pooling_inst1 (
        .pool_in1(batch_norm_out[2]),
        .pool_in2(batch_norm_out[3]),
        .pool_out(max_pool_out[1]) 
    );   
       
    Max_pooling Max_pooling_inst2 (
        .pool_in1(max_pool_out[0]),
        .pool_in2(max_pool_out[1]),
        .pool_out(final_pool_out) 
    );       

    // --------------------------------------------------------------
    // LIF (via lif_mem_top's re-timing wrapper) — memory now external
    // --------------------------------------------------------------
    // Note: rst is passed to arst_n. Ensure your global reset logic 
    // matches this active-low or active-high expectation.
    lif_mem_top #(
        .DATA_WIDTH (DATA_WIDTH),
        .THRESHOLD  (THRESHOLD),
        .ZERO       (ZERO)
    ) lif_mem_top_inst (
        .clk          (clk),
        .arst_n       (rst),          // Mapping top-level rst to lif_mem_top's arst_n
        .first_frame  (first_frame),
        .new_data_en  (new_data_en),
        .in_pool      (final_pool_out),
        .hist_in      (hist_in),
        .hist_out     (hist_out),
        .spike_out    (spike),
        .hist_out_dbg (hist_out_dbg)
    );

endmodule