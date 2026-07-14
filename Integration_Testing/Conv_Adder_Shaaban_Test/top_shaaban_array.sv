`timescale 1ns / 1ps

module top_shaaban_array #(
    parameter int DATA_WIDTH     = 18,
    parameter int N_SHAABAN      = 32,
    parameter int INPUTS_PER_SHB = 4
)(
    input  logic                                      clk,
    input  logic                                      rst,
    input  logic signed [(INPUTS_PER_SHB*DATA_WIDTH)-1:0] shb_bus [0:N_SHAABAN-1],
    input  logic signed [DATA_WIDTH-1:0]              conv_bias_param   [0:N_SHAABAN-1],
    input  logic signed [DATA_WIDTH-1:0]              mult_weight_param [0:N_SHAABAN-1],
    input  logic signed [DATA_WIDTH-1:0]              add_weight_param  [0:N_SHAABAN-1],
    output logic [N_SHAABAN-1:0]                      spike_out,
    output logic [0:31]                               shaaban_spike_bus [0:N_SHAABAN-1]
);

    genvar s;
    generate
        for (s = 0; s < N_SHAABAN; s++) begin : gen_shaaban_array
            shaban_unit_top #(
                .DATA_WIDTH         (DATA_WIDTH),
                .conv_bias_relu_num (INPUTS_PER_SHB),
                .batch_norm_num     (INPUTS_PER_SHB),
                .pool_num           (2)
            ) u_shb (
                .clk        (clk),
                .rst        (rst),
                .conv_in    (shb_bus[s]),
                .conv_bias  (conv_bias_param[s]),
                .mult_wight (mult_weight_param[s]),
                .add_wight  (add_weight_param[s]),
                .spike      (spike_out[s])
            );

            assign shaaban_spike_bus[s] = {32{spike_out[s]}};
        end
    endgenerate

endmodule
