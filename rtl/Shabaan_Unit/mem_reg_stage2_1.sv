// =====================================================================================
// Module name : hist_regfile_128x18
// Purpose     : Storage for the 128 leftover history elements (18-bit each) that
//               don't fit evenly into the 61 x 36Kb BRAMs used by fetch_stage3_0
//               (1954*64 = 125056 elements; 61*2048 = 124928 fit in BRAM, the
//               remaining 125056-124928 = 128 live here instead of wasting a whole
//               extra 36Kb BRAM on 128/2048 = 6.25% utilization).
//
//               Drop-in target for fetch_stage3_0's reg_rd_en/reg_rd_addr/
//               reg_wr_en/reg_wr_addr ports - connect directly, no glue needed.
//
//               Behaves like a simple single-port-read / single-port-write sync
//               "BRAM-shaped" storage so its timing matches the real BRAMs on the
//               mem_* side of fetch_stage3_0:
//                 - read: 1-cycle latency (rd_data registered, valid the cycle
//                   after rd_en/rd_addr are asserted) - same latency assumption
//                   fetch_stage3_0's write-side delay (valid_d1) is built around.
//                 - write: registered same-cycle write on wr_en.
//                 - simultaneous read+write to the SAME address returns the OLD
//                   value on rd_data that cycle (no read-during-write forwarding),
//                   matching typical no-change/read-first BRAM behavior. This
//                   should never actually happen in this design anyway, since
//                   fetch_stage3_0's write to a given position always trails that
//                   position's read by exactly one full read-latency cycle, on a
//                   DIFFERENT frame - reads and writes never target the same
//                   address on the same cycle.
//
//               Implemented as plain flops (not inferred as BRAM) since 128x18 is
//               small enough that LUTRAM/FF implementation is the right utilization
//               trade-off vs burning a whole 36Kb block for it.
// =====================================================================================
// Written by  : Manar
// Last edit   : 14-8-2026
// =====================================================================================

module hist_regfile_128x18 #(
    parameter DEPTH      = 128,
    parameter DATA_WIDTH = 18,
    parameter ADDR_WIDTH = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  logic                     clk,
    input  logic                     arst_n,

    // Read port
    input  logic                     rd_en,
    input  logic [ADDR_WIDTH-1:0]    rd_addr,
    output logic [DATA_WIDTH-1:0]    rd_data,   // valid 1 cycle after rd_en/rd_addr

    // Write port
    input  logic                     wr_en,
    input  logic [ADDR_WIDTH-1:0]    wr_addr,
    input  logic [DATA_WIDTH-1:0]    wr_data
);

    // -----------------------------------------------------------------
    // Storage array
    // -----------------------------------------------------------------
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // -----------------------------------------------------------------
    // Write side: plain registered write, no reset of the whole array
    // (matches BRAM behavior - contents are undefined out of reset until
    // first written, same as a real BRAM would be).
    // -----------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
    end

    // -----------------------------------------------------------------
    // Read side: registered output -> 1-cycle latency, no read-during-
    // write forwarding (see header note on why that's safe here).
    // -----------------------------------------------------------------
    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            rd_data <= '0;
        end else if (rd_en) begin
            rd_data <= mem[rd_addr];
        end
    end

endmodule