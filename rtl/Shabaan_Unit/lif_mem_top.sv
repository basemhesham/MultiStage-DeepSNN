// =====================================================================================
// Module name : lif_mem_top
// Purpose     : Thin wrapper around LIF that applies the 1-cycle re-timing needed to
//               align in_pool/first_frame/in_valid with the BRAM's 1-cycle read
//               latency for hist_in.
//               ** HIERARCHY EDIT: fetch and BRAM_LIF_Mem_0 have been pulled OUT of
//               this module and are now instantiated individually (x32) at the
//               deep_snn_top level, alongside a x32 top_shaaban_array. hist_in is
//               now an INPUT (driven by the per-lane BRAM's doutb at top level) and
//               hist_out is now an OUTPUT (driven back down to the per-lane BRAM's
//               dina at top level), instead of both being internal wires to a
//               locally-instantiated fetch+BRAM pair. frame_start/ADDR_WIDTH/DEPTH
//               are no longer needed here since address generation (fetch) and
//               storage (BRAM) no longer live inside this module. **
// =====================================================================================

module lif_mem_top #(
    parameter DATA_WIDTH = 18,
    parameter signed [DATA_WIDTH-1:0] THRESHOLD = 18'd512,
    parameter signed [DATA_WIDTH-1:0] ZERO      = 18'd0
) (
    input  wire                          clk,
    input  wire                          arst_n,

    // Caller-facing interface (mapping controller side)
    input  wire                          first_frame,  // High during Frame 0
    input  wire                          new_data_en,  // High when data is not an overlap
    input  wire signed [DATA_WIDTH-1:0]  in_pool,      // X[t]: pooled value for this position

    // Memory-facing interface (now driven from the top-level per-lane BRAM instance)
    input  wire signed [DATA_WIDTH-1:0]  hist_in,      // H[t-1], read from the external BRAM

    output wire                          spike_out,    // S[t]
    output wire signed [DATA_WIDTH-1:0]  hist_out,     // H[t], to be written to the external BRAM
    output wire signed [DATA_WIDTH-1:0]  hist_out_dbg  // H[t] committed this cycle (debug/verify, = hist_out)
);

    // -----------------------------------------------------------------
    // Internal Active Valid (Gated by new_data_en)
    // -----------------------------------------------------------------
    wire active_valid = new_data_en;

    // -----------------------------------------------------------------
    // Re-timing: Align in_pool AND controls with BRAM read latency (1 cycle).
    // The external fetch+BRAM pair (now at top level) apply the exact same
    // 1-cycle delay to rd_addr -> doutb, so hist_in arrives already aligned
    // with these _d1 signals on the same cycle.
    // -----------------------------------------------------------------
    reg signed [DATA_WIDTH-1:0] in_pool_d1;
    reg                         first_frame_d1;
    reg                         active_valid_d1; // Delay valid to match data arrival

    always_comb begin
        if (!arst_n) begin
            in_pool_d1      = '0;
            first_frame_d1  = 1'b0;
            active_valid_d1 = 1'b0;
        end else begin
            in_pool_d1      = in_pool;
            first_frame_d1  = first_frame;
            active_valid_d1 = active_valid;
        end
    end

    // -----------------------------------------------------------------
    // LIF: Calculates spike and next history term
    // -----------------------------------------------------------------
    LIF #(
        .DATA_WIDTH (DATA_WIDTH),
        .THRESHOLD  (THRESHOLD),
        .ZERO       (ZERO)
    ) u_lif (
        .clk         (clk),
        .arst_n      (arst_n),
        .in_valid    (active_valid_d1), // Route delayed valid to LIF
        .first_frame (first_frame_d1),
        .in_pool     (in_pool_d1),
        .hist_in     (hist_in),         // Now sourced from the top-level BRAM directly
        .spike_out   (spike_out),
        .hist_out    (hist_out)         // Now exposed as a port, for the top-level BRAM's dina
    );

    assign hist_out_dbg = hist_out;

endmodule