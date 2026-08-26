//===========================================================
// File        : mapping_controller.sv
// Purpose     : Reads a 24-row x 256-col pixel matrix from memory (72-bit
//               words, 4 pixels/word, 18 bits/pixel) and produces 5x5
//               sliding-window outputs over a 24x24 pixel buffer, with
//               mode-aware zero-padding for border/corner windows.
//               *** 4-WINDOW-PARALLEL EDIT ***: outputs WIN_GROUP=4
//               consecutive horizontal windows per cycle instead of 1,
//               cutting FETCH time 4x (interior: 400 -> 100 cycles).
//               *** LINT-FIX PASS ***: replaced non-power-of-2 '%'/'/'
//               (mod-24, div-6) with counter/compare-and-subtract logic,
//               separated blocking-only decode always_comb blocks from the
//               non-blocking-only always_ff writes, and resolved multi-width
//               inline arithmetic into single module-level signals.
//               *** REDUNDANCY-REDUCTION PASS ***: the row-wrap
//               "sum + conditional-subtract" pattern previously appeared
//               three times (write-decode, addr-gen, and inside the
//               read_buf_pixel function) as three separate signal PAIRS.
//               It is now a single `WRAP_ROW textual macro reused at every
//               call site, so there is exactly one place that defines the
//               wrap behaviour instead of three near-identical copies.
//               The automatic function read_buf_pixel() has been removed;
//               buffer reads are now inlined directly as buff[][][] index
//               expressions. conv_window_assembly no longer stores
//               WIN_GROUP*CONV_K*CONV_K (100) entries per signal for data
//               that never actually depended on all three indices: row-only
//               quantities (position/pad/physical-row) are now precomputed
//               once per row (5 entries), and column-only quantities
//               (position/pad/bank/col-in-bank) once per lane+column
//               (WIN_GROUP*CONV_K = 20 entries), then combined at the final
//               pixel-emission step.
//               *** GENERATE-FOR REFACTOR PASS ***: every procedural `for`
//               loop that lived inside the single conv_window_assembly
//               always_comb block (lane-column precompute, row-only
//               precompute, column-only precompute, valid_mask_o, and the
//               final per-pixel emission) has been rewritten as an
//               elaboration-time `generate for`, indexed by true genvars
//               instead of runtime loop variables. The old runtime signal
//               `pixel_bit_offset` is gone entirely: since g/r/c are now
//               compile-time constants per generated instance, its value is
//               a genvar-derived `localparam` instead.
//               *** VLOG-2583 FIX ***: the first cut of this pass gave each
//               generate instance its own `always_comb` block. Questa/
//               ModelSim then raised vlog-2583 ("extra checking for
//               conflicts... done at vopt time") on every array target,
//               because vlog can't cheaply prove at compile time that N
//               separate procedural always_comb *processes* writing into
//               different elements of the SAME array never overlap; that
//               check is deferred to vopt. Since every generated body here
//               is a pure combinational expression with no loop-carried
//               state, each is now a continuous `assign` instead of an
//               always_comb — assign targets aren't subject to that
//               process-conflict analysis, so the warning is gone rather
//               than merely deferred. All LOAD, bank-rotation, padding,
//               indexing, and timing BEHAVIOUR is UNCHANGED — this pass
//               only changes *how* the per-lane/per-row/per-column/
//               per-pixel logic is structurally replicated and driven, not
//               what it computes.
// Used in     : top-level conv pipeline, feeds a 5x5xWIN_GROUP conv block
//===========================================================
// Written by  : 
// Editor      : Manar
// Last edit   : 14-7-2026
//===========================================================

`ifndef MAPPING_CONTROLLER_SV
`define MAPPING_CONTROLLER_SV

//=============================================================================
// DESIGN NOTES
//=============================================================================

//-----------------------------------------------------------------------------
// Memory Layout
//-----------------------------------------------------------------------------
//   Full matrix : 24 rows x 256 cols
//   Word width  : 72 bits = 4 pixels x 18 bits
//   Row r base  : r * 64  (64 words per row)
//   1-cycle read latency: address presented cycle N, data valid cycle N+1

//-----------------------------------------------------------------------------
// Buffer Organisation  (banks store COLUMNS, not rows)
//-----------------------------------------------------------------------------
//   The 24x24 pixel buffer is split into 3 column-banks:
//     bank 0 : 24 rows x cols  0.. 7
//     bank 1 : 24 rows x cols  8..15
//     bank 2 : 24 rows x cols 16..23
//   buf[bank][row][col_within_bank]  col_within_bank = 0..7

//-----------------------------------------------------------------------------
// Horizontal Sliding  (30 windows across 256 cols)
//-----------------------------------------------------------------------------
//   Window k covers pixel-cols 8k .. 8k+23  (k = 0..29)
//   In memory, pixel-col C is at word offset C/4 within its row.
//   Window k reads word offsets 2k .. 2k+5  (6 words = 24 pixels per row).
//
//   Full load  (first window or new sweep):
//     Read 6 words x 24 rows = 144 words.
//     Words 0..1 per row  -> bank 0 (cols 0..7)
//     Words 2..3 per row  -> bank 1 (cols 8..15)
//     Words 4..5 per row  -> bank 2 (cols 16..23)
//
//   Partial load (windows 1..29 within a sweep):
//     Only the rightmost 8 new pixel-columns enter the window.
//     Read 2 words x 24 rows = 48 words  (word offsets 2k+4, 2k+5 per row).
//     These 48 words overwrite write_bank  (the bank that held the oldest cols).

//-----------------------------------------------------------------------------
// Bank Rotation
//-----------------------------------------------------------------------------
//   fetch_order[0..2] maps logical col-group {0..7, 8..15, 16..23} to physical
//   banks.  After each partial load the oldest bank becomes the new rightmost.
//
//   Initially (full load):  fetch_order = {0, 1, 2}  write_bank -> 0 next
//   After partial load #1:  write_bank=0 filled;  fetch_order = {1, 2, 0}
//   After partial load #2:  write_bank=1 filled;  fetch_order = {2, 0, 1}
//   After partial load #3:  write_bank=2 filled;  fetch_order = {0, 1, 2}
//   ... repeats every 3 partial loads

//-----------------------------------------------------------------------------
// Row Origin Rotation  (across vertical sweeps of the 256x256 frame)
//-----------------------------------------------------------------------------
//   The memory holds 24 rows of the full 256-row picture.  After all 30
//   horizontal windows are output (done_o), the outer system overwrites 8
//   rows in memory with the next 8 image rows, then pulses start_i again.
//
//   row_origin tracks which physical memory row is logical row 0:
//     Sweep 0 : row_origin = 0  -> physical rows 0..23 in natural order
//     Sweep 1 : row_origin = 8  -> physical rows 8,9,...,23,0,1,...,7
//     Sweep 2 : row_origin = 16 -> physical rows 16,...,23,0,...,15
//     Sweep 3 : row_origin = 0  (wraps)
//   Actual physical memory row = (row_origin + logical_row) % IMG_ROWS
//
//   30 horizontal windows x 30 vertical sweeps = 900 total 24x24 windows
//   covering the full 256x256 frame.  After sweep 29 done_o fires with
//   frame_done_o also asserted; controller resets for a new frame.

//-----------------------------------------------------------------------------
// 5x5 Conv Sliding Window  (mode-aware with zero padding)
//-----------------------------------------------------------------------------
//   The active fetch region and zero-padding are derived INTERNALLY from
//   win_idx and sweep_idx — no external mode input required.
//
//   mode_r[1] = 1 when sweep_idx == 0 or sweep_idx == NUM_SWEEPS-1 (row border)    //for zero padding
//   mode_r[0] = 1 when win_idx  == 0 or win_idx  == NUM_H_WIN-1    (col border)
//
//   Active region per mode:
//     mode_r=2'b00 (interior)    : 24 rows x 24 cols, 20x20=400 windows, no padding
//     mode_r=2'b01 (left/right)  : 24 rows x 18 cols, 20x14=280 windows, pad_left or pad_right=2
//     mode_r=2'b10 (top/bottom)  : 18 rows x 24 cols, 14x20=280 windows, pad_top  or pad_bot =2
//     mode_r=2'b11 (corner)      : 18 rows x 18 cols, 14x14=196 windows, two pads = 2 each
//
//   Zero padding (2 pixels on the image-border side per active axis):
//     pad_top   = 2 if mode_r[1] && sweep_idx==0,           else 0
//     pad_bot   = 2 if mode_r[1] && sweep_idx==NUM_SWEEPS-1, else 0
//     pad_left  = 2 if mode_r[0] && win_idx ==0,            else 0
//     pad_right = 2 if mode_r[0] && win_idx ==NUM_H_WIN-1,  else 0
//
//   Real buffer region (16 real pixels per padded axis):
//     real_buf_row_start = 8 if pad_bot==2, else 0
//     real_buf_col_start = 8 if pad_right==2, else 0
//
//   Per kernel position (kr,kc) at conv position (conv_row,conv_col):
//     output_row = conv_row + kr,  output_col = conv_col + kc
//     in_pad     = output_row < pad_top
//               || output_row >= active_rows - pad_bot
//               || output_col < pad_left
//               || output_col >= active_cols - pad_right
//     pixel = 0                                        if in_pad
//           = buf[real_buf_row_start + output_row - pad_top]
//                [real_buf_col_start + output_col - pad_left]  otherwise

//-----------------------------------------------------------------------------
// 4-Window Parallel Fetch
//-----------------------------------------------------------------------------
//   In the original design conv_col advanced by 1 each FETCH cycle.
//   In this version conv_col advances by WIN_GROUP (=4) each cycle so that
//   lanes g=0..WIN_GROUP-1 compute windows starting at columns
//     out_col_lane[g] = conv_col + g
//   simultaneously.  The output bus packs them side by side:
//     bits [  449:   0] = lane 0 window  (leftmost  of the group)
//     bits [  899: 450] = lane 1 window
//     bits [ 1349: 900] = lane 2 window
//     bits [ 1799:1350] = lane 3 window  (rightmost of the group)
//   Within each 450-bit lane the pixel packing is identical to the original:
//     top-left pixel at MSB (slot 24), bottom-right pixel at LSB (slot 0).
//
//   valid_mask_o:
//     conv_slides_col is not always a multiple of WIN_GROUP (border case = 14,
//     14 % 4 = 2 remainder).  On the last group of such a row, only lanes 0
//     and 1 hold real windows; lanes 2 and 3 are forced to zero.
//     valid_mask_o[g] = 1  means lane g holds a real window this cycle.
//     valid_mask_o[g] = 0  means lane g is padding — downstream conv25 block
//                           g must gate its result.

//-----------------------------------------------------------------------------
// Load/Fetch Handshake  (fetch_en_i / done_load_o)
//-----------------------------------------------------------------------------
//   After a LOAD phase completes (full or partial), the controller does NOT
//   automatically proceed to FETCH. Instead it enters WAIT_FETCH and asserts
//   done_load_o, holding there until the external fetch_en_i pulse arrives.
//
//     LOAD complete -> WAIT_FETCH (done_load_o=1) -> fetch_en_i pulse -> FETCH (done_load_o=0)

//-----------------------------------------------------------------------------
// WRAP_ROW macro
//-----------------------------------------------------------------------------
//   Every place that needs "physical row = (row_origin + some_index) mod
//   IMG_ROWS" uses this single textual macro instead of three separate
//   duplicated sum/wrapped signal pairs.
//     `WRAP_ROW(base)  =  (row_origin + base), wrapped into [0, IMG_ROWS-1]
//   used directly wherever a wrapped physical row is needed, including the
//   row_origin += 8 sweep-advance step (WRAP_ROW(5'd8)). row_origin is in
//   {0,8,16} and every `base` used in this file is in [0,31], so the sum
//   never exceeds 47 — one conditional subtract always wraps it correctly.
//   Being a textual macro (not a function) it inlines directly at the call
//   site: no function-call semantics, no automatic/reentrant storage.
`define WRAP_ROW(base) \
    ((6'(row_origin) + 6'(base) >= 6'(IMG_ROWS)) ? \
        (6'(row_origin) + 6'(base) - 6'(IMG_ROWS)) : \
        (6'(row_origin) + 6'(base)))

//-----------------------------------------------------------------------------
// Lint-Fix Pass  (carried over from a previous edit; still in effect)
//-----------------------------------------------------------------------------
//   1. mod-24 / div-6 removal: no '%' or '/' by a non-power-of-2 anywhere;
//      counters (row_cnt/word_cnt) and WRAP_ROW replace them.
//   2. blocking/non-blocking separation: buffer-write address decode lives
//      in its own always_comb (blocking only); the always_ff write_buf
//      block only performs non-blocking writes using already-resolved
//      signals as plain indices.
//   3. resolved-width temporaries: multi-width inline arithmetic is computed
//      once into an explicitly-sized signal/localparam instead of being
//      written directly at the array-index position.

module mapping_controller
#(
    parameter int PIXEL_W      = 18,   // bits per pixel
    parameter int WORD_W       = 72,   // bits per memory word (4 pixels)
    parameter int IMG_ROWS     = 24,   // rows in memory (circular buffer)
    parameter int IMG_COLS     = 256,  // columns in full image
    parameter int BUF_SIZE     = 24,   // buffer dimension (24x24)
    parameter int BANK_COLS    = 8,    // pixel-columns per bank
    parameter int CONV_K       = 5,    // conv kernel size
    parameter int WIN_GROUP    = 4,    // windows output per cycle (4x speedup)
    parameter int NUM_H_WIN    = 30,   // horizontal windows per sweep (30)
    parameter int NUM_SWEEPS   = 30    // vertical sweeps per frame (30)
)
(
    //=======================================================
    // Controls
    //=======================================================
    input  wire logic        clk,
    input  wire logic        rst_n,        // active LOW, asynchronous. No soft/synchronous reset.
    input  wire logic        start_i,      // begin full load (new sweep)
    input  wire logic        next_i,       // begin partial load (next h-window)
    input  wire logic        fetch_en_i,   // one-cycle pulse: permission to enter FETCH after a load
    //=======================================================
    // Inputs
    //=======================================================
    input  wire [WORD_W-1:0] mem_data_i,   // read data (1-cycle latency)
    //=======================================================
    // Outputs
    //=======================================================
    output logic     [15:0]                             mem_addr_o,     // word address (always_comb - procedural)
    output logic                                        mem_rd_o,       // read enable (always_comb - procedural)

    // Each 450-bit lane holds one 5x5 window in the same packing as before.
    //   lane g occupies bits [g*450+449 : g*450]  for g = 0..WIN_GROUP-1
    //   within a lane: slot 24 (MSB) = top-left pixel, slot 0 (LSB) = bottom-right
    output logic     [WIN_GROUP*CONV_K*CONV_K*PIXEL_W-1:0] conv_pixels_o, // 100 packed pixels (4 windows x 25) (procedural)
    output logic     [WIN_GROUP-1:0]                    valid_mask_o,   // bit g=1 when lane g is a real window (procedural)
    output logic                                        conv_valid_o,   // one cycle per window GROUP (procedural)
    output logic                                        conv_done_o,    // pulse after last GROUP of active region (procedural)
    output wire  logic                                  done_o,         // pulse after last h-window of a sweep (assign, fed from done_r)
    output wire  logic                                  frame_done_o,   // pulse after all sweeps complete (assign, fed from frame_done_r)
    output wire  logic                                  done_load_o,    // high while waiting in WAIT_FETCH for fetch_en_i (assign)
    output wire  logic [1:0]                            state_o         // 00=IDLE 01=LOAD 10=FETCH 11=WAIT_FETCH (assign, for TB)
);

    //=======================================================
    // Local Parameters
    //=======================================================
    localparam int WORDS_PER_ROW     = IMG_COLS / 4;          // 64 words per image row
    localparam int WORDS_PER_BUF     = BUF_SIZE / 4;          // 6 words = 24 pixels per row
    localparam int WORDS_PER_BANK    = BANK_COLS / 4;         // 2 words = 8 pixels per row
    // Full load  : 24 rows x 6 words = 144 words
    localparam int TOTAL_LOAD_WORDS  = IMG_ROWS * WORDS_PER_BUF;
    // Partial load: 24 rows x 2 new words = 48 words  (rightmost 8 new cols)
    localparam int PARTIAL_LOAD_WORDS = IMG_ROWS * WORDS_PER_BANK;
    // CONV_SLIDES and TOTAL_CONV are now dynamic (see mode_decode block below).
    // Maximum: 24-5+1=20 slides/axis (interior), Minimum: 18-5+1=14 (border)
    // bits per single 5x5 window (unchanged from original)
    localparam int WINDOW_BITS       = CONV_K * CONV_K * PIXEL_W;  // 450

    //=======================================================
    // Internals
    //=======================================================
    // Pixel buffer: 3 col-banks x 24 rows x 8 cols. buf[bank][row][col_in_bank]
    logic [PIXEL_W-1:0] buff [0:2][0:IMG_ROWS-1][0:BANK_COLS-1];

    // FSM.
    typedef enum logic [2:0] {
        IDLE       = 3'b000,
        LOAD       = 3'b001,
        FETCH      = 3'b010,
        WAIT_FETCH = 3'b011,   // gated handshake state between LOAD and FETCH
        SECOND_BEGIN_OF_SWEEP = 3'b100,
        END_OF_SWEEP   = 3'b101
    } state_t;
    state_t state, next_state;

    // Position / sequencing registers.
    logic [4:0] win_idx;             // horizontal window index within current sweep (0..29)
    logic [4:0] sweep_idx;           // vertical sweep index (0..29)
    logic [5:0] word_col_offset;     // word offset of current 24-pixel window (window k -> k*2)
    logic [4:0] row_origin;          // physical memory row that maps to logical row 0 (0, 8, or 16)
    logic [7:0] load_cnt;            // number of read requests issued this load phase // till 144
    logic       full_load;           // 1 = full load (144 words), 0 = partial load (48 words), 144 = 24rows *3banks *2word
    logic [1:0] write_bank;          // physical bank that receives new data in a partial load
    logic [1:0] fetch_order [0:2];   // fetch_order[i] = physical bank holding logical col-group i
    logic [4:0] conv_row;            // conv window GROUP top-left row within the active region         //20 (5*5)
    logic [4:0] conv_col;            // conv window GROUP top-left col; steps by WIN_GROUP each cycle   //20 (5*5)

    // Mode-decode signals — all combinational from win_idx/sweep_idx (see mode_decode block).
    logic [1:0] mode_r;              // [1]=row border  [0]=col border
    logic [1:0] pad_top, pad_bot;    // 0 or 2
    logic [1:0] pad_left, pad_right; // 0 or 2
    logic [4:0] active_rows, active_cols;       // 18 or 24
    logic [3:0] real_buf_row_start, real_buf_col_start; // 0 or 8
    logic [4:0] conv_slides_row, conv_slides_col;       // 14 or 20  //No. of 5*5 windows

    // 1-cycle pipeline registers for memory read latency.
    logic       load_data_valid;   // data arriving this cycle is valid
    logic [7:0] load_cnt_d;        // load_cnt value when the read was issued

    // Counters that replace division-by-6 (non-power-of-2) for
    // logical_row/word_in_row during LOAD.
    logic [4:0] row_cnt,  row_cnt_d;    // current logical row during LOAD  //24
    logic [2:0] word_cnt, word_cnt_d;   // current word-in-row during LOAD

    // Buffer-write decode temporaries (module-level, combinational,
    // blocking-only — see buffer_write_decode below). physical_row_c is
    // produced directly by the WRAP_ROW macro; no separate sum/wrapped pair
    // is declared here any more.
    logic [4:0] physical_row_c;  // logical row rotated by row_origin (0..23) /////////////
    logic [1:0] tgt_bank_c;      // target bank for this write          // bank 0,1,2
    logic [2:0] col_base_c;      // first col_in_bank index for this word // 6 words per window
    logic [2:0] col_idx0_c, col_idx1_c, col_idx2_c, col_idx3_c; // resolved indices
    logic [7:0] load_max_comb;
    //=======================================================
    // mode_decode
    //=======================================================
    // Generates mode_r, padding amounts, active region, and real buffer
    // offsets purely from win_idx and sweep_idx (both stable throughout
    // FETCH). No external mode input required.
    always_comb begin
        // --- mode_r: row border when sweep is first or last ---
        mode_r[1] = (sweep_idx == 5'd0) || (sweep_idx == NUM_SWEEPS - 1);
        // --- mode_r: col border when window is first or last ---
        mode_r[0] = (win_idx  == 5'd0) || (win_idx  == NUM_H_WIN  - 1);

        // --- padding: only on the image-border side, 2 pixels ---
        // row axis: top padding for first sweep, bottom for last sweep
        pad_top = (sweep_idx == 5'd0)           ? 2'd2 : 2'd0;
        pad_bot = (sweep_idx == NUM_SWEEPS - 1) ? 2'd2 : 2'd0;
        // col axis: left padding for first window, right for last window
        pad_left  = (win_idx == 5'd0)          ? 2'd2 : 2'd0;
        pad_right = (win_idx == NUM_H_WIN - 1) ? 2'd2 : 2'd0;

        // --- active region: 18 on border axes, 24 on interior ---
        active_rows = mode_r[1] ? 5'd18 : 5'd24;
        active_cols = mode_r[0] ? 5'd18 : 5'd24;

        // --- real buffer start: 0 when pad is on top/left,
        //                        8 when pad is on bot/right (real data is in lower half) ---
        real_buf_row_start = (pad_bot == 2'd2) ? 4'd8 : 4'd0;
        real_buf_col_start = (pad_right == 2'd2) ? 4'd8 : 4'd0;

        // --- conv slides per axis ---
        conv_slides_row = active_rows - CONV_K + 1;  // 14 or 20
        conv_slides_col = active_cols - CONV_K + 1;  // 14 or 20
    end

    //=======================================================
    // buffer_write_decode
    //=======================================================
    // Combinational, blocking assignments only. Decodes load_cnt_d into
    // (physical_row, bank, col_in_bank) for the currently-arriving memory
    // word. Lives in its own always_comb block so the always_ff below only
    // ever performs non-blocking writes to real registers/memories.
    //
    // physical_row_c comes directly from the WRAP_ROW macro (no '%'
    // operator, no locally-declared sum/wrapped pair — see macro definition
    // above for the underlying compare-and-subtract).
    always_comb begin
        col_base_c      = {2'b00, word_cnt_d[0]} << 2;   // 0 or 4

        if (full_load) begin
            // bank = word_in_row / 2  (pairs of words per bank)
            tgt_bank_c      = word_cnt_d[2:1];               // 0,1,2
            // col base within bank: word_in_row even->0, odd->4
        end else begin
            tgt_bank_c      = write_bank;
        end

        physical_row_c = 5'(`WRAP_ROW(row_cnt_d));

        // Resolved buffer column indices (no arithmetic left inline at the
        // array-index position — each index is now a plain signal)
        col_idx0_c = col_base_c + 3'd0;
        col_idx1_c = col_base_c + 3'd1;
        col_idx2_c = col_base_c + 3'd2;
        col_idx3_c = col_base_c + 3'd3;
    end

    //=======================================================
    // fsm_sequential
    //=======================================================
    always_ff @(posedge clk or negedge rst_n) begin
        //===================================================
        // Reset
        //===================================================
        if (!rst_n) begin
            state           <= IDLE;
            win_idx         <= '0;
            sweep_idx       <= '0;
            word_col_offset <= '0;
            row_origin      <= '0;
            load_cnt        <= '0;
            load_cnt_d      <= '0;
            row_cnt         <= '0;
            row_cnt_d       <= '0;
            word_cnt        <= '0;
            word_cnt_d      <= '0;
            full_load       <= 1'b1;
            write_bank      <= 2'd0;
            fetch_order     <= '{2'd0, 2'd1, 2'd2};
            conv_row        <= '0;
            conv_col        <= '0;
            load_data_valid <= 1'b0;
        //===================================================
        // Running
        //===================================================
        end else begin
            state <= next_state;

            //---------------------------------------------------
            // LOAD: pipeline tracking
            //---------------------------------------------------
            if (state == LOAD) begin
                load_data_valid <= mem_rd_o;   // data arrives one cycle after rd
                load_cnt_d      <= load_cnt;   // capture index of the issued read
                row_cnt_d       <= row_cnt;
                word_cnt_d      <= word_cnt;

                if (mem_rd_o) begin
                    load_cnt <= load_cnt + 1'b1;
                    if (word_cnt == (full_load ? WORDS_PER_BUF[2:0]-3'd1 : WORDS_PER_BANK[2:0]-3'd1)) begin
                        word_cnt <= '0;
                        row_cnt  <= row_cnt + 1'b1;
                    end else begin
                        word_cnt <= word_cnt + 1'b1;
                    end
                end
            end else begin
                load_data_valid <= 1'b0;
                load_cnt_d      <= '0;
                row_cnt_d       <= '0;
                word_cnt_d      <= '0;
            end

            //---------------------------------------------------
            // Entering LOAD: reset load counter
            //---------------------------------------------------
            if (next_state == LOAD && state != LOAD) begin
                load_cnt        <= '0;
                load_cnt_d      <= '0;
                load_data_valid <= 1'b0;
                row_cnt         <= '0;
                row_cnt_d       <= '0;
                word_cnt        <= '0;
                word_cnt_d      <= '0;
            end

            //---------------------------------------------------
            // Write arriving memory word into correct buffer location
            //   All decode math happens in the buffer_write_decode
            //   always_comb block above (physical_row_c/tgt_bank_c/
            //   col_idx*_c). This block only performs non-blocking writes
            //   into the buff[] memory, using plain signals as indices.
            //---------------------------------------------------
            if (load_data_valid) begin : write_buf
                // Unpack 4 pixels from 72-bit word into consecutive col positions.
                // Pixel order: MSB=pixel 0, LSB=pixel 3

                buff[tgt_bank_c][physical_row_c][col_idx0_c] <= mem_data_i[WORD_W-1          -: PIXEL_W];
                buff[tgt_bank_c][physical_row_c][col_idx1_c] <= mem_data_i[WORD_W-PIXEL_W-1  -: PIXEL_W];
                buff[tgt_bank_c][physical_row_c][col_idx2_c] <= mem_data_i[WORD_W-2*PIXEL_W-1-: PIXEL_W];
                buff[tgt_bank_c][physical_row_c][col_idx3_c] <= mem_data_i[WORD_W-3*PIXEL_W-1-: PIXEL_W];
            end

            //---------------------------------------------------
            // LOAD -> WAIT_FETCH: reset conv position; rotate banks AFTER load completes
            //---------------------------------------------------
            if (state == LOAD && next_state == WAIT_FETCH) begin
                conv_row <= '0;
                conv_col <= '0;

                //===============================================
                // Full load just completed
                //===============================================
                if (full_load) begin
                    // Full load just filled banks 0,1,2 in natural order.
                    // write_bank=0 means the first partial load overwrites bank 0
                    // (oldest cols 0..7), which is correct.
                    write_bank  <= 2'd0;
                    fetch_order <= '{2'd0, 2'd1, 2'd2};
                //===============================================
                // Partial load just completed
                //===============================================
                end else begin
                    // Partial load just finished writing newest cols into write_bank.
                    // Rotate NOW so write_bank appears at slot 2 (rightmost=newest).
                    // Advance write_bank to the next oldest bank for the next partial load.
                    case (write_bank)
                        2'd0: begin
                            write_bank  <= 2'd1;
                            fetch_order <= '{2'd1, 2'd2, 2'd0};
                        end
                        2'd1: begin
                            write_bank  <= 2'd2;
                            fetch_order <= '{2'd2, 2'd0, 2'd1};
                        end
                        2'd2: begin
                            write_bank  <= 2'd0;
                            fetch_order <= '{2'd0, 2'd1, 2'd2};
                        end
                        default: write_bank <= 2'd0;
                    endcase
                end
            end

            //---------------------------------------------------
            // SECOND_BEGIN_OF_SWEEP: pipeline tracking
            //---------------------------------------------------

            // if (state == SECOND_BEGIN_OF_SWEEP) begin
                
            // end
            

            //---------------------------------------------------
            // FETCH: advance window GROUP position each cycle
            //---------------------------------------------------
            if (state == FETCH && conv_valid_o) begin
                if (conv_col + WIN_GROUP[4:0] >= conv_slides_col) begin
                    conv_col <= '0;
                    if (conv_row == conv_slides_row - 1)
                        conv_row <= '0;  // wraps; FSM leaves FETCH this same cycle
                    else
                        conv_row <= conv_row + 1'b1;
                end else begin
                    conv_col <= conv_col + WIN_GROUP[4:0];  // step by 4 instead of 1
                end
            end

            //---------------------------------------------------
            // FETCH -> IDLE: advance window/sweep counters; rotate banks
            //---------------------------------------------------
            if (state == FETCH && next_state == IDLE) begin

                //===============================================
                // End of horizontal sweep
                //===============================================
                if (win_idx == NUM_H_WIN - 1) begin
                    win_idx         <= '0;
                    word_col_offset <= '0;          // reset column position for new sweep
                    full_load       <= 1'b1;        // next load must be a full load

                    if (sweep_idx == NUM_SWEEPS - 1) begin
                        // Full frame done: reset everything for new frame.
                        sweep_idx  <= '0;
                        row_origin <= '0;
                    end else begin
                        // Advance vertical position: rotate row_origin by +8.
                        // WRAP_ROW(5'd8) directly gives (row_origin+8) mod
                        // IMG_ROWS — no separate _sum/_wrapped signals or
                        // dedicated always_comb block needed any more.
                        sweep_idx  <= sweep_idx + 1'b1;
                        row_origin <= 5'(`WRAP_ROW(5'd8));
                    end

                //===============================================
                // Advance within sweep
                //===============================================
                end else begin
                    // Only update position counters here.
                    // Bank rotation happens at LOAD->WAIT_FETCH after the partial load
                    // has actually written the new data into write_bank.
                    win_idx         <= win_idx + 1'b1;
                    word_col_offset <= word_col_offset + 6'd2; // +8 pixels = +2 words
                    full_load       <= 1'b0;
                    // write_bank and fetch_order unchanged here — updated at LOAD->WAIT_FETCH
                end
            end

        end // rst_n
    end // always_ff

    //=======================================================
    // fsm_next_state
    //=======================================================
    always_comb begin
        next_state = state;
        case (state)
            //===============================================
            // IDLE
            //===============================================
            IDLE: begin
                // start_i triggers a full load (first window of any sweep)
                if (start_i)
                    next_state = LOAD;
                // next_i triggers a partial load (windows 1..29 within a sweep)
                else if (next_i && !full_load && (win_idx == 1))
                    next_state = SECOND_BEGIN_OF_SWEEP;
                else if (next_i && !full_load && (win_idx == NUM_H_WIN - 1))
                    next_state = END_OF_SWEEP;
                else if (next_i && !full_load)
                    next_state = LOAD;
            end
            //===============================================
            // SECOND_BEGIN_OF_SWEEP
            //===============================================
            SECOND_BEGIN_OF_SWEEP: begin
                // next_i triggers a partial load (windows 1..29 within a sweep)
                if (!mem_rd_o)
                    next_state = WAIT_FETCH;
            end

            //===============================================
            // LOAD
            //===============================================
            LOAD: begin
                // Transition when all reads have been issued AND last data received
                // (load_cnt already incremented past the last index when mem_rd_o drops).
                if (load_cnt == load_max_comb && !mem_rd_o)
                    next_state = WAIT_FETCH;
            end
            //===============================================
            // END_OF_SWEEP
            //===============================================
            END_OF_SWEEP: begin
                // next_i triggers a partial load (windows 1..29 within a sweep)
                if (load_cnt == load_max_comb && !mem_rd_o)
                    next_state = WAIT_FETCH;
            end

            //===============================================
            // WAIT_FETCH
            //===============================================
            WAIT_FETCH: begin
                // Hold here (done_load_o stays high) until fetch_en_i pulses.
                if (fetch_en_i)
                    next_state = FETCH;
            end

            //===============================================
            // FETCH
            //===============================================
            FETCH: begin
                if (conv_done_o)
                    next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

    //=======================================================
    // mem_addr_gen
    //=======================================================
    // Full load  (144 reads, row-major):
    //   logical_row = load_cnt / 6,  word_in_row = load_cnt % 6
    //   physical_row = (row_origin + logical_row) mod 24  [via WRAP_ROW]
    //   mem_addr = physical_row * 64 + word_col_offset + word_in_row
    //
    // Partial load (48 reads, row-major):
    //   logical_row = load_cnt / 2,  word_in_row = load_cnt % 2
    //   physical_row = (row_origin + logical_row) mod 24  [via WRAP_ROW]
    //   New cols are the last 2 words of the new window:
    //     word address within row = word_col_offset + 4 + word_in_row
    //   (word_col_offset already advanced to the new window value at FETCH->IDLE)
    logic [4:0] cur_logical_row;
    logic [4:0] cur_physical_row;
    logic [2:0] cur_word_in_row;
    logic [5:0] cur_row_word_offset;  // word offset within the row for this read

    always_comb begin
        load_max_comb = full_load ? TOTAL_LOAD_WORDS[7:0]
                                  : PARTIAL_LOAD_WORDS[7:0];

        //===================================================
        // Full load
        //===================================================
        if (full_load) begin
            cur_logical_row  = 5'(row_cnt);     // 0..23
            cur_word_in_row  = word_cnt;        // 0..5
            // full load reads all 6 words of the window starting at word_col_offset
            cur_row_word_offset = word_col_offset + 6'(cur_word_in_row);
        //===================================================
        // Partial load
        //===================================================
        end else begin
            cur_logical_row  = 5'(row_cnt);     // 0..23
            cur_word_in_row  = word_cnt;        // 0..1
            // partial load reads only the 2 rightmost new words of the window
            // word_col_offset already points to new window; new cols are at +4,+5
            cur_row_word_offset = word_col_offset + 6'd4 + 6'(cur_word_in_row);
        end

        // Apply row_origin rotation via the shared WRAP_ROW macro — no
        // locally-declared sum/wrapped pair needed here any more.
        cur_physical_row = 5'(`WRAP_ROW(cur_logical_row));

        mem_addr_o = 16'((cur_physical_row * WORDS_PER_ROW) + 11'(cur_row_word_offset));
        mem_rd_o   = (state == LOAD) && (load_cnt < load_max_comb);
    end

    //=======================================================
    // conv_window_assembly — precompute arrays (populated by generate blocks below)
    //=======================================================
    // Padding-aware, 4-lane parallel. Buffer reads are inlined directly as
    // buff[bank][row][col] index expressions at the point of use (no
    // automatic function call).
    //
    // None of the row-related quantities (position/pad/physical-row) ever
    // depend on lane g or column c, and none of the column-related
    // quantities depend on row r, so they are split into:
    //   - row-only terms   : CONV_K (5) entries, indexed by r
    //   - column-only terms: WIN_GROUP*CONV_K (20) entries, indexed by g,c
    // and combined only at the final per-pixel emission step.
    //
    //   row_out[r]     = conv_row + r                       (row position)
    //   row_in_pad[r]  = row_out[r] < pad_top || row_out[r] >= active_rows-pad_bot
    //   row_phys[r]    = WRAP_ROW(real_buf_row_start + row_out[r] - pad_top)
    //                    -- only meaningful when !row_in_pad[r]
    //
    //   col_out[g][c]      = out_col_lane[g] + c             (col position)
    //   col_in_pad[g][c]   = col_out[g][c] < pad_left || col_out[g][c] >= active_cols-pad_right
    //   col_buf_idx[g][c]  = real_buf_col_start + col_out[g][c] - pad_left
    //   col_bank_sel[g][c] = fetch_order[col_buf_idx[g][c][4:3]]
    //   col_in_bank[g][c]  = col_buf_idx[g][c][2:0]
    //                    -- only meaningful when !col_in_pad[g][c]
    //
    //   pixel(g,r,c) = 0                                                 if row_in_pad[r] || col_in_pad[g][c] || !lane_valid[g]
    //                = buff[col_bank_sel[g][c]][row_phys[r]][col_in_bank[g][c]]   otherwise
    //
    // Lanes where (conv_col + g) >= conv_slides_col are invalid (border
    // partial group): their pixels are forced to zero and valid_mask_o[g]=0.

    logic [4:0] g_out_col_lane [0:WIN_GROUP-1]; // conv_col + g, one per lane
    logic       g_lane_valid   [0:WIN_GROUP-1]; // 1 when lane is a real window

    // Row-only precompute: CONV_K (5) entries total, not WIN_GROUP*CONV_K*CONV_K (100).
    logic [4:0] row_out    [0:CONV_K-1];
    logic       row_in_pad [0:CONV_K-1];
    logic [4:0] row_phys   [0:CONV_K-1];

    // Column-only precompute: WIN_GROUP*CONV_K (20) entries total.
    logic [4:0] col_out       [0:WIN_GROUP-1][0:CONV_K-1];
    logic       col_in_pad    [0:WIN_GROUP-1][0:CONV_K-1];
    logic [4:0] col_buf_idx   [0:WIN_GROUP-1][0:CONV_K-1]; // pre-bank-split index
    logic [1:0] col_bank_sel  [0:WIN_GROUP-1][0:CONV_K-1];
    logic [2:0] col_in_bank   [0:WIN_GROUP-1][0:CONV_K-1];

    //=======================================================
    // gen_lane_col / gen_row_terms / gen_col_terms
    //=======================================================
    // *** GENERATE-FOR REFACTOR (assign-based, see VLOG-2583 FIX note in
    // the file header) ***: the procedural `for` loops that used to fill
    // these arrays inside one big always_comb are now elaboration-time
    // `generate for` loops, each instance driving its array element with a
    // continuous `assign`. g/r/c are true genvars here (compile-time
    // constants per instance) — the actual math is identical to before.

    // Per-lane starting column and validity (WIN_GROUP instances).
    // *** VLOG-2583 FIX ***: these are pure combinational expressions with
    // no loop-carried state, so each generate instance drives its array
    // element via a continuous `assign` rather than a procedural
    // always_comb block. vlog-2583 ("extra checking... done at vopt time")
    // is specifically a warning about *procedural* always_comb/always_latch
    // processes that Questa can't yet prove don't overlap; continuous
    // assignments to distinct bit-selects/array elements are not subject to
    // that same process-conflict analysis, so the warning goes away at
    // vlog time instead of merely being deferred to vopt.
    generate
        for (genvar g = 0; g < WIN_GROUP; g++) begin : gen_lane_col
            assign g_out_col_lane[g] = conv_col + 5'(g);
            assign g_lane_valid[g]   = (g_out_col_lane[g] < conv_slides_col);
        end
    endgenerate

    // Row-only terms, reused by every lane/column (CONV_K instances).
    generate
        for (genvar r = 0; r < CONV_K; r++) begin : gen_row_terms
            assign row_out[r]    = conv_row + 5'(r);
            assign row_in_pad[r] = (row_out[r] <  5'(pad_top))
                                 || (row_out[r] >= active_rows - 5'(pad_bot));
            // WRAP_ROW is evaluated unconditionally; if row_in_pad[r] is
            // true the result may be a "don't care" underflowed value, but
            // it is never used to index buff[] in that case (see
            // gen_pixel_* below) — same underflow-guard philosophy as the
            // original.
            assign row_phys[r] = 5'(`WRAP_ROW(5'(real_buf_row_start) + row_out[r] - 5'(pad_top)));
        end
    endgenerate

    // Column-only terms, reused across all rows (WIN_GROUP*CONV_K instances).
    generate
        for (genvar g = 0; g < WIN_GROUP; g++) begin : gen_col_terms_lane
            for (genvar c = 0; c < CONV_K; c++) begin : gen_col_terms_col
                assign col_out[g][c]    = g_out_col_lane[g] + 5'(c);
                assign col_in_pad[g][c] = (col_out[g][c] <  5'(pad_left))
                                        || (col_out[g][c] >= active_cols - 5'(pad_right));
                assign col_buf_idx[g][c]  = 5'(real_buf_col_start) + col_out[g][c] - 5'(pad_left);
                assign col_bank_sel[g][c] = fetch_order[col_buf_idx[g][c][4:3]];
                assign col_in_bank[g][c]  = col_buf_idx[g][c][2:0];
            end
        end
    endgenerate

    //=======================================================
    // gen_lane_valid_mask
    //=======================================================
    // valid_mask_o[g]: one instance per lane (WIN_GROUP total), driven by
    // `assign` (see VLOG-2583 FIX note in the file header). Held low
    // outside FETCH, same as the original default '0 + conditional overwrite.
    generate
        for (genvar g = 0; g < WIN_GROUP; g++) begin : gen_lane_valid_mask
            assign valid_mask_o[g] = (state == FETCH) ? g_lane_valid[g] : 1'b0;
        end
    endgenerate

    //=======================================================
    // gen_pixel_lane / gen_pixel_row / gen_pixel_col
    //=======================================================
    // Pixel emission: one instance per (g,r,c) — WIN_GROUP*CONV_K*CONV_K
    // (100) total, each driving exactly one PIXEL_W-wide, non-overlapping
    // slice of conv_pixels_o via a continuous `assign` (see VLOG-2583 FIX
    // note in the file header) — offsets are distinct compile-time
    // constants per instance, so there is no multiple-driver hazard.
    // PIXEL_BIT_OFFSET is a genvar-derived localparam instead of the old
    // runtime `pixel_bit_offset` signal, since g/r/c never change at
    // runtime within a given generated instance.
    generate
        for (genvar g = 0; g < WIN_GROUP; g++) begin : gen_pixel_lane
            for (genvar r = 0; r < CONV_K; r++) begin : gen_pixel_row
                for (genvar c = 0; c < CONV_K; c++) begin : gen_pixel_col
                    // Pixel slot within this lane's 450-bit window:
                    //   top-left = MSB (slot 24), bottom-right = LSB (slot 0)
                    localparam int PIXEL_BIT_OFFSET =
                        (g * WINDOW_BITS) +
                        (((CONV_K*CONV_K-1)-(r*CONV_K+c)) * PIXEL_W);

                    // Direct buff[] index — no function call.
                    assign conv_pixels_o[PIXEL_BIT_OFFSET +: PIXEL_W] =
                        (state == FETCH &&
                         !(row_in_pad[r] || col_in_pad[g][c] || !g_lane_valid[g]))
                            ? buff[col_bank_sel[g][c]][row_phys[r]][col_in_bank[g][c]]
                            : '0;
                end
            end
        end
    endgenerate

    //=======================================================
    // conv_window_assembly (control-only: conv_valid_o / conv_done_o)
    //=======================================================
    // Everything that used to be per-lane/per-row/per-column/per-pixel data
    // now lives in the generate blocks above. This block only sets the two
    // single-bit control outputs, which never depended on g/r/c and so
    // stay as an ordinary always_comb rather than a generate-for.
    always_comb begin
        conv_valid_o = 1'b0;
        conv_done_o  = 1'b0;

        if (state == FETCH) begin
            conv_valid_o = 1'b1;

            //-----------------------------------------------
            // conv_done_o: last row AND last group of that row
            //-----------------------------------------------
            if ((conv_row == conv_slides_row - 1) &&
                (conv_col + WIN_GROUP[4:0] >= conv_slides_col))
                conv_done_o = 1'b1;
        end
    end

    //=======================================================
    // done_frame_done_stage
    //=======================================================
    // done_r    : pulses one cycle when all 30 horizontal windows of a sweep
    //             are done (registered to align with the last conv_done_o
    //             clock edge).
    // frame_done_r : pulses one cycle after all 30 sweeps complete (900
    //             windows); the frame itself resets via rst_n or the
    //             counter-reset path inside FETCH->IDLE above.
    // Active-LOW, asynchronous reset (matches rst_n's declared behaviour).
    logic done_r, frame_done_r;

    always_ff @(posedge clk or negedge rst_n) begin
        //===================================================
        // Reset
        //===================================================
        if (!rst_n) begin
            done_r       <= 1'b0;
            frame_done_r <= 1'b0;
        //===================================================
        // Running
        //===================================================
        end else begin
            done_r       <= 1'b0;  // default: deassert each cycle
            frame_done_r <= 1'b0;

            // Fires when the 30th horizontal window's conv pass completes.
            if (state == FETCH && next_state == IDLE && conv_done_o) begin
                if (win_idx == NUM_H_WIN - 1) begin
                    done_r <= 1'b1;
                    if (sweep_idx == NUM_SWEEPS - 1)
                        frame_done_r <= 1'b1;  // full 256x256 frame complete
                end
            end
        end
    end

    //=======================================================
    // status_outputs
    //=======================================================
    // done_load_o : combinational, high throughout WAIT_FETCH (handshake gate).
    assign state_o      = state;
    assign done_load_o  = (state == WAIT_FETCH);
    assign done_o       = done_r;
    assign frame_done_o = frame_done_r;

endmodule

`undef WRAP_ROW

`endif // MAPPING_CONTROLLER_SV
