`timescale 1ns/1ps
// =============================================================================
// tb_mappingcntrl_ver2.sv
// =============================================================================
// Testbench for the 4-window-parallel mapping_controller (mappingcntrl_ver2.sv)
//
// TESTS
//  Test 1: Single interior window    (sweep=1, win=1)      – mode 00
//  Test 2: Top-border window         (sweep=0, win=1)      – mode 10
//  Test 3: Left-border window        (sweep=1, win=0)      – mode 01
//  Test 4: Top-left corner window    (sweep=0, win=0)      – mode 11
//  Test 5: Bottom-right corner       (sweep=29, win=29)    – mode 11
//  Test 6: Full 30x30 frame pass     (linear image data)   – exhaustive
//
// INTERNAL PROBES (sampled every FETCH cycle, printed)
//  - state_o, conv_row, conv_col (sampled from DUT internals)
//  - valid_mask_o, conv_pixels_o lane 0 pixel [0][0]
//  - pad_top/bot/left/right, real_buf_row/col_start
//  - load phase: load_cnt, mem_addr_o, mem_rd_o, mem_data_i
//  - Bank rotation: fetch_order[0..2], write_bank
//
// PIXEL MODEL
//  Linear: pixel[row][col] = row * IMG_COLS + col   (fits in 18 bits, max=65535)
//  Stored as 72-bit words: {pixel[c], pixel[c+1], pixel[c+2], pixel[c+3]}
// =============================================================================

module tb_mappingcntrl_ver2;

    // =========================================================================
    // Parameters (must match DUT)
    // =========================================================================
    localparam int PIXEL_W   = 18;
    localparam int WORD_W    = 72;
    localparam int IMG_ROWS  = 24;
    localparam int IMG_COLS  = 256;
    localparam int BUF_SIZE  = 24;
    localparam int BANK_COLS = 8;
    localparam int CONV_K    = 5;
    localparam int WIN_GROUP = 4;
    localparam int NUM_H_WIN = 30;
    localparam int NUM_SWEEPS= 30;

    localparam int WORDS_PER_ROW    = IMG_COLS / 4;        // 64
    localparam int OUTMEM_WORDS     = IMG_ROWS * WORDS_PER_ROW; // 1536
    localparam int WINDOW_BITS      = CONV_K * CONV_K * PIXEL_W; // 450
    localparam int SLIDES_FULL      = BUF_SIZE - CONV_K + 1;    // 20
    localparam int SLIDES_BORDER    = 18       - CONV_K + 1;    // 14
    localparam int PAD              = 2;

    // =========================================================================
    // DUT signals
    // =========================================================================
    logic        clk = 0;
    logic        rst_n;
    logic        start_i, next_i, fetch_en_i;
    logic [15:0] mem_addr_o;
    logic        mem_rd_o;
    logic [WORD_W-1:0]                           mem_data_i;
    logic [WIN_GROUP*CONV_K*CONV_K*PIXEL_W-1:0] conv_pixels_o;
    logic [WIN_GROUP-1:0]                        valid_mask_o;
    logic        conv_valid_o, conv_done_o, done_o, frame_done_o;
    logic        done_load_o;
    logic [1:0]  state_o;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    mapping_controller #(
        .PIXEL_W  (PIXEL_W),   .WORD_W  (WORD_W),
        .IMG_ROWS (IMG_ROWS),  .IMG_COLS(IMG_COLS),
        .BUF_SIZE (BUF_SIZE),  .BANK_COLS(BANK_COLS),
        .CONV_K   (CONV_K),    .WIN_GROUP(WIN_GROUP),
        .NUM_H_WIN(NUM_H_WIN), .NUM_SWEEPS(NUM_SWEEPS)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .start_i      (start_i),
        .next_i       (next_i),
        .fetch_en_i   (fetch_en_i),
        .mem_addr_o   (mem_addr_o),
        .mem_rd_o     (mem_rd_o),
        .mem_data_i   (mem_data_i),
        .conv_pixels_o(conv_pixels_o),
        .valid_mask_o (valid_mask_o),
        .conv_valid_o (conv_valid_o),
        .conv_done_o  (conv_done_o),
        .done_o       (done_o),
        .frame_done_o (frame_done_o),
        .done_load_o  (done_load_o),
        .state_o      (state_o)
    );

    always #5 clk = ~clk;

    // =========================================================================
    // Full 256x256 image + per-sweep word memory
    // =========================================================================
    logic [PIXEL_W-1:0] full_image [0:255][0:IMG_COLS-1];
    logic [WORD_W-1:0]  word_mem   [0:OUTMEM_WORDS-1];

    // 1-cycle latency memory model
    logic [WORD_W-1:0] mem_data_r;
    assign mem_data_i = mem_data_r;
    always_ff @(posedge clk)
        mem_data_r <= mem_rd_o ? word_mem[mem_addr_o] : '0;

    // =========================================================================
    // Helper functions
    // =========================================================================
    function automatic int get_pad_top(input int s);
        return (s == 0) ? PAD : 0;
    endfunction
    function automatic int get_pad_bot(input int s);
        return (s == NUM_SWEEPS-1) ? PAD : 0;
    endfunction
    function automatic int get_pad_left(input int k);
        return (k == 0) ? PAD : 0;
    endfunction
    function automatic int get_pad_right(input int k);
        return (k == NUM_H_WIN-1) ? PAD : 0;
    endfunction
    function automatic int get_active_rows(input int s);
        return ((s==0)||(s==NUM_SWEEPS-1)) ? 18 : 24;
    endfunction
    function automatic int get_active_cols(input int k);
        return ((k==0)||(k==NUM_H_WIN-1)) ? 18 : 24;
    endfunction
    function automatic int get_slides_row(input int s);
        return get_active_rows(s) - CONV_K + 1;
    endfunction
    function automatic int get_slides_col(input int k);
        return get_active_cols(k) - CONV_K + 1;
    endfunction
    function automatic int get_rbs_row(input int s);
        return (s == NUM_SWEEPS-1) ? 8 : 0;
    endfunction
    function automatic int get_rbs_col(input int k);
        return (k == NUM_H_WIN-1) ? 8 : 0;
    endfunction

    // =========================================================================
    // Build image (linear: pixel = row*256+col)
    // =========================================================================
    task automatic build_image();
        for (int r = 0; r < 256; r++)
            for (int c = 0; c < IMG_COLS; c++)
                full_image[r][c] = PIXEL_W'(r * IMG_COLS + c);
        $display("[TB] image built: [0][0]=%0d [1][0]=%0d [255][255]=%0d",
                  full_image[0][0], full_image[1][0], full_image[255][255]);
    endtask

    // Rebuild word_mem for a given sweep (mimics what the outer system loads)
    task automatic rebuild_outmem(input int s);
        int ro, logical_row, image_row;
        ro = (s * 8) % IMG_ROWS;
        for (int r = 0; r < IMG_ROWS; r++) begin
            logical_row = (r - ro + IMG_ROWS) % IMG_ROWS;
            image_row   = s * 8 + logical_row;
            for (int w = 0; w < WORDS_PER_ROW; w++) begin
                word_mem[r * WORDS_PER_ROW + w] = {
                    full_image[image_row][w*4+0],
                    full_image[image_row][w*4+1],
                    full_image[image_row][w*4+2],
                    full_image[image_row][w*4+3]
                };
            end
        end
    endtask

    // =========================================================================
    // Reset helper
    // =========================================================================
    task automatic do_reset();
        rst_n     = 0;
        start_i   = 0;
        next_i    = 0;
        fetch_en_i= 0;
        repeat(4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
    endtask

    // =========================================================================
    // Single-cycle pulse helpers
    // =========================================================================
    task automatic pulse_start();
        @(posedge clk); start_i = 1;
        @(posedge clk); start_i = 0;
    endtask
    task automatic pulse_next();
        @(posedge clk); next_i = 1;
        @(posedge clk); next_i = 0;
    endtask
    task automatic pulse_fetch_en();
        @(posedge clk); fetch_en_i = 1;
        @(posedge clk); fetch_en_i = 0;
    endtask

    // =========================================================================
    // Wait for done_load_o then give fetch_en_i
    // =========================================================================
    task automatic wait_load_then_fetch();
        // Wait until WAIT_FETCH state
        wait(done_load_o);
        @(posedge clk);
        // ---- PROBE: print load-phase summary ----
        $display("  [PROBE] WAIT_FETCH entered: state_o=%0d done_load_o=%0d", state_o, done_load_o);
        $display("          DUT internals: fetch_order=[%0d,%0d,%0d] write_bank=%0d",
                  dut.fetch_order[0], dut.fetch_order[1], dut.fetch_order[2], dut.write_bank);
        // Give permission to FETCH
        pulse_fetch_en();
        // Wait until FETCH starts
        wait(conv_valid_o);
    endtask

    // =========================================================================
    // CHECKER: verify one group of WIN_GROUP windows
    // Called on each conv_valid_o cycle during FETCH.
    // s, k = sweep and window index (for expected pixel calculation)
    // cr, cc = conv_row and conv_col (window group top-left within active region)
    // errs = running error count (inout)
    // =========================================================================
    task automatic check_group(
        input  int  s, k, cr, cc,
        input  logic [WIN_GROUP*CONV_K*CONV_K*PIXEL_W-1:0] got,
        input  logic [WIN_GROUP-1:0] vmask,
        inout  int  errs
    );
        int pt, pb, pl, pr, ar, ac, rbs_r, rbs_c;
        int slides_c;
        int err_here;
        logic [PIXEL_W-1:0] got_px, exp_px;
        int slot, img_row, img_col;
        int out_row, out_col;
        int in_pad;
        int lane_col;  // lane g's starting conv_col

        pt    = get_pad_top(s);   pb    = get_pad_bot(s);
        pl    = get_pad_left(k);  pr    = get_pad_right(k);
        ar    = get_active_rows(s); ac = get_active_cols(k);
        rbs_r = get_rbs_row(s);   rbs_c = get_rbs_col(k);
        slides_c = get_slides_col(k);
        err_here = 0;

        for (int g = 0; g < WIN_GROUP; g++) begin
            lane_col = cc + g;
            // Skip lanes beyond conv_slides_col
            if (lane_col >= slides_c) begin
                // Lane must have valid_mask=0 and pixels=0
                if (vmask[g]) begin
                    $display("[FAIL] s=%0d k=%0d cr=%0d cc=%0d lane=%0d: valid_mask=1 but lane_col=%0d >= slides_col=%0d",
                              s, k, cr, cc, g, lane_col, slides_c);
                    err_here++;  errs++;
                end
                for (int r = 0; r < CONV_K; r++)
                    for (int c = 0; c < CONV_K; c++) begin
                        slot   = (CONV_K*CONV_K-1) - (r*CONV_K+c);
                        got_px = got[g*WINDOW_BITS + slot*PIXEL_W +: PIXEL_W];
                        if (got_px !== 0) begin
                            $display("[FAIL] s=%0d k=%0d cr=%0d cc=%0d lane=%0d k[%0d][%0d]: invalid lane got=%0d exp=0",
                                      s, k, cr, cc, g, r, c, got_px);
                            err_here++;  errs++;
                        end
                    end
                continue;
            end

            // Valid lane: check each pixel
            if (!vmask[g]) begin
                $display("[FAIL] s=%0d k=%0d cr=%0d cc=%0d lane=%0d: valid_mask=0 but lane is in range",
                          s, k, cr, cc, g);
                err_here++;  errs++;
            end

            for (int r = 0; r < CONV_K; r++) begin
                for (int c = 0; c < CONV_K; c++) begin
                    out_row = cr + r;
                    out_col = lane_col + c;

                    in_pad = ((out_row <  pt)        ? 1 : 0)
                           | ((out_row >= ar - pb)   ? 1 : 0)
                           | ((out_col <  pl)        ? 1 : 0)
                           | ((out_col >= ac - pr)   ? 1 : 0);

                    slot   = (CONV_K*CONV_K-1) - (r*CONV_K+c);
                    got_px = got[g*WINDOW_BITS + slot*PIXEL_W +: PIXEL_W];

                    if (in_pad) begin
                        exp_px = '0;
                    end else begin
                        img_row = s*8 + rbs_r + out_row - pt;
                        img_col = k*8 + rbs_c + out_col - pl;
                        exp_px  = full_image[img_row][img_col];
                    end

                    if (got_px !== exp_px) begin
                        if (err_here == 0)
                            $display("[FAIL] s=%0d k=%0d cr=%0d cc=%0d lane=%0d t=%0t",
                                      s, k, cr, cc, g, $time);
                        $display("  k[%0d][%0d] out(%0d,%0d) in_pad=%0d: got=%0d exp=%0d",
                                  r, c, out_row, out_col, in_pad, got_px, exp_px);
                        err_here++;  errs++;
                    end
                end
            end
        end

        if (err_here == 0 && cr == 0 && cc == 0)
            $display("[OK]  s=%0d k=%0d cr=0 cc=0 group0 OK  valid_mask=%04b", s, k, vmask);
    endtask

    // =========================================================================
    // Run one horizontal window, collect probe data
    // s, k: sweep/win indices
    // Returns total pixel errors
    // =========================================================================
    task automatic run_window(input int s, input int k, inout int total_errs);
        int cycle_cnt;
        int cr_cap, cc_cap;
        int slides_r, slides_c;

        slides_r = get_slides_row(s);
        slides_c = get_slides_col(k);
        cycle_cnt = 0;

        $display("\n  --- FETCH window s=%0d k=%0d  mode=%0db%0d  slides=%0dx%0d ---",
                  s, k,
                  ((s==0)||(s==NUM_SWEEPS-1)) ? 1 : 0,
                  ((k==0)||(k==NUM_H_WIN-1))  ? 1 : 0,
                  slides_r, slides_c);

        // Internal probe header
        $display("  [PROBE HDR] pt=%0d pb=%0d pl=%0d pr=%0d ar=%0d ac=%0d rbs_r=%0d rbs_c=%0d",
                  get_pad_top(s), get_pad_bot(s), get_pad_left(k), get_pad_right(k),
                  get_active_rows(s), get_active_cols(k),
                  get_rbs_row(s), get_rbs_col(k));
        $display("  [PROBE HDR] fetch_order=[%0d,%0d,%0d] write_bank=%0d row_origin=%0d",
                  dut.fetch_order[0], dut.fetch_order[1], dut.fetch_order[2],
                  dut.write_bank, dut.row_origin);

        while (!conv_done_o) begin
            if (conv_valid_o) begin
                cr_cap = dut.conv_row;
                cc_cap = dut.conv_col;

                // Detailed probe every 10 cycles to keep transcript manageable
                if (cycle_cnt % 10 == 0)
                    $display("  [PROBE cy=%0d] conv_row=%0d conv_col=%0d valid_mask=%04b lane0_px00=%0d",
                              cycle_cnt, cr_cap, cc_cap, valid_mask_o,
                              conv_pixels_o[(CONV_K*CONV_K-1)*PIXEL_W +: PIXEL_W]);

                check_group(s, k, cr_cap, cc_cap, conv_pixels_o, valid_mask_o, total_errs);
                cycle_cnt++;
            end
            @(posedge clk);
        end
        // Capture the last group on conv_done_o cycle
        if (conv_valid_o) begin
            cr_cap = dut.conv_row;
            cc_cap = dut.conv_col;
            check_group(s, k, cr_cap, cc_cap, conv_pixels_o, valid_mask_o, total_errs);
            cycle_cnt++;
        end
        @(posedge clk);

        $display("  FETCH done: %0d cycles (expected ~%0d)", cycle_cnt,
                  slides_r * ((slides_c + WIN_GROUP - 1) / WIN_GROUP));
    endtask

    // =========================================================================
    // Load phase probe: print first/last few load transactions
    // =========================================================================
    task automatic run_load_with_probe(input int is_full, input int s);
        int load_cycles;
        int expected;
        expected = is_full ? (IMG_ROWS * 6) : (IMG_ROWS * 2);
        load_cycles = 0;

        $display("  --- LOAD %s  s=%0d ---", is_full ? "FULL" : "PARTIAL", s);

        while (state_o == 2'b01) begin  // LOAD state = 2'b01
            if (mem_rd_o) begin
                if (load_cycles < 4 || load_cycles >= expected - 2)
                    $display("  [LOAD probe] cy=%0d addr=%0d data(px0)=%0d",
                              load_cycles, mem_addr_o,
                              mem_data_i[WORD_W-1 -: PIXEL_W]);
                load_cycles++;
            end
            @(posedge clk);
        end
        $display("  LOAD ended: state_o=%0d done_load_o=%0d  (%0d reads)", state_o, done_load_o, load_cycles);
    endtask

    // =========================================================================
    // TEST: run a single sweep/win pair from scratch
    // Handles the full start -> load -> wait -> fetch -> idle sequence
    // =========================================================================
    task automatic run_single_window_test(
        input string test_name,
        input int target_s,
        input int target_k
    );
        int errs;
        errs = 0;

        $display("\n========================================");
        $display("TEST: %s  (sweep=%0d win=%0d)", test_name, target_s, target_k);
        $display("========================================");

        // Advance DUT to the target sweep/win pair by running preceding windows fast
        // For simplicity in targeted tests we do a hard reset and drive
        // directly — the checker knows which (s,k) to expect.

        do_reset();
        rebuild_outmem(target_s);

        // Drive sweep_idx and win_idx via the DUT counter mechanism:
        // We just start with sweep=0,win=0 and advance to target using a fast loop.
        // To keep this test self-contained, we fake the DUT's sweep/win by manually
        // forcing only sweep=0/win=0 full-load + the correct wco, then let the
        // checker use (target_s, target_k) for expected pixels. 
        //
        // Simpler approach used here: since word_col_offset and row_origin are
        // the only things that affect pixel values, we rebuild word_mem for target_s
        // and set conv_row/col expectations accordingly. The start_i + next_i
        // advancement is the correct stimulus path anyway.
        //
        // For targeted tests: force the DUT to the right window by pre-advancing.
        // We do N full+partial loads to reach target_s, target_k.

        // -- Advance sweeps --
        for (int s = 0; s < target_s; s++) begin
            rebuild_outmem(s);
            pulse_start();
            run_load_with_probe(1, s);
            wait_load_then_fetch();
            while (!conv_done_o) @(posedge clk);
            @(posedge clk);
            for (int k = 1; k < NUM_H_WIN; k++) begin
                pulse_next();
                run_load_with_probe(0, s);
                wait_load_then_fetch();
                while (!conv_done_o) @(posedge clk);
                @(posedge clk);
            end
        end

        // -- Load and run the target sweep --
        rebuild_outmem(target_s);
        for (int k = 0; k <= target_k; k++) begin
            if (k == 0) pulse_start(); else pulse_next();
            run_load_with_probe((k==0), target_s);
            wait_load_then_fetch();
            if (k == target_k)
                run_window(target_s, target_k, errs);
            else begin
                while (!conv_done_o) @(posedge clk);
                @(posedge clk);
            end
        end

        $display("TEST %s: errors=%0d -> %s", test_name, errs, (errs==0) ? "PASS" : "FAIL");
    endtask

    // =========================================================================
    // TEST 6: Full exhaustive 30x30 frame pass
    // =========================================================================
    task automatic run_full_frame(inout int frame_errs);
        int win_errs;

        $display("\n========================================");
        $display("TEST 6: Full 30x30 frame exhaustive pass");
        $display("========================================");

        do_reset();
        frame_errs = 0;

        for (int s = 0; s < NUM_SWEEPS; s++) begin
            rebuild_outmem(s);
            $display("\n=== SWEEP %0d ===", s);

            for (int k = 0; k < NUM_H_WIN; k++) begin
                win_errs = 0;

                // Trigger load
                if (k == 0) pulse_start(); else pulse_next();

                // Wait for LOAD to complete
                wait(state_o == 2'b11);  // WAIT_FETCH
                @(posedge clk);
                pulse_fetch_en();
                wait(conv_valid_o);

                // Run FETCH and check
                run_window(s, k, win_errs);
                frame_errs += win_errs;

                if (win_errs == 0 && k % 5 == 0)
                    $display("[PASS] sweep=%0d win=%0d: 0 errors", s, k);
                else if (win_errs > 0)
                    $display("[FAIL] sweep=%0d win=%0d: %0d errors", s, k, win_errs);
            end
        end

        $display("\nTEST 6 RESULT: frame_errors=%0d -> %s",
                  frame_errs, (frame_errs==0) ? "PASS" : "FAIL");
    endtask

    // =========================================================================
    // Scoreboard background checkers
    // =========================================================================
    // GAP: conv_valid_o must only be high in FETCH state
    int gap_conv_valid_errors = 0;
    always_ff @(posedge clk) begin
        if (rst_n && conv_valid_o && state_o !== 2'b10) begin
            $display("[GAP FAIL] conv_valid_o=1 outside FETCH at t=%0t", $time);
            gap_conv_valid_errors++;
        end
    end

    // GAP: mem_rd_o must only be high in LOAD state
    int gap_mem_rd_errors = 0;
    always_ff @(posedge clk) begin
        if (rst_n && mem_rd_o && state_o !== 2'b01) begin
            $display("[GAP FAIL] mem_rd_o=1 outside LOAD at t=%0t", $time);
            gap_mem_rd_errors++;
        end
    end

    // GAP: done_load_o must only be high in WAIT_FETCH
    int gap_done_load_errors = 0;
    always_ff @(posedge clk) begin
        if (rst_n && done_load_o && state_o !== 2'b11) begin
            $display("[GAP FAIL] done_load_o=1 outside WAIT_FETCH at t=%0t", $time);
            gap_done_load_errors++;
        end
    end

    // =========================================================================
    // Main stimulus
    // =========================================================================
    int frame_errs;

    initial begin
        frame_errs = 0;

        build_image();

        // ------------------------------------------------------------------
        // Test 1 – Interior window (sweep=1, win=1)
        // ------------------------------------------------------------------
        // For speed in single-window tests we jump straight to target
        // by running preceding windows without checking (fast-forward).
        // The checker still verifies the target window fully.
        run_single_window_test("T1_interior   (s=1,k=1)",   1,  1);

        // ------------------------------------------------------------------
        // Test 2 – Top border (sweep=0, win=1)
        // ------------------------------------------------------------------
        run_single_window_test("T2_top_border (s=0,k=1)",   0,  1);

        // ------------------------------------------------------------------
        // Test 3 – Left border (sweep=1, win=0)
        // ------------------------------------------------------------------
        run_single_window_test("T3_left_border(s=1,k=0)",   1,  0);

        // ------------------------------------------------------------------
        // Test 4 – Top-left corner (sweep=0, win=0)
        // ------------------------------------------------------------------
        run_single_window_test("T4_TL_corner  (s=0,k=0)",   0,  0);

        // ------------------------------------------------------------------
        // Test 5 – Bottom-right corner (sweep=29, win=29)
        // ------------------------------------------------------------------
        run_single_window_test("T5_BR_corner  (s=29,k=29)", 29, 29);

        // ------------------------------------------------------------------
        // Test 6 – Full exhaustive frame
        // ------------------------------------------------------------------
        run_full_frame(frame_errs);

        // ------------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------------
        $display("\n========================================");
        $display("BACKGROUND CHECKER SUMMARY");
        $display("  GAP conv_valid outside FETCH : %0d errors", gap_conv_valid_errors);
        $display("  GAP mem_rd outside LOAD      : %0d errors", gap_mem_rd_errors);
        $display("  GAP done_load outside WFETCH : %0d errors", gap_done_load_errors);
        $display("  Full frame pixel errors      : %0d", frame_errs);
        $display("========================================");
        $display("ALL TESTS COMPLETE");

        #100;
        $finish;
    end
endmodule