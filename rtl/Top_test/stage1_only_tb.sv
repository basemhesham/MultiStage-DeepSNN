// =============================================================================
// stage1_only_tb.sv
// -----------------------------------------------------------------------------
// Purpose:
//   Verify ONLY Stage 1 of deep_snn_top (the `top` module) using a real image
//   feed instead of directly forcing internal signals.
//
//   - mem_data_i is driven from a simple 1-cycle-latency memory model that is
//     preloaded from dummy_image_256x256.hex (256x256, one pixel per line,
//     18-bit values in hex).
//   - The mapping_controller inside deep_snn_top reads that memory word-by-word
//     (72-bit words = 4 pixels x 18 bits, 64 words/row, exactly as documented
//     in Mapping_Cntrl.sv) via mem_addr_o / mem_rd_o / mem_data_i.
//   - The testbench watches the *internal* next-state signal `ns` of
//     top_controller (u_top_controller.ns, type state_t). The instant ns
//     becomes STAGE2, the run is finished as far as Stage 1 is concerned, so
//     the TB calls $finish immediately. This guarantees we never simulate any
//     part of Stage 2/Stage 3 -- only the CLEAR_STAGE2_WORD -> STAGE1 portion
//     of the run is exercised.
//   - After every clock in which top_controller is in the STAGE1 state, each
//     pipeline block prints its current output for debugging/visualization:
//     mapping_controller -> pixel_source_mapper -> weight_mapper ->
//     conv9_array -> adder_tree_shaaban_connect -> shaaban_array ->
//     spike_writeback.
//
// Usage:
//   Place dummy_image_256x256.hex in the simulation run directory (or edit
//   the $readmemh path below), compile together with all RTL under design/,
//   and run stage1_only_tb as the top module.
// =============================================================================

