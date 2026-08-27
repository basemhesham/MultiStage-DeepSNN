// =====================================================================================
// Module name : fetch_stage2_1
// Purpose     : Generates the read and write addresses/enables for the LIF history
//               storage covering 1954*64 = 125056 positions, split across:
//                 - 61 x 2048-deep 36Kb BRAM banks (124928 positions), using the
//                   spare-bank ping-pong rotation (61 active + 1 spare = 62 total
//                   physical BRAMs), same scheme as fetch/fetch_stage2_0/
//                   fetch_stage2_2/fetch_stage3.
//                 - ONE hist_regfile_128x18 (128 positions) acting as a FIXED,
//                   non-rotating "62nd bank" for the 125056-124928=128 leftover
//                   positions that don't fill a whole extra BRAM (only 6.25%
//                   utilization) - see hist_regfile_128x18's header for why a
//                   single (non-ping-ponged) regfile is safe here: within one
//                   frame its write to a given position always trails that same
//                   position's read by exactly one pipeline cycle, so "read old,
//                   then write new" naturally happens in the correct order on a
//                   single array with no double-buffering needed.
//
//               ** Spare-bank ping-pong (BRAM side only): 61 active + 1 spare. **
//               Frame 1 : write window start = 0                          no read
//               Frame 2 : write window start = BRAM_TOTAL_BANKS-1(=61)    read window start = 0
//               Frame 3 : write window start = 60                        read window start = 61
//               Frame N : write window start decrements by 1 each frame, wrapping mod 62.
//               Within a frame, the window walks FORWARD through 61 consecutive
//               banks (mod 62) starting at that frame's start bank - identical
//               mechanism to fetch.sv, just with ACTIVE_BANKS=61/TOTAL_BANKS=62.
//
//               ** Regfile side (fixed, no rotation): **
//               Every frame, once the BRAM region's 124928 positions are swept,
//               the sweep continues into the regfile's 128 positions
//               (reg_pos = 0..127) using the SAME single regfile every frame -
//               no start-bank rotation, no spare, no first_frame gating beyond
//               the normal read suppression.
//
//               ** ADDRESSING (no divider/modulo hardware): **
//               BRAM side: sweep position tracked as (bank_adv, local_pos) -
//               local_pos counts 0..BANK_DEPTH-1 and rolls into bank_adv
//               (0..ACTIVE_BANKS-1). Physical bank = (start_bank + bank_adv)
//               wrapped mod BRAM_TOTAL_BANKS via compare-and-subtract (no '%').
//               Physical BRAM address = {bank_index, local_pos} (concat, since
//               BANK_DEPTH is a power of 2 - no multiplier).
//               Regfile side: reg_pos is a plain 0..127 counter, used directly
//               as the regfile address - no bank decomposition needed.
//
//               'frame_start' must be pulsed for exactly one cycle at the boundary
//               between two frames (after frame N's last in_valid, before frame N+1's
//               first in_valid) - and must NOT be pulsed before frame 0/frame 1,
//               since the rotation already starts at bank 0 out of reset.
// =====================================================================================
// Written by  : Abdelrahman Khaled
// Editor      : Manar
// Last edit   : 23-8-2026
// =====================================================================================

module fetch_stage2_1 #(
    parameter int BANK_DEPTH       = 2048,                          // depth of a single physical BRAM bank - MUST be a power of 2
    parameter int BRAM_ACTIVE_BANKS = 61,                           // BRAM banks swept per frame
    parameter int BRAM_TOTAL_BANKS  = 62,                           // BRAM banks physically present = ACTIVE + 1 spare
    parameter int REG_DEPTH        = 128,                           // regfile depth (the fixed "62nd bank")
    parameter int MEM_ADDR_WIDTH   = $clog2(BRAM_TOTAL_BANKS*BANK_DEPTH), // BRAM-side physical address width
    parameter int REG_ADDR_WIDTH   = (REG_DEPTH > 1) ? $clog2(REG_DEPTH) : 1
) (
    input  logic                        clk,
    input  logic                        arst_n,

    // Caller-facing side (mapping controller)
    input  logic  [3:0]                 frame_count, // indicate which frame we are in as to write only in the first and read only in the last
    input  logic                        frame_start, // 1-cycle pulse at each frame boundary (NOT before frame 1)
    input  logic                        in_valid,    // position valid this cycle (advances the position counter)

    // BRAM-side memory-facing ports (drive the 61+1 BRAM banks)
    output logic                        mem_rd_en,
    output logic [MEM_ADDR_WIDTH-1:0]   mem_rd_addr,
    output logic                        mem_wr_en,
    output logic [MEM_ADDR_WIDTH-1:0]   mem_wr_addr,

    // Regfile-side memory-facing ports (drive hist_regfile_128x18 directly)
    output logic                        reg_rd_en,
    output logic [REG_ADDR_WIDTH-1:0]   reg_rd_addr,
    output logic                        reg_wr_en,
    output logic [REG_ADDR_WIDTH-1:0]   reg_wr_addr,

    // Caller-facing side
    output logic                        out_valid,
    output logic [MEM_ADDR_WIDTH-1:0]   addr_out     // BRAM-side address when in BRAM region; '0 during regfile region
);

    localparam int BANK_IDX_WIDTH = $clog2(BRAM_TOTAL_BANKS);   // width for a BRAM bank index (0..BRAM_TOTAL_BANKS-1)
    localparam int ADV_WIDTH      = $clog2(BRAM_ACTIVE_BANKS);  // width for the in-frame bank-advance count (0..BRAM_ACTIVE_BANKS-1)
    localparam int LOCAL_WIDTH    = $clog2(BANK_DEPTH);         // width for the local in-bank offset (0..BANK_DEPTH-1)

    // -----------------------------------------------------------------
    // Rotating start-bank (BRAM side only): same mechanism as fetch.sv -
    // cur_bank/prev_bank decrement by one bank each frame_start, wrapping
    // mod BRAM_TOTAL_BANKS.
    // -----------------------------------------------------------------
    localparam [BANK_IDX_WIDTH-1:0] BRAM_TOTAL_BANKS_M1 = BANK_IDX_WIDTH'(BRAM_TOTAL_BANKS - 1);

    reg [BANK_IDX_WIDTH-1:0] cur_bank;
    reg [BANK_IDX_WIDTH-1:0] prev_bank;
    wire [BANK_IDX_WIDTH-1:0] cur_bank_dec;   // pre-computed decrement (kept out of the ternary below)
    wire [BANK_IDX_WIDTH-1:0] cur_bank_next;
    assign cur_bank_dec  = cur_bank - 1'b1;
    assign cur_bank_next = (cur_bank == '0) ? BRAM_TOTAL_BANKS_M1 : cur_bank_dec;

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            cur_bank  <= '0;
            prev_bank <= '0;
        end else if (frame_start && (frame_count != 0)) begin
            prev_bank <= cur_bank;
            cur_bank  <= cur_bank_next;
        end
    end

    // -----------------------------------------------------------------
    // Sweep position: (bank_adv, local_pos) for the BRAM region, then
    // reg_pos for the regfile region once the BRAM region is exhausted.
    // 'in_reg_region' marks which region the CURRENT cycle's position is
    // in.
    // -----------------------------------------------------------------
    reg [LOCAL_WIDTH-1:0] local_pos;
    reg [ADV_WIDTH-1:0]   bank_adv;
    reg [REG_ADDR_WIDTH-1:0] reg_pos;
    reg                     in_reg_region;

    localparam [ADV_WIDTH-1:0] BRAM_ACTIVE_BANKS_M1 = ADV_WIDTH'(BRAM_ACTIVE_BANKS - 1);

    wire local_pos_wraps = (local_pos == BANK_DEPTH-1);
    wire bram_region_done = in_valid && !in_reg_region &&
                             (bank_adv == BRAM_ACTIVE_BANKS_M1) && local_pos_wraps;

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            local_pos     <= '0;
            bank_adv      <= '0;
            reg_pos       <= '0;
            in_reg_region <= 1'b0;
        end else if (frame_start) begin
            local_pos     <= '0;
            bank_adv      <= '0;
            reg_pos       <= '0;
            in_reg_region <= 1'b0;
        end else if (in_valid) begin
            if (!in_reg_region) begin
                if (bram_region_done) begin
                    // BRAM region just finished this cycle -> next cycle
                    // begins the regfile region at reg_pos 0.
                    in_reg_region <= 1'b1;
                end else if (local_pos_wraps) begin
                    local_pos <= '0;
                    bank_adv  <= bank_adv + 1'b1;
                end else begin
                    local_pos <= local_pos + 1'b1;
                end
            end else begin
                reg_pos <= reg_pos + 1'b1; // 0..127, never wraps within a frame (region ends at 128)
            end
        end
    end

    // -----------------------------------------------------------------
    // Bank-index helper (BRAM side): base bank + bank_adv, wrapped mod
    // BRAM_TOTAL_BANKS via compare-and-subtract (no '%').
    // -----------------------------------------------------------------
    function automatic [BANK_IDX_WIDTH-1:0] wrapped_bank(
        input [BANK_IDX_WIDTH-1:0] base,
        input [ADV_WIDTH-1:0]      adv
    );
        logic [BANK_IDX_WIDTH:0] sum;
        logic [BANK_IDX_WIDTH:0] sum_wrapped;  // pre-computed wrap (kept out of the ternary below)
        begin
            sum         = {1'b0, base} + {{(BANK_IDX_WIDTH+1-ADV_WIDTH){1'b0}}, adv};
            sum_wrapped = sum - BRAM_TOTAL_BANKS;
            wrapped_bank = (sum >= BRAM_TOTAL_BANKS) ? BANK_IDX_WIDTH'(sum_wrapped) : sum[BANK_IDX_WIDTH-1:0];
        end
    endfunction

    // -----------------------------------------------------------------
    // Read side: combinational.
    //   BRAM region : sweeps from prev_bank (this frame's read window =
    //                 last frame's write window), suppressed on frame 1.
    //   Regfile region : reads the SAME single regfile every frame (no
    //                 rotation - see header), also suppressed on frame 1.
    // -----------------------------------------------------------------
    wire [BANK_IDX_WIDTH-1:0] rd_bank = wrapped_bank(prev_bank, bank_adv);

    assign mem_rd_en   = (in_valid && (|frame_count != 0) && !in_reg_region) ? 1 : 0;  // read when it's not the first frame
    assign mem_rd_addr = MEM_ADDR_WIDTH'({rd_bank, local_pos});

    assign reg_rd_en   = (in_valid && (|frame_count != 0) && in_reg_region) ? 1 : 0;  // writing when it's not the last frame
    assign reg_rd_addr = reg_pos;

    // -----------------------------------------------------------------
    // Write side: delayed 1 cycle to align with memory read latency,
    // sweeps from cur_bank / writes the same fixed regfile, mirroring
    // the read-side region split one cycle later.
    // -----------------------------------------------------------------
    reg                      valid_d1;
    reg [LOCAL_WIDTH-1:0]    local_pos_d1;
    reg [ADV_WIDTH-1:0]      bank_adv_d1;
    reg [BANK_IDX_WIDTH-1:0] cur_bank_d1;
    reg [REG_ADDR_WIDTH-1:0] reg_pos_d1;
    reg                      in_reg_region_d1;

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            valid_d1         <= 1'b0;
            local_pos_d1     <= '0;
            bank_adv_d1      <= '0;
            cur_bank_d1      <= '0;
            reg_pos_d1       <= '0;
            in_reg_region_d1 <= 1'b0;
        end else begin
            valid_d1         <= in_valid;
            local_pos_d1     <= local_pos;
            bank_adv_d1      <= bank_adv;
            cur_bank_d1      <= cur_bank;
            reg_pos_d1       <= reg_pos;
            in_reg_region_d1 <= in_reg_region;
        end
    end

    wire [BANK_IDX_WIDTH-1:0] wr_bank = wrapped_bank(cur_bank_d1, bank_adv_d1);

    // We ALWAYS write, even on frame 1, to populate the history for frame 2.
    assign mem_wr_en   = (valid_d1 && (&frame_count != 1) && !in_reg_region_d1) ? 1 : 0;  // writing when it's not the last frame
    assign mem_wr_addr = MEM_ADDR_WIDTH'({wr_bank, local_pos_d1});

    assign reg_wr_en   = (valid_d1 && (&frame_count != 1) && in_reg_region_d1) ? 1 : 0;  // writing when it's not the last frame
    assign reg_wr_addr = reg_pos_d1;

    // -----------------------------------------------------------------
    // Status passthrough to the caller/wrapper - aligned to the same
    // cycle as the write side. addr_out reports the BRAM-side address
    // when the write is in the BRAM region; held at '0 during the
    // regfile region (use reg_wr_addr/reg_wr_en directly if the
    // regfile-side address is needed for debug).
    // -----------------------------------------------------------------
    assign out_valid = valid_d1;
    assign addr_out  = in_reg_region_d1 ? '0 : mem_wr_addr;

endmodule
