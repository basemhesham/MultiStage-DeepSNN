module conv_Adder_shaaban_top #(
    parameter DATA_WIDTH     = 18,
    parameter N_SHAABAN      = 32,
    parameter MAC_OUT_W      = 40,
    parameter INPUTS_PER_SHB = 4,
    parameter N_TREES        = 12
)(
    input  logic                         clk,
    input  logic                         rst,
    input  logic [1:0]                   src_sel,
    // Shaaban inputs
    input  logic signed [DATA_WIDTH-1:0] conv_bias_param   [0:N_SHAABAN-1], // always 0
    input  logic signed [DATA_WIDTH-1:0] mult_weight_param [0:N_SHAABAN-1],
    input  logic signed [DATA_WIDTH-1:0] add_weight_param  [0:N_SHAABAN-1],
    // Convolution inputs
    input  logic signed [DATA_WIDTH-1:0]    pixels_mapped  [0:N_TREES-1][0:N_SHAABAN-1][0:8],
    input  logic signed [DATA_WIDTH-1:0]    weights_mapped [0:N_TREES-1][0:N_SHAABAN-1][0:8],
    // Outputs
    output logic [N_SHAABAN-1:0] spike_out,                       // Final spike outputs
    output logic [0:N_SHAABAN-1] shaaban_spike_bus [0:N_SHAABAN-1]// Individual Shaaban spike buses

);

    wire logic signed [DATA_WIDTH-1:0] mac_to_connect [0:N_TREES-1][0:N_SHAABAN-1];

    top_conv9_array #(
        .PIXEL_W    (DATA_WIDTH),
        .MAC_OUT_W  (MAC_OUT_W),
        .DATA_WIDTH (DATA_WIDTH)
    ) u_conv9_array (
        .clk            (clk),
        .pixels_mapped  (pixels_mapped),
        .weights_mapped (weights_mapped),
        .mac_to_connect (mac_to_connect)
    );

    shaaban_adder_tree_top #(
        .DATA_WIDTH     (DATA_WIDTH),
        .N_SHAABAN      (N_SHAABAN),
        .INPUTS_PER_SHB (INPUTS_PER_SHB),
        .N_TREES        (N_TREES)
    ) u_shaaban_adder_tree (
        .clk                (clk),
        .rst                (rst),
        .src_sel            (src_sel),
        .mac_in             (mac_to_connect),
        .conv_bias_param    (conv_bias_param),
        .mult_weight_param  (mult_weight_param),
        .add_weight_param   (add_weight_param),
        .spike_out          (spike_out),
        .shaaban_spike_bus  (shaaban_spike_bus)
    );

endmodule