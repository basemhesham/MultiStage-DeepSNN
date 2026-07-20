// =============================================================================
// mapping_controller.sv
// =============================================================================
// Description:
//   Reads a 24-row x 256-col pixel matrix from memory (72-bit words,
//   4 pixels/word, 18 bits/pixel) and produces sequential 5x5 sliding-window
//   outputs over a 24x24 pixel buffer.
//
// --------------------------------------------------------------------------
// MEMORY LAYOUT
// --------------------------------------------------------------------------
//   Full matrix : 24 rows x 256 cols
//   Word width  : 72 bits = 4 pixels x 18 bits
//   Row r base  : r * 64  (64 words per row)
//   1-cycle read latency: address presented cycle N, data valid cycle N+1
//
// --------------------------------------------------------------------------
// BUFFER ORGANISATION  (banks store COLUMNS, not rows)
// --------------------------------------------------------------------------
//   The 24x24 pixel buffer is split into 3 column-banks:
//     bank 0 : 24 rows x cols  0.. 7
//     bank 1 : 24 rows x cols  8..15
//     bank 2 : 24 rows x cols 16..23
//   buf[bank][row][col_within_bank]  col_within_bank = 0..7
//
// --------------------------------------------------------------------------
// HORIZONTAL SLIDING  (30 windows across 256 cols)
// --------------------------------------------------------------------------
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
//
// --------------------------------------------------------------------------
// BANK ROTATION
// --------------------------------------------------------------------------
//   fetch_order[0..2] maps logical col-group {0..7, 8..15, 16..23} to physical
//   banks.  After each partial load the oldest bank becomes the new rightmost.
//
//   Initially (full load):  fetch_order = {0, 1, 2}  write_bank -> 0 next
//   After partial load #1:  write_bank=0 filled;  fetch_order = {1, 2, 0}
//   After partial load #2:  write_bank=1 filled;  fetch_order = {2, 0, 1}
//   After partial load #3:  write_bank=2 filled;  fetch_order = {0, 1, 2}
//   ... repeats every 3 partial loads
//
// --------------------------------------------------------------------------
// ROW ORIGIN ROTATION  (across vertical sweeps of the 256x256 frame)
// --------------------------------------------------------------------------
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
//
// --------------------------------------------------------------------------
// 5x5 CONV SLIDING WINDOW  (mode-aware with zero padding)
// --------------------------------------------------------------------------
//   The active fetch region and zero-padding are derived INTERNALLY from
//   win_idx and sweep_idx — no external mode input required.
//
//   mode_r[1] = 1 when sweep_idx == 0 or sweep_idx == NUM_SWEEPS-1 (row border)
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
//
// --------------------------------------------------------------------------
// LOAD/FETCH HANDSHAKE  (fetch_en_i / done_load_o)
// --------------------------------------------------------------------------
//   After a LOAD phase completes (full or partial), the controller does NOT
//   automatically proceed to FETCH. Instead it enters WAIT_FETCH and asserts
//   done_load_o, holding there until the external fetch_en_i pulse arrives.
//   This applies uniformly to every load (full and partial) since it is a
//   stage-level gate, not tied to start_i/next_i.
//
//     LOAD complete -> WAIT_FETCH (done_load_o=1) -> fetch_en_i pulse -> FETCH (done_load_o=0)
//
// =============================================================================

