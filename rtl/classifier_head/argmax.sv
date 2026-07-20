//===========================================================
// File        : argmax4.sv
// Purpose     : Find the max value and its index among the 4 class
//               logits produced by fc2_layer. Ties resolve to the
//               LOWEST index (first max wins), matching common
//               argmax/np.argmax convention.
//               1-cycle latency: captures fc_out on `valid_in` (wire
//               this to fc2_layer's `done`), result appears the
//               following cycle on max_idx/max_val with valid_out=1.
// Used in     : top-level inference pipeline, right after fc2_layer,
//               to turn the 4 raw logits into a single predicted class.
//===========================================================

`ifndef ARGMAX4_SV
`define ARGMAX4_SV

module argmax4
#(
    parameter int DATA_WIDTH = 18,   // must match fc2_layer's DATA_WIDTH (Q_.FRAC_BITS)
    parameter int N_OUTPUTS  = 4     // number of candidates (this impl is a 4-way tree)
)
(
    //=======================================================
    // Controls
    //=======================================================
    input  wire logic                          clk,
    input  wire logic                          arst_n,
    input  wire logic                          valid_in,   // e.g. fc2_layer's `done`
    //=======================================================
    // Inputs
    //=======================================================
    input  wire signed [DATA_WIDTH-1:0]        data_in [0:N_OUTPUTS-1],  // e.g. fc2_layer's fc_out
    //=======================================================
    // Outputs
    //=======================================================
    output reg   signed [DATA_WIDTH-1:0]       max_val,
    output reg   [$clog2(N_OUTPUTS)-1:0]       max_idx,
    output reg                                 valid_out
);

    //=======================================================
    // combinational compare tree
    //=======================================================
    // Stage 0: pairwise compare (0 vs 1), (2 vs 3).
    // Stage 1: compare the two winners.
    // Ties resolve to the lower index at every stage (>= on the left operand
    // keeps it winning on equality since it's compared first).
    wire signed [DATA_WIDTH-1:0]      val_01, val_23, val_final;
    wire        [$clog2(N_OUTPUTS)-1:0] idx_01, idx_23, idx_final;

    assign val_01 = (data_in[0] >= data_in[1]) ? data_in[0] : data_in[1];
    assign idx_01 = (data_in[0] >= data_in[1]) ? 2'd0        : 2'd1;

    assign val_23 = (data_in[2] >= data_in[3]) ? data_in[2] : data_in[3];
    assign idx_23 = (data_in[2] >= data_in[3]) ? 2'd2        : 2'd3;

    assign val_final = (val_01 >= val_23) ? val_01 : val_23;
    assign idx_final = (val_01 >= val_23) ? idx_01 : idx_23;

    //=======================================================
    // capture_stage
    //=======================================================
    // Registers the tree's result exactly one cycle after valid_in fires,
    // so max_idx/max_val/valid_out line up together.
    always_ff @(posedge clk or negedge arst_n)
    begin
        if (!arst_n)
        begin
            max_val   <= '0;
            max_idx   <= '0;
            valid_out <= 1'b0;
        end
        else
        begin
            valid_out <= valid_in;   // 1-cycle pulse, mirrors valid_in
            if (valid_in)
            begin
                max_val <= val_final;
                max_idx <= idx_final;
            end
        end
    end

endmodule

`endif // ARGMAX4_SV