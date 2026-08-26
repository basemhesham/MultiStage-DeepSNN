`ifndef MAPPING_CONTROLLER_SV
`define MAPPING_CONTROLLER_SV

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

    // local parameters

    localparam int CORNER_WINDOW_SIZE   = 64;                   // 16 row * 4 words (real data)
    localparam int SIDE_PAD_WINDOW_SIZE = 96;                   // 16 row * 6 words or 24 * 4 (real data)
    localparam int NO_PAD_WINDOW_SIZE   = 144;                  // 24 row * 6 words (real data)

    //=======================================================
    // Internals
    //=======================================================
    logic [PIXEL_W-1:0] buff [0:IMG_ROWS-1][0:23];  //full window 24 rows with 6words collumn = 24 collumn

    logic [PIXEL_W-1:0] bank_1 [0:IMG_ROWS-1][0:BANK_COLS-1];
    logic [PIXEL_W-1:0] bank_2 [0:IMG_ROWS-1][0:BANK_COLS-1];
    logic [PIXEL_W-1:0] bank_3 [0:IMG_ROWS-1][0:BANK_COLS-1];

    //////////////////////////////////////////////////////////

    logic load_data_valid;          // saves "mem_rd_o" in reg

    // Position / sequencing registers.
    logic [4:0] win_idx;             // horizontal window index within current sweep (0..29)
    logic [4:0] sweep_idx;           // vertical sweep index (0..29)

    //need to make sure that if the is 30 sweeps or 31 same fo windows

    logic pad_top, pad_bot;    // 0 or 1
    logic pad_left, pad_right; // 0 or 1
    logic pad_top_left;
    logic pad_top_right;
    logic pad_bot_left;
    logic pad_bot_right;

    logic [7:0] load_cnt;            // number of read requests issued this load phase // till 144=24*6w or
                                     // 24*4w = 96 for padding left or write
                                     // 16*6w = 96 for padding top or bottom
                                     // 16*4w = 64 for corner cases

    logic [7:0] load_max_comb;
    logic [4:0] row_max_comb;        // 24 or 18
    logic [2:0] col_max_comb;        // 6 or 4

    logic [4:0] row_cnt;             // max 24
    logic [4:0] col_cnt;             // max 24

    //////////////////////////////////////////////////////////

    // FSM.
    typedef enum logic [1:0] {
        IDLE       = 2'b00,
        LOAD       = 2'b01,
        FETCH      = 2'b10,
        WAIT_FETCH = 2'b11   // gated handshake state between LOAD and FETCH
    } state_t;

    state_t state, next_state;

    //=======================================================
    // mode_decode
    //=======================================================
    // Generates mode_r, padding amounts, active region, and real buffer
    // offsets purely from win_idx and sweep_idx (both stable throughout
    // FETCH). No external mode input required.

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

    always_comb begin

        // row axis: top padding for first sweep, bottom for last sweep
        pad_top = (sweep_idx == 5'd0)           ? 1'b1 : 1'b0;
        pad_bot = (sweep_idx == NUM_SWEEPS - 1) ? 1'b1 : 1'b0;
        // col axis: left padding for first window, right for last window
        pad_left  = (win_idx == 5'd0)           ? 1'b1 : 1'b0;
        pad_right = (win_idx == NUM_H_WIN - 1)  ? 1'b1 : 1'b0;

        pad_top_left  = pad_top && pad_left;
        pad_top_right = pad_top && pad_right;
        pad_bot_left  = pad_bot && pad_left;
        pad_bot_right = pad_bot && pad_right;

        //calculate max load
        if (pad_top_left || pad_top_right || pad_bot_left || pad_bot_right) begin
            load_max_comb = CORNER_WINDOW_SIZE;
        end
        else if (pad_top || pad_bot || pad_left || pad_right) begin
            load_max_comb = SIDE_PAD_WINDOW_SIZE;
        end
        else begin
            load_max_comb = NO_PAD_WINDOW_SIZE;
        end

        if (pad_top || pad_bot) begin
            row_max_comb = 18;  //with padding
        end
        else begin
            row_max_comb = 24;
        end

        if (pad_left || pad_right) begin
            col_max_comb = 18;  //with padding
        end
        else begin
            row_max_comb = 24;
        end


        // --- active region: 18 on border axes, 24 on interior ---
        active_rows = mode_r[1] ? 5'd18 : 5'd24;
        active_cols = mode_r[0] ? 5'd18 : 5'd24;

        // // --- real buffer start: 0 when pad is on top/left,
        // //                        8 when pad is on bot/right (real data is in lower half) ---
        // real_buf_row_start = (pad_bot == 2'd2) ? 4'd8 : 4'd0;
        // real_buf_col_start = (pad_right == 2'd2) ? 4'd8 : 4'd0;

        // --- conv slides per axis ---
        conv_slides_row = active_rows - CONV_K + 1;  // 14 or 20
        conv_slides_col = active_cols - CONV_K + 1;  // 14 or 20
    end

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
                if (start_i || (next_i && !full_load))
                    next_state = LOAD;
                else 
                    next_state = IDLE;
            end

            //===============================================
            // LOAD
            //===============================================
            LOAD: begin
                // Transition when all reads have been issued AND last data received
                // (load_cnt already incremented past the last index when mem_rd_o drops).
                if (load_cnt == load_max_comb && !mem_rd_o)
                    next_state = WAIT_FETCH;
                else 
                    next_state = LOAD;
            end

            //===============================================
            // WAIT_FETCH
            //===============================================
            WAIT_FETCH: begin
                // Hold here (done_load_o stays high) until fetch_en_i pulses.
                if (fetch_en_i)
                    next_state = FETCH;
                else 
                    next_state = WAIT_FETCH;
            end

            //===============================================
            // FETCH
            //===============================================
            FETCH: begin
                if (conv_done_o)
                    next_state = IDLE;
                else
                    next_state = FETCH;
            end

            default: next_state = IDLE;
        endcase
    end


    //=======================================================
    // fsm_sequential
    //=======================================================
    always_ff @(posedge clk or negedge rst_n) begin
        //===================================================
        // Reset
        //===================================================
        if (!rst_n) begin
            buff            <= '0;
            bank_1          <= '0;
            bank_2          <= '0;
            bank_3          <= '0;
            state           <= IDLE;
            win_idx         <= '0;
            sweep_idx       <= '0;
            word_col_offset <= '0;
            // row_origin      <= '0;
            load_cnt        <= '0;
            row_cnt         <= '0;
            row_cnt_d       <= '0;
            col_cnt         <= '0;
            col_cnt_d       <= '0;
            full_load       <= 1'b1;
            write_bank      <= 2'd1;
            fetch_order     <= '{2'd1, 2'd2, 2'd0};
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

                if (pad_top && !(row_cnt > 2)) begin                // padding for top
                    row_cnt <= 2;
                    buff            <= '0;
                end else if (!pad_top && !(row_cnt > 0)) begin
                    row_cnt <= 0;
                end

                if (pad_left && !(col_cnt > 2)) begin                // padding for top
                    col_cnt <= 2;
                    buff            <= '0;
                end else if (!pad_left && !(col_cnt > 0)) begin
                    col_cnt <= 0;
                end

                if (mem_rd_o) begin
                    load_cnt <= load_cnt + 1'b1;
                    if (word_cnt == (full_load ? 3: 1)) begin
                        word_cnt <= '0;
                        row_cnt  <= row_cnt + 1'b1;
                    end else begin
                        word_cnt <= word_cnt + 1'b1;
                    end
                end
            end else begin
                load_data_valid <= 1'b0;
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
                col_cnt         <= '0;
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
                    fetch_order <= '{2'd1, 2'd2, 2'd0};
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
            // FETCH: advance window GROUP position each cycle
            //---------------------------------------------------
            if (state == FETCH && conv_valid_o) begin
                if (conv_col + WIN_GROUP >= conv_slides_col) begin
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

        //===================================================
        // Full load
        //===================================================
        if (full_load) begin
            cur_logical_row  = row_cnt;     // 0..23
            cur_word_in_row  = word_cnt;        // 0..3
            // full load reads all 6 words of the window starting at word_col_offset
            cur_row_word_offset = word_col_offset + 6'(cur_word_in_row);
        //===================================================
        // Partial load
        //===================================================
        end else begin
            cur_logical_row  = row_cnt;     // 0..23
            cur_word_in_row  = word_cnt;        // 0..1
            // partial load reads only the 2 rightmost new words of the window
            // word_col_offset already points to new window; new cols are at +4,+5
            cur_row_word_offset = word_col_offset + 6'd2 + 6'(cur_word_in_row);
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