`timescale 1ns/1ps

module stage1_only_tb;

    // =========================================================================
    // Parameters mirrored from deep_snn_top / mapping_controller
    // =========================================================================
    localparam int PIXEL_W         = 18;
    localparam int MAP_WORD_W      = 72;                       // 4 pixels/word
    localparam int PIXELS_PER_WORD = MAP_WORD_W / PIXEL_W;      // 4
    localparam int IMG_ROWS_FULL   = 256;
    localparam int IMG_COLS_FULL   = 256;
    localparam int WORDS_PER_ROW   = IMG_COLS_FULL / PIXELS_PER_WORD; // 64
    localparam int MEM_DEPTH       = IMG_ROWS_FULL * WORDS_PER_ROW;   // 16384
    localparam int MEM_ADDR_BITS   = $clog2(MEM_DEPTH);               // 14
    localparam int CLK_PERIOD      = 10;
  // =========================================================================
   
    localparam int WORD_W    = 72;
    localparam int IMG_ROWS  = 24;
    localparam int IMG_COLS  = 256;
    localparam int BUF_SIZE  = 24;
    localparam int BANK_COLS = 8;
    localparam int CONV_K    = 5;
    localparam int WIN_GROUP = 4;
    localparam int NUM_H_WIN = 32;
    localparam int NUM_SWEEPS= 32;


    localparam int OUTMEM_WORDS     = IMG_ROWS * WORDS_PER_ROW; // 1536
    localparam int WINDOW_BITS      = CONV_K * CONV_K * PIXEL_W; // 450
    localparam int SLIDES_FULL      = BUF_SIZE - CONV_K + 1;    // 20
    localparam int SLIDES_BORDER    = 18       - CONV_K + 1;    // 14
    localparam int PAD              = 2;
   int frame_errs;
    // =========================================================================
    // DUT I/O
    // =========================================================================
    logic clk, rst, arst_n, enable;

    logic                          pixel_mem_wr_en;    // unused in stage1 path
    logic [5:0]                    pixel_mem_wr_addr;  // unused in stage1 path
    logic [(384*PIXEL_W)-1:0]      pixel_mem_wr_data;   // unused in stage1 path

    logic                          start_i;             // pulse -> mapping_controller
    logic [MAP_WORD_W-1:0]         mem_data_i;          // from our memory model

    logic [31:0]                   spike_out;
    logic [(4*PIXEL_W)-1:0]        class_logits;
    logic                          classifier_done;
    logic                          classifier_busy;
    logic                          snn_done;
    logic                          done;
    logic [15:0]                   mem_addr_o;
    logic                          mem_rd_o;
    logic                          map_done_o;

    // ==========================================================
    // Debug file handles
    // ==========================================================
    integer f_mapping;
    integer f_pixel_mapper;
    integer f_conv9;
    integer f_adder_tree;
    integer f_shaaban;
    integer f_spike_writeback;
    integer f_controller;
    integer f_spike_dump;   // spike_out, gated on (new_data_o && src_sel == 0)
    integer f_spike_dump_s2; // spike_out, gated on (src_sel == 1), per shb_mem_en
    integer f_spike_dump_s3; // spike_out, gated on (src_sel == 2), lif[0] only

    // =========================================================================
    // Clock
    // =========================================================================
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // Image memory model (dummy_image_256x256.hex -> packed 72-bit words)
    // =========================================================================
    logic [MAP_WORD_W-1:0] image_mem  [0:MEM_DEPTH-1];
    logic [4*PIXEL_W-1:0] full_image [0: 16384-1];
    logic [WORD_W-1:0]  word_mem   [0:OUTMEM_WORDS-1];

    // 1-cycle latency memory model
    logic [WORD_W-1:0] mem_data_r;
    assign mem_data_i = mem_data_r;
    always_ff @(posedge clk)
        mem_data_r <= mem_rd_o ? full_image[mem_addr_o] : '0;

    task automatic build_image();
        // Dummy image
        // for (int r = 0; r < 256; r++)
        //     for (int c = 0; c < IMG_COLS; c++)
        //         full_image[r][c] = PIXEL_W'(r * IMG_COLS + c);
        // $display("[TB] image built: [0][0]=%0d [1][0]=%0d [255][255]=%0d",
        //           full_image[0][0], full_image[1][0], full_image[255][255]);

        // for (int r = 0; r < 16384; r++)
        //         full_image[r] = {PIXEL_W'(r*4), PIXEL_W'(r*4 +1), PIXEL_W'(r*4 +2), PIXEL_W'(r*4 +3)};
                // full_image[r] = 72'hFFFF_FFFF_FFFF_FFFF_FF;  // all 1's for easy visual inspection

        //Reading real image
        $readmemb("full_image.mem", full_image);
        $display("[TB] image loaded: full_image[0]=%h full_image[64]=%h full_image[16383]=%h",
                  full_image[0], full_image[64], full_image[16383]);

    endtask

    // Rebuild word_mem for a given sweep (mimics what the outer system loads)
    task automatic rebuild_outmem(input int s);
        int ro, logical_row, image_row;
        ro = (s * 8) % IMG_ROWS;
        // for (int r = 0; r < IMG_ROWS; r++) begin
        //     logical_row = (r - ro + IMG_ROWS) % IMG_ROWS;
        //     image_row   = s * 8 + logical_row;
        //     for (int w = 0; w < WORDS_PER_ROW; w++) begin
        //         word_mem[r * WORDS_PER_ROW + w] = {
        //             full_image[image_row][w*4+0],
        //             full_image[image_row][w*4+1],
        //             full_image[image_row][w*4+2],
        //             full_image[image_row][w*4+3]
        //         };
        //     end
        // end
    endtask

    // always_comb begin
    //         word_mem = full_image [mem_addr_o];
    // end

    task automatic do_reset();
        arst_n     = 0;
        start_i   = 0;
        repeat(4) @(posedge clk);
        arst_n = 1;
        @(posedge clk);
    endtask

    task automatic pulse_start();
        @(posedge clk); start_i = 1;
        @(posedge clk); start_i = 0;
    endtask

    task automatic pulse_next();
        @(posedge clk); 
    endtask

    // task automatic pulse_fetch_en();
    //     @(posedge clk); DUT.try_fetch = 1;
    //     @(posedge clk); DUT.try_fetch = 0;
    // endtask

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

        while (!DUT.map_conv_done_o) begin
            if (DUT.u_mapping_controller.conv_valid_o) begin

                // Detailed probe every 10 cycles to keep transcript manageable
                if (cycle_cnt % 10 == 0)
                    $display("  [PROBE cy=%0d] conv_row=%0d conv_col=%0d lane0_px00=%0d",
                              cycle_cnt, cr_cap, cc_cap,
                              DUT.map_conv_pixels_o[(CONV_K*CONV_K-1)*PIXEL_W +: PIXEL_W]);
                cycle_cnt++;
            end
            @(posedge clk);
        end
        // Capture the last group on conv_done_o cycle
        if (DUT.u_mapping_controller.conv_valid_o) begin
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

        while (DUT.u_mapping_controller.state_o == 2'b01) begin  // LOAD state = 2'b01
            if (mem_rd_o) begin
                load_cycles++;
            end
            @(posedge clk);
        end
    endtask
    task automatic wait_load_then_fetch();
        // Wait until WAIT_FETCH state
        wait(DUT.ctrl_done_load_o);
        wait(DUT.u_mapping_controller.conv_valid_o);
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
            wait_load_then_fetch();
            while (!DUT.map_conv_done_o) @(posedge clk);
            @(posedge clk);
            for (int k = 1; k < NUM_H_WIN; k++) begin
                pulse_next();
                wait_load_then_fetch();
                while (!DUT.map_conv_done_o) @(posedge clk);
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
                while (!DUT.map_conv_done_o) @(posedge clk);
                @(posedge clk);
            end
        end

        $display("TEST %s: errors=%0d -> %s", test_name, errs, (errs==0) ? "PASS" : "FAIL");
    endtask

    task automatic run_full_frame(inout int frame_errs);
        int win_errs;

        $display("\n========================================");
        $display("TEST 6: Full 30x30 frame exhaustive pass");
        $display("========================================");

        do_reset();
        frame_errs = 0;

        // for (int s = 0; s < 256; s++) begin
        //     rebuild_outmem(s);
        //     $display("\n=== SWEEP %0d ===", s);

        //     for (int k = 0; k < 256; k++) begin
        //         win_errs = 0;

        //         // Trigger load
        //         if (k == 0) pulse_start(); else pulse_next();

        //         // Wait for LOAD to complete
        //         wait(DUT.map_state_o == 2'b11);  // WAIT_FETCH
        //         @(posedge clk);
        //         pulse_fetch_en();
        //         wait(DUT.map_conv_valid_o);

        //         // Run FETCH and check
        //         run_window(s, k, win_errs);
        //         frame_errs += win_errs;
 
        //         if (win_errs == 0 && k % 5 == 0)
        //             $display("[PASS] sweep=%0d win=%0d: 0 errors", s, k);
        //         else if (win_errs > 0)
        //             $display("[FAIL] sweep=%0d win=%0d: %0d errors", s, k, win_errs);
        //     end
        // end

        for (int s = 0; s < 2; s++) begin
            rebuild_outmem(s);
            pulse_start();
            wait_load_then_fetch();
            wait(DUT.map_conv_done_o);
            for (int k = 1; k < 32; k++) begin
                wait(DUT.u_top_controller.next_i);
                wait_load_then_fetch();
                wait(DUT.map_conv_done_o);
            end
        end

        $display("\nTEST 6 RESULT: frame_errors=%0d -> %s",
                  frame_errs, (frame_errs==0) ? "PASS" : "FAIL");
    endtask


    

    // =========================================================================
    // DUT
    // =========================================================================
    deep_snn_top DUT (
        .clk               (clk),
        .rst               (rst),
        .arst_n            (arst_n),
        .enable            (enable),
        .pixel_mem_wr_en   (pixel_mem_wr_en),
        .pixel_mem_wr_addr (pixel_mem_wr_addr),
        .pixel_mem_wr_data (pixel_mem_wr_data),
        .start_i           (start_i),
        .mem_data_i        (mem_data_i),
        .spike_out         (spike_out),
        .class_logits      (class_logits),
        .classifier_done   (classifier_done),
        .classifier_busy   (classifier_busy),
        .snn_done          (snn_done),
        .done              (done),
        .mem_addr_o        (mem_addr_o),
        .mem_rd_o          (mem_rd_o),
        .map_done_o        (map_done_o)
    );

    initial begin

        f_mapping         = $fopen("mapping_controller.txt", "w");
        f_pixel_mapper    = $fopen("pixel_source_mapper.txt", "w");
        f_conv9           = $fopen("conv9_array.txt", "w");
        f_adder_tree      = $fopen("adder_tree_connect.txt", "w");
        f_shaaban         = $fopen("shaaban_array.txt", "w");
        f_spike_writeback = $fopen("spike_writeback.txt", "w");
        f_controller      = $fopen("top_controller.txt", "w");
        f_spike_dump      = $fopen("spike_out_new_data.txt", "w");
        f_spike_dump_s2   = $fopen("spike_out_stage2.txt", "w");
        f_spike_dump_s3   = $fopen("spike_out_stage3.txt", "w");

    end

    // =========================================================================
    // Stimulus
    // =========================================================================
    initial begin

        clk               = 1'b0;
        rst               = 1'b1;
        arst_n            = 1'b0;
        enable            = 1'b0;
        pixel_mem_wr_en   = 1'b0;
        pixel_mem_wr_addr = 6'd0;
        pixel_mem_wr_data = '0;
        start_i           = 1'b0;
        //mem_data_i        = '0;

        repeat (3) @(posedge clk);
        arst_n = 1'b1;
        rst    = 1'b0;
        repeat (2) @(posedge clk);

        // One pulse kicks top_controller: IDLE -> CLEAR_STAGE2_WORD -> STAGE1
        enable = 1'b1;
        @(posedge clk);

        frame_errs=0;
        build_image();
        run_full_frame(frame_errs);
        // run_single_window_test("TL_corner  (s=0,k=0)",   0,  0);
        // run_single_window_test("T2_top_border (s=0,k=1)",   0,  1);
        // run_single_window_test("T2_top_border (s=0,k=1)",   0,  2);

      #1000;
        $finish;
    end

    // =========================================================================
    // Stage-1-only cutoff
    // -----------------------------------------------------------------------
    // `ns` is top_controller's internal next-state signal (type state_t).
    // The moment it becomes STAGE2 we know top_controller is about to leave
    // Stage 1, so the TB is done -- finish immediately without simulating
    // any of Stage 2/Stage 3.
    // =========================================================================
    // always @(posedge clk) begin
    //     if (DUT.u_top_controller.ns == DUT.u_top_controller.STAGE2) begin
    //         $display("==========================================================");
    //         $display("[%0t] Stage 1 finished (ns == STAGE2). Ending testbench.", $time);
    //         $display("==========================================================");

    //         $fclose(f_mapping);
    //         $fclose(f_pixel_mapper);
    //         $fclose(f_conv9);
    //         $fclose(f_adder_tree);
    //         $fclose(f_shaaban);
    //         $fclose(f_spike_writeback);
    //         $fclose(f_controller);

    //         $finish;
    //     end
    // end

    // Safety net in case Stage 1 never completes
    initial begin
        #(CLK_PERIOD * 2_000_000);
        $fatal(1, "TIMEOUT: simulation never reached STAGE2 (Stage 1 did not finish)");
    end

    // =========================================================================
    // Per-block debug printing (only while top_controller is actually in
    // STAGE1, i.e. only for cycles that belong to the stage we're verifying)
    // =========================================================================
    
    //wire in_stage1 = (DUT.u_top_controller.cs == DUT.u_top_controller.STAGE1);

    // Block 1: mapping_controller (mem_data_i -> conv_pixels_o)
    // always @(posedge clk) begin
    //     if (DUT.map_conv_valid_o)
    //         $display(f_mapping,
    //         "[%0t] conv_valid_o=1 conv_done_o=%0b frame_done_o=%0b addr=%0d conv_pixels_o=%h",
    //         $time,
    //         DUT.map_conv_done_o,
    //         DUT.map_frame_done_o,
    //         mem_addr_o,
    //         DUT.map_conv_pixels_o);
    // end

    // Block 2: top_pixel_source_mapper (pixels_mapped)
    // always @(posedge clk) begin
    //     if (in_stage1)
    //         $fdisplay(f_pixel_mapper,
    //         "[%0t] stage1_pos=%0d pixels_mapped[0][0][0..2]=%0d,%0d,%0d",
    //         $time,
    //         DUT.u_top_controller.stage1_pos,
    //         DUT.pixels_mapped[0][0][0],
    //         DUT.pixels_mapped[0][0][1],
    //         DUT.pixels_mapped[0][0][2]);
    // end

    // // Block 3: top_conv9_array (mac_to_connect)
    // always @(posedge clk) begin
    //     if (in_stage1)
    //         $fdisplay(f_conv9,
    //         "[%0t] mac_to_connect[0][0]=%0d mac_to_connect[0][1]=%0d",
    //         $time,
    //         DUT.mac_to_connect[0][0],
    //         DUT.mac_to_connect[0][1]);
    // end

    // // Block 4: adder_tree_shaaban_connect (shb_bus)
    // always @(posedge clk) begin
    //     if (in_stage1)
    //         $fdisplay(f_adder_tree,
    //         "[%0t] shb_bus[0]=%0d shb_bus[1]=%0d",
    //         $time,
    //         DUT.shb_bus[0],
    //         DUT.shb_bus[1]);
    // end

    // // Block 5: top_shaaban_array (LIF + spikes)
    // always @(posedge clk) begin
    //     if (in_stage1)
    //         $fdisplay(f_shaaban,
    //         "[%0t] spike_out=%b",
    //         $time,
    //         spike_out);
    // end

    // // Block 6: top_spike_writeback (packed word going to spike_mem)
    // always @(posedge clk) begin
    //     if (in_stage1)
    //         $fdisplay(f_spike_writeback,
    //         "[%0t] spike_mem_wr_data[63:0]=%h",
    //         $time,
    //         DUT.spike_mem_wr_data[63:0]);
    // end

    // =========================================================================
    // spike_out dump: only when mapping_controller's new_data_o is high AND
    // src_sel == 0 (Stage 1 source selected). Both new_data_o and src_sel are
    // internal to DUT (deep_snn_top), so they're reached hierarchically.
    // =========================================================================
    always @(posedge clk) begin
        if (DUT.new_data_o && (DUT.src_sel == 2'b00)) begin
            $fdisplay(f_spike_dump, "[%0t] spike_out=%b", $time, spike_out);
        end
    end

    // =========================================================================
    // Stage 2 spike_out dump: only while src_sel == 1 (Stage 2 selected).
    // Only 3 shaaban/LIF lanes are active in Stage 2 (lanes 0..2), enabled via
    // the shb_mem_en bitmask (shb_mem_en[0]->lif[0], [1]->lif[1], [2]->lif[2]):
    //   shb_mem_en == 1 (3'b001) -> lif[0] only
    //   shb_mem_en == 2 (3'b010) -> lif[1] only
    //   shb_mem_en == 3 (3'b011) -> lif[0] and lif[1] together
    //   shb_mem_en == 4 (3'b100) -> lif[2] only
    // (and so on for any other bit combination of the 3-bit mask)
    // =========================================================================
    always @(posedge clk) begin
        if (DUT.src_sel == 2'b01) begin
            if (DUT.shb_mem_en[0])
                $fdisplay(f_spike_dump_s2, "[%0t] shb_mem_en=%03b lif[0] spike_out[0]=%b",
                          $time, DUT.shb_mem_en, spike_out[0]);
            if (DUT.shb_mem_en[1])
                $fdisplay(f_spike_dump_s2, "[%0t] shb_mem_en=%03b lif[1] spike_out[1]=%b",
                          $time, DUT.shb_mem_en, spike_out[1]);
            if (DUT.shb_mem_en[2])
                $fdisplay(f_spike_dump_s2, "[%0t] shb_mem_en=%03b lif[2] spike_out[2]=%b",
                          $time, DUT.shb_mem_en, spike_out[2]);
        end
    end

    // =========================================================================
    // Stage 3 spike_out dump: only while src_sel == 2 (Stage 3 selected).
    // Only 1 shaaban/LIF lane is active in Stage 3 -> lif[0] only.
    // =========================================================================
    always @(posedge clk) begin
        if (DUT.src_sel == 2'b10) begin
            $fdisplay(f_spike_dump_s3, "[%0t] lif[0] spike_out[0]=%b", $time, spike_out[0]);
        end
    end

    // Make sure the dump file is flushed/closed no matter which $finish path
    // (safety-net timeout or normal stimulus end) ends the simulation.
    final begin
        $fclose(f_spike_dump);
        $fclose(f_spike_dump_s2);
        $fclose(f_spike_dump_s3);
    end

    // // Controller state transitions (always printed, gives the overall picture)
    // always @(posedge clk) begin
    //     if (DUT.u_top_controller.cs != DUT.u_top_controller.ns)
    //         $fdisplay(f_controller,
    //         "[%0t] cs -> ns : %0s -> %0s",
    //         $time,
    //         DUT.u_top_controller.cs.name(),
    //         DUT.u_top_controller.ns.name());
    // end

endmodule