module mapping_controller #(
    parameter int PIXEL_W      = 18,   // bits per pixel
    parameter int WORD_W       = 72,   // bits per memory word (4 pixels)
    parameter int IMG_ROWS     = 24,   // rows in memory (circular buffer)
    parameter int IMG_COLS     = 256,  // columns in full image
    parameter int BUF_SIZE     = 24,   // buffer dimension (24x24)
    parameter int BANK_COLS    = 8,    // pixel-columns per bank
    parameter int CONV_K       = 5,    // conv kernel size
    parameter int NUM_H_WIN    = 30,   // horizontal windows per sweep (30)
    parameter int NUM_SWEEPS   = 30    // vertical sweeps per frame (30)
)(
    input  logic                              clk,
    input  logic                              rst_n,         // active-low sync reset

    // --- control ---
    input  logic                              start_i,       // begin full load (new sweep)
    input  logic                              next_i,        // begin partial load (next h-window)
    input  logic                              fetch_en_i,    // one-cycle pulse: permission to enter FETCH after a load

    // --- memory interface ---
    output logic [15:0]                       mem_addr_o,    // word address
    output logic                              mem_rd_o,      // read enable
    input  logic [WORD_W-1:0]                 mem_data_i,    // read data (1-cycle latency)

    // --- conv output ---
    output logic [CONV_K*CONV_K*PIXEL_W-1:0]  conv_pixels_o, // 25 packed pixels (zeros for pad positions)
    output logic                              conv_valid_o,  // one cycle per window
    output logic                              conv_done_o,   // pulse after last window of active region
    output logic                              done_o,        // pulse after last h-window of a sweep
    output logic                              frame_done_o,  // pulse after all sweeps complete (full frame)
    output logic                              done_load_o,   // high while waiting in WAIT_FETCH for fetch_en_i
    output logic [1:0]                        state_o        // 00=IDLE 01=LOAD 10=FETCH 11=WAIT_FETCH (for TB)
);

    // =========================================================================
    // Local parameters
    // =========================================================================
    localparam int WORDS_PER_ROW     = IMG_COLS / 4;          // 64 words per image row
    localparam int WORDS_PER_BUF     = BUF_SIZE / 4;          // 6 words = 24 pixels per row
    localparam int WORDS_PER_BANK    = BANK_COLS / 4;         // 2 words = 8 pixels per row
    // Full load  : 24 rows x 6 words = 144 words
    localparam int TOTAL_LOAD_WORDS  = IMG_ROWS * WORDS_PER_BUF;
    // Partial load: 24 rows x 2 new words = 48 words  (rightmost 8 new cols)
    localparam int PARTIAL_LOAD_WORDS = IMG_ROWS * WORDS_PER_BANK;
    // CONV_SLIDES and TOTAL_CONV are now dynamic (see mode decode block below).
    // Maximum: 24-5+1=20 slides/axis (interior), Minimum: 18-5+1=14 (border)

    // =========================================================================
    // Pixel buffer: 3 col-banks x 24 rows x 8 cols
    // buf[bank][row][col_in_bank]
    // =========================================================================
    logic [PIXEL_W-1:0] buff [0:2][0:IMG_ROWS-1][0:BANK_COLS-1];

    // =========================================================================
    // FSM
    // =========================================================================
    typedef enum logic [1:0] {
        IDLE       = 2'b00,
        LOAD       = 2'b01,
        FETCH      = 2'b10,
        WAIT_FETCH = 2'b11   // new: gated handshake state between LOAD and FETCH
    } state_t;

    state_t state, next_state;

    // =========================================================================
    // Registers
    // =========================================================================

    // horizontal window index within current sweep (0..29)
    logic [4:0] win_idx;

    // vertical sweep index (0..29)
    logic [4:0] sweep_idx;

    // word-column offset for start of current 24-pixel window
    // window k -> word offset = k*2  (each step = 8 pixels = 2 words)
    logic [5:0] word_col_offset;

    // row origin: which physical memory row maps to logical row 0
    // rotates +8 each sweep: 0, 8, 16, 0, 8, 16 ...
    logic [4:0] row_origin;  // 0, 8, or 16

    // load counter: number of read requests issued this load phase
    logic [7:0] load_cnt;

    // 1 = full load (144 words), 0 = partial load (48 words)
    logic full_load;

    // which physical bank receives the new data in partial load
    // rotates 0->1->2->0 after each partial load
    logic [1:0] write_bank;

    // fetch_order[i] = physical bank that is logical col-group i
    // fetch_order[0] = bank for cols  0..7  (leftmost)
    // fetch_order[1] = bank for cols  8..15
    // fetch_order[2] = bank for cols 16..23 (rightmost)
    logic [1:0] fetch_order [0:2];

    // conv window top-left position within the ACTIVE region
    // Range: 0..13 (18-active axis) or 0..19 (24-active axis)
    logic [4:0] conv_row;
    logic [4:0] conv_col;

    // -------------------------------------------------------------------------
    // Internal mode decode signals — all combinational from win_idx/sweep_idx
    // -------------------------------------------------------------------------
    // mode_r: internally generated, mirrors the 4-case border/interior logic
    //   mode_r[1]: 1 = row border (sweep is first or last)
    //   mode_r[0]: 1 = col border (window is first or last)
    logic [1:0] mode_r;

    // padding amounts (0 or 2) — only one of top/bot and one of left/right
    // can be non-zero at a time for any given window
    logic [1:0] pad_top;        // 0 or 2
    logic [1:0] pad_bot;        // 0 or 2
    logic [1:0] pad_left;       // 0 or 2
    logic [1:0] pad_right;      // 0 or 2

    // active region dimensions (18 or 24 per axis)
    logic [4:0] active_rows;    // 18 or 24
    logic [4:0] active_cols;    // 18 or 24

    // start position inside the 24x24 buffer for real (non-pad) pixels
    // 0 when pad is on top/left side; 8 when pad is on bot/right side
    logic [3:0] real_buf_row_start;  // 0 or 8
    logic [3:0] real_buf_col_start;  // 0 or 8

    // number of 5x5 kernel positions per axis (14 or 20)
    logic [4:0] conv_slides_row;
    logic [4:0] conv_slides_col;

    // 1-cycle pipeline registers for memory read latency
    logic       load_data_valid;  // data arriving this cycle is valid
    logic [7:0] load_cnt_d;       // load_cnt value when the read was issued

    // =========================================================================
    // Internal mode decode — combinational
    // Generates mode_r, padding amounts, active region, and real buffer offsets
    // purely from win_idx and sweep_idx (both stable throughout FETCH).
    // No external mode input required.
    // =========================================================================
    always_comb begin
        // --- mode_r: row border when sweep is first or last ---
        mode_r[1] = (sweep_idx == 5'd0) || (sweep_idx == NUM_SWEEPS - 1);
        // --- mode_r: col border when window is first or last ---
        mode_r[0] = (win_idx  == 5'd0) || (win_idx  == NUM_H_WIN  - 1);

        // --- padding: only on the image-border side, 2 pixels ---
        // row axis: top padding for first sweep, bottom for last sweep
        pad_top = (mode_r[1] && sweep_idx == 5'd0)           ? 2'd2 : 2'd0;
        pad_bot = (mode_r[1] && sweep_idx == NUM_SWEEPS - 1) ? 2'd2 : 2'd0;
        // col axis: left padding for first window, right for last window
        pad_left  = (mode_r[0] && win_idx == 5'd0)          ? 2'd2 : 2'd0;
        pad_right = (mode_r[0] && win_idx == NUM_H_WIN - 1) ? 2'd2 : 2'd0;

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

    // =========================================================================
    // FSM sequential
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state           <= IDLE;
            win_idx         <= '0;
            sweep_idx       <= '0;
            word_col_offset <= '0;
            row_origin      <= '0;
            load_cnt        <= '0;
            load_cnt_d      <= '0;
            full_load       <= 1'b1;
            write_bank      <= 2'd0;
            fetch_order     <= '{2'd0, 2'd1, 2'd2};
            conv_row        <= '0;
            conv_col        <= '0;
            load_data_valid <= 1'b0;
        end else begin
            state <= next_state;

            // ------------------------------------------------------------------
            // LOAD: pipeline tracking
            // ------------------------------------------------------------------
            if (state == LOAD) begin
                load_data_valid <= mem_rd_o;   // data arrives one cycle after rd
                load_cnt_d      <= load_cnt;   // capture index of the issued read

                if (mem_rd_o)
                    load_cnt <= load_cnt + 1'b1;
            end else begin
                load_data_valid <= 1'b0;
                load_cnt_d      <= '0;
            end

            // ------------------------------------------------------------------
            // Entering LOAD: reset load counter
            // ------------------------------------------------------------------
            if (next_state == LOAD && state != LOAD) begin
                load_cnt        <= '0;
                load_cnt_d      <= '0;
                load_data_valid <= 1'b0;
            end

            // ------------------------------------------------------------------
            // Write arriving memory word into correct buffer location
            // ------------------------------------------------------------------
            if (load_data_valid) begin : write_buf
                // ----------------------------------------------------------------
                // Decode load_cnt_d into (physical_row, bank, col_in_bank)
                //
                // Full load layout (144 words, row-major):
                //   word index = row * 6 + word_in_row  (word_in_row 0..5)
                //   word_in_row 0,1 -> bank 0, col_in_bank 0..7
                //   word_in_row 2,3 -> bank 1, col_in_bank 0..7
                //   word_in_row 4,5 -> bank 2, col_in_bank 0..7
                //
                // Partial load layout (48 words, row-major):
                //   word index = row * 2 + word_in_row  (word_in_row 0..1)
                //   all words go to write_bank
                //   word_in_row 0 -> col_in_bank 0..3
                //   word_in_row 1 -> col_in_bank 4..7
                //
                // In both cases the physical memory row is rotated:
                //   physical_row = (row_origin + logical_row) % IMG_ROWS
                // ----------------------------------------------------------------
                logic [5:0] logical_row;
                logic [4:0] physical_row;
                logic [2:0] word_in_row;
                logic [1:0] tgt_bank;
                logic [2:0] col_base;    // first col_in_bank index for this word

                if (full_load) begin
                    logical_row  = load_cnt_d / WORDS_PER_BUF;           // 0..23
                    word_in_row  = load_cnt_d % WORDS_PER_BUF;           // 0..5
                    // bank = word_in_row / 2  (pairs of words per bank)
                    tgt_bank     = word_in_row[2:1];                      // 0,1,2
                    // col base within bank: word_in_row even->0, odd->4
                    col_base     = {2'b00, word_in_row[0]} << 2;          // 0 or 4
                end else begin
                    logical_row  = load_cnt_d / WORDS_PER_BANK;           // 0..23
                    word_in_row  = load_cnt_d % WORDS_PER_BANK;           // 0..1
                    tgt_bank     = write_bank;
                    col_base     = {2'b00, word_in_row[0]} << 2;          // 0 or 4
                end

                // Apply row_origin rotation (wraps within 24 rows)
                physical_row = (row_origin + logical_row[4:0]) % IMG_ROWS;

                // Unpack 4 pixels from 72-bit word into consecutive col positions
                // Pixel order: MSB=pixel 0, LSB=pixel 3
                buff[tgt_bank][physical_row][col_base + 0] <= mem_data_i[WORD_W-1          -: PIXEL_W]; // bits 71:54
                buff[tgt_bank][physical_row][col_base + 1] <=
                    mem_data_i[WORD_W-PIXEL_W-1  -: PIXEL_W]; // bits 53:36
                buff[tgt_bank][physical_row][col_base + 2] <=
                    mem_data_i[WORD_W-2*PIXEL_W-1-: PIXEL_W]; // bits 35:18
                buff[tgt_bank][physical_row][col_base + 3] <=
                    mem_data_i[WORD_W-3*PIXEL_W-1-: PIXEL_W]; // bits 17:0
            end

            // ------------------------------------------------------------------
            // LOAD -> WAIT_FETCH: reset conv position; rotate banks AFTER load completes
            // (Bank rotation logic unchanged — only the destination state changed
            //  from FETCH to WAIT_FETCH, since FETCH now requires fetch_en_i first.)
            // ------------------------------------------------------------------
            if (state == LOAD && next_state == WAIT_FETCH) begin
                conv_row <= '0;
                conv_col <= '0;

                if (full_load) begin
                    // Full load just filled banks 0,1,2 in natural order.
                    // write_bank=0 means the first partial load overwrites bank 0
                    // (oldest cols 0..7), which is correct.
                    write_bank  <= 2'd0;
                    fetch_order <= '{2'd0, 2'd1, 2'd2};
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

            // ------------------------------------------------------------------
            // FETCH: advance 5x5 window position each cycle
            // Uses dynamic conv_slides_row/col from mode decode block so the
            // sweep stops at the correct boundary for each border/interior case.
            // ------------------------------------------------------------------
            if (state == FETCH && conv_valid_o) begin
                if (conv_col == conv_slides_col - 1) begin
                    conv_col <= '0;
                    if (conv_row == conv_slides_row - 1)
                        conv_row <= '0;  // wraps; FSM leaves FETCH this same cycle
                    else
                        conv_row <= conv_row + 1'b1;
                end else begin
                    conv_col <= conv_col + 1'b1;
                end
            end

            // ------------------------------------------------------------------
            // FETCH -> IDLE: advance window/sweep counters; rotate banks
            // ------------------------------------------------------------------
            if (state == FETCH && next_state == IDLE) begin

                if (win_idx == NUM_H_WIN - 1) begin
                    // ---- End of horizontal sweep --------------------------------
                    win_idx         <= '0;
                    word_col_offset <= '0;          // reset column position for new sweep
                    full_load       <= 1'b1;        // next load must be a full load

                    if (sweep_idx == NUM_SWEEPS - 1) begin
                        // Full frame done: reset everything for new frame
                        sweep_idx  <= '0;
                        row_origin <= '0;
                    end else begin
                        // Advance vertical position: rotate row_origin by +8
                        sweep_idx  <= sweep_idx + 1'b1;
                        row_origin <= (row_origin + 5'd8 >= IMG_ROWS)
                                    ? row_origin + 5'd8 - IMG_ROWS[4:0]
                                    : row_origin + 5'd8;
                    end

                end else begin
                    // ---- Advance within sweep -----------------------------------
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

    // =========================================================================
    // FSM combinational next-state
    // =========================================================================
    always_comb begin
        next_state = state;
        case (state)
            IDLE: begin
                // start_i triggers a full load (first window of any sweep)
                if (start_i)
                    next_state = LOAD;
                // next_i triggers a partial load (windows 1..29 within a sweep)
                else if (next_i && !full_load)
                    next_state = LOAD;
            end

            LOAD: begin
                logic [7:0] load_max;
                load_max = full_load ? TOTAL_LOAD_WORDS[7:0]
                                     : PARTIAL_LOAD_WORDS[7:0];
                // Transition when all reads have been issued AND last data received
                // (load_cnt already incremented past the last index when mem_rd_o drops)
                // NOTE: destination changed from FETCH to WAIT_FETCH — the handshake
                // gate now sits between LOAD completion and FETCH entry.
                if (load_cnt == load_max && !mem_rd_o)
                    next_state = WAIT_FETCH;
            end

            WAIT_FETCH: begin
                // Hold here (done_load_o stays high) until fetch_en_i pulses.
                // Applies uniformly to every load (full or partial) since this
                // gate is purely stage-based, independent of start_i/next_i.
                if (fetch_en_i)
                    next_state = FETCH;
            end

            FETCH: begin
                if (conv_done_o)
                    next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

    // =========================================================================
    // Memory address generation
    // =========================================================================
    // Full load  (144 reads, row-major):
    //   logical_row = load_cnt / 6,  word_in_row = load_cnt % 6
    //   physical_row = (row_origin + logical_row) % 24
    //   mem_addr = physical_row * 64 + word_col_offset + word_in_row
    //
    // Partial load (48 reads, row-major):
    //   logical_row = load_cnt / 2,  word_in_row = load_cnt % 2
    //   physical_row = (row_origin + logical_row) % 24
    //   New cols are the last 2 words of the new window:
    //     word address within row = word_col_offset + 4 + word_in_row
    //   (word_col_offset already advanced to the new window value at FETCH->IDLE)
    // =========================================================================
    logic [7:0] load_max_comb;
    logic [4:0] cur_logical_row;
    logic [4:0] cur_physical_row;
    logic [2:0] cur_word_in_row;
    logic [5:0] cur_row_word_offset;  // word offset within the row for this read

    always_comb begin
        load_max_comb = full_load ? TOTAL_LOAD_WORDS[7:0]
                                  : PARTIAL_LOAD_WORDS[7:0];

        if (full_load) begin
            cur_logical_row  = load_cnt / WORDS_PER_BUF;     // 0..23
            cur_word_in_row  = load_cnt % WORDS_PER_BUF;     // 0..5
            // full load reads all 6 words of the window starting at word_col_offset
            cur_row_word_offset = word_col_offset + cur_word_in_row;
        end else begin
            cur_logical_row  = load_cnt / WORDS_PER_BANK;    // 0..23
            cur_word_in_row  = load_cnt % WORDS_PER_BANK;    // 0..1
            // partial load reads only the 2 rightmost new words of the window
            // word_col_offset already points to new window; new cols are at +4,+5
            cur_row_word_offset = word_col_offset + 4 + cur_word_in_row;
        end

        // Apply row_origin rotation
        cur_physical_row = (row_origin + cur_logical_row) % IMG_ROWS;

        mem_addr_o = (cur_physical_row * WORDS_PER_ROW) + cur_row_word_offset;
        mem_rd_o   = (state == LOAD) && (load_cnt < load_max_comb);
    end

    // =========================================================================
    // Conv window pixel assembly  (padding-aware)
    // =========================================================================
    // Logical 24x24 buffer access:
    //   col  0.. 7 -> bank fetch_order[0], col_in_bank = col
    //   col  8..15 -> bank fetch_order[1], col_in_bank = col - 8
    //   col 16..23 -> bank fetch_order[2], col_in_bank = col - 16
    //   row        -> physical_row = (row_origin + logical_row) % IMG_ROWS
    //
    // For each kernel position (kr, kc) within the 5x5 kernel:
    //   output_row = conv_row + kr  (position within active region)
    //   output_col = conv_col + kc
    //
    //   in_pad = output_row <  pad_top                      (top zero zone)
    //         || output_row >= active_rows - pad_bot        (bottom zero zone)
    //         || output_col <  pad_left                     (left zero zone)
    //         || output_col >= active_cols - pad_right      (right zero zone)
    //
    //   pixel = 0  if in_pad
    //         = buf[real_buf_row_start + output_row - pad_top]
    //              [real_buf_col_start + output_col - pad_left]  otherwise
    // =========================================================================

    function automatic logic [PIXEL_W-1:0] read_buf_pixel(
        input logic [4:0] log_row,  // 0..23  logical row within 24x24 buffer
        input logic [4:0] log_col   // 0..23  logical col within 24x24 buffer
    );
        logic [1:0] bank_sel;
        logic [2:0] col_in_bank;
        logic [4:0] phys_row;

        bank_sel    = fetch_order[log_col[4:3]]; // log_col/8 selects fetch_order slot
        col_in_bank = log_col[2:0];              // log_col % 8
        phys_row    = (row_origin + log_row) % IMG_ROWS;

        return buff[bank_sel][phys_row][col_in_bank];
    endfunction

    // =========================================================================
    // Conv window pixel assembly  (padding-aware, QuestaSim-safe)
    // =========================================================================
    // All temporaries are declared at module level (no declarations inside
    // procedural blocks after statements).
    // Underflow guard: buf_row/col only computed when NOT in pad zone.
    // =========================================================================

    // Declare loop temporaries at module level
    logic [4:0] g_out_row [0:CONV_K-1][0:CONV_K-1];
    logic [4:0] g_out_col [0:CONV_K-1][0:CONV_K-1];
    logic       g_in_pad  [0:CONV_K-1][0:CONV_K-1];
    logic [4:0] g_buf_row [0:CONV_K-1][0:CONV_K-1];
    logic [4:0] g_buf_col [0:CONV_K-1][0:CONV_K-1];

    always_comb begin
        // Default outputs
        conv_pixels_o = '0;
        conv_valid_o  = 1'b0;
        conv_done_o   = 1'b0;

        // Pre-compute all per-kernel-position signals
        for (int r = 0; r < CONV_K; r++) begin
            for (int c = 0; c < CONV_K; c++) begin
                // Position within the active region
                g_out_row[r][c] = conv_row + 5'(r);
                g_out_col[r][c] = conv_col + 5'(c);

                // In-pad check: falls in any zero-padding zone?
                g_in_pad[r][c] =
                    (g_out_row[r][c] <  pad_top)
                 || (g_out_row[r][c] >= active_rows - pad_bot)
                 || (g_out_col[r][c] <  pad_left)
                 || (g_out_col[r][c] >= active_cols - pad_right);

                // Buffer coordinates — only valid when NOT in pad.
                // Guard against underflow: use max(0, ...) via conditional.
                // real_buf_row_start + output_row - pad_top  (pad_top <= output_row here)
                // real_buf_col_start + output_col - pad_left (pad_left <= output_col here)
                if (g_in_pad[r][c]) begin
                    g_buf_row[r][c] = 5'd0;   // don't care, gated below
                    g_buf_col[r][c] = 5'd0;
                end else begin
                    g_buf_row[r][c] = 5'(real_buf_row_start)
                                    + g_out_row[r][c]
                                    - 5'(pad_top);
                    g_buf_col[r][c] = 5'(real_buf_col_start)
                                    + g_out_col[r][c]
                                    - 5'(pad_left);
                end
            end
        end

        if (state == FETCH) begin
            conv_valid_o = 1'b1;

            for (int r = 0; r < CONV_K; r++) begin
                for (int c = 0; c < CONV_K; c++) begin
                    // Pixel slot: top-left = MSB (slot 24), bottom-right = LSB (slot 0)
                    // slot = (CONV_K*CONV_K-1) - (r*CONV_K+c) = 24 - r*5 - c
                    if (g_in_pad[r][c]) begin
                        conv_pixels_o[((CONV_K*CONV_K-1)-(r*CONV_K+c))*PIXEL_W +: PIXEL_W] = '0;
                    end else begin
                        conv_pixels_o[((CONV_K*CONV_K-1)-(r*CONV_K+c))*PIXEL_W +: PIXEL_W]
                            = read_buf_pixel(g_buf_row[r][c], g_buf_col[r][c]);
                    end
                end
            end

            // conv_done_o: last position of active region
            if (conv_row == conv_slides_row - 1 && conv_col == conv_slides_col - 1)
                conv_done_o = 1'b1;
        end
    end

    // =========================================================================
    // done_o  : pulses one cycle when all 30 horizontal windows of a sweep done
    //           (registered to align with last conv_done_o clock edge)
    // frame_done_o : pulses one cycle after all 30 sweeps complete (900 windows)
    //               also resets internal state for next frame via rst_n or
    //               the counter reset path inside FETCH->IDLE above
    // done_load_o : combinational, high throughout WAIT_FETCH (handshake gate)
    // =========================================================================
    assign state_o     = state;
    assign done_load_o = (state == WAIT_FETCH);

    logic done_r, frame_done_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            done_r       <= 1'b0;
            frame_done_r <= 1'b0;
        end else begin
            done_r       <= 1'b0;  // default: deassert each cycle
            frame_done_r <= 1'b0;

            // Fires when the 30th horizontal window's conv pass completes
            if (state == FETCH && next_state == IDLE && conv_done_o) begin
                if (win_idx == NUM_H_WIN - 1) begin
                    done_r <= 1'b1;
                    if (sweep_idx == NUM_SWEEPS - 1)
                        frame_done_r <= 1'b1;  // full 256x256 frame complete
                end
            end
        end
    end

    assign done_o       = done_r;
    assign frame_done_o = frame_done_r;

endmodule
