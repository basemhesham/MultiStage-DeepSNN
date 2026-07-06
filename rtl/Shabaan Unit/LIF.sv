// =====================================================================================
// Module name : LIF
// Purpose     : Leaky Integrate-and-Fire spiking neuron — final stage of each Shaaban
//               unit (Bias+ReLU -> BatchNorm -> MaxPool -> LIF). Integrates the pooled
//               convolution result into a membrane potential, applies a fixed decay
//               (beta = 0.5) every cycle, and fires a spike whenever the membrane
//               potential reaches the THRESHOLD. Uses a one-cycle-delayed reset
//               ("reset-before-spike, delay = 1") driven by the previous cycle's spike.
// Written by  : Unknown (original author not recorded)
// Revised by  : Mohamed Hussein
// Date        : July 5, 2026
// Notes       : Converted always -> always_ff / always_comb, and all wire/reg types ->
//               logic (ports and internals alike), as part of a readability and
//               testbench-prep revision pass. No functional change intended.
// Last edit   : July 6, 2026
// =====================================================================================

module LIF #(
    parameter DATA_WIDTH       = 18,
    parameter signed THRESHOLD = 18'd512,
    parameter signed ZERO      = 18'd0
) (
    input  wire logic clk,
    input  wire logic arst_n,
    input  wire logic signed [DATA_WIDTH-1:0] in_pool,
    output wire logic spike
);

    // --------------------------------------------------------------
    //  Internal Signals
    // --------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0] mem_reg;          // membrane potential, held between cycles
    logic                        spike_reg;         // previous cycle's spike flag (drives delayed reset)

    logic signed [DATA_WIDTH-1:0] reset_val;
    logic signed [DATA_WIDTH-1:0] mem_leak;
    logic signed [DATA_WIDTH-1:0] new_mem;
    logic signed [DATA_WIDTH-1:0] mem_input_add_trnuc;

    logic signed [DATA_WIDTH:0]   mem_input_add;    // 19-bit intermediate to prevent overflow
    logic                         spike_int;        // internal (combinational) spike

    // --------------------------------------------------------------
    //  Sequential : Membrane & Spike-History Update
    // --------------------------------------------------------------
    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            mem_reg    <= 'd0;
            spike_reg  <= 1'b0;
        end else begin
            mem_reg    <= new_mem;
            spike_reg  <= spike_int;
        end
    end

    // --------------------------------------------------------------
    //  Combinational : Delayed Reset Selection
    // --------------------------------------------------------------
    assign reset_val = spike_reg ? THRESHOLD : ZERO;

    // --------------------------------------------------------------
    //  Combinational : Leak (Decay by 0.5)
    // --------------------------------------------------------------
    assign mem_leak = mem_reg >>> 1;

    // --------------------------------------------------------------
    //  Combinational : Integrate (19-bit sum, then truncate)
    // --------------------------------------------------------------
    assign mem_input_add      = mem_leak + in_pool;
    assign mem_input_add_trnuc = mem_input_add[DATA_WIDTH-1:0];

    // --------------------------------------------------------------
    //  Combinational : Apply Delayed Reset
    // --------------------------------------------------------------
    assign new_mem = mem_input_add_trnuc - reset_val;

    // --------------------------------------------------------------
    //  Combinational : THRESHOLD Comparison / Spike Generation
    // --------------------------------------------------------------
    always_comb begin
        if (new_mem >= THRESHOLD) begin
            spike     = 1'b1;
            spike_int = 1'b1;
        end else begin
            spike     = 1'b0;
            spike_int = 1'b0;
        end
    end

endmodule