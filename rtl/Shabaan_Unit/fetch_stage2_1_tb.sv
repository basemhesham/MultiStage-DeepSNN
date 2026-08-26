`timescale 1ns/1ps

// =====================================================================================
// fetch_stage2_1_tb.sv
// -------------------------------------------------------------------------------------
// Verifies:
//   1) BRAM region: local_pos/bank_adv wrap exactly like the other fetch modules
//      (fetch.sv / fetch_stage2_0 / fetch_stage2_2 / fetch_stage3), and the start
//      bank decrements by 1 each frame (spare-bank rotation), wrapping mod
//      BRAM_TOTAL_BANKS.
//   2) Regfile region: reg_rd_en and reg_wr_en BOTH fire for every regfile
//      position each frame (after frame 1) - i.e. reading the regfile also
//      writes it back, on the SAME single (non-rotating) array - while
//      mem_rd_en/mem_wr_en stay low for those positions.
//   3) Frame 1 has NO reads anywhere (mem_rd_en and reg_rd_en both 0 for the
//      whole frame), but writes still happen everywhere (populating history
//      for frame 2).
//
// Uses deliberately small override parameters (not the real 61/128/2048
// values) so a handful of frames run in a few dozen cycles while exercising
// the exact same address-generation logic paths.
// =====================================================================================

module fetch_stage2_1_tb;

    // =========================================================================
    // Small override parameters for a fast, exhaustive-ish test
    // =========================================================================
    localparam int BANK_DEPTH        = 4;   // small BRAM depth (vs 2048 real)
    localparam int BRAM_ACTIVE_BANKS = 3;   // small active-bank count (vs 61 real)
    localparam int BRAM_TOTAL_BANKS  = 4;   // ACTIVE + 1 spare (vs 62 real)
    localparam int REG_DEPTH         = 2;   // small regfile depth (vs 128 real)
    localparam int MEM_ADDR_WIDTH    = $clog2(BRAM_TOTAL_BANKS*BANK_DEPTH); // 4
    localparam int REG_ADDR_WIDTH    = (REG_DEPTH > 1) ? $clog2(REG_DEPTH) : 1; // 1

    localparam int BRAM_REGION_SIZE  = BRAM_ACTIVE_BANKS * BANK_DEPTH; // 12
    localparam int POS_PER_FRAME     = BRAM_REGION_SIZE + REG_DEPTH;   // 14

    // =========================================================================
    // DUT I/O
    // =========================================================================
    logic clk, arst_n;
    logic first_frame, frame_start, in_valid;

    logic                        mem_rd_en, mem_wr_en;
    logic [MEM_ADDR_WIDTH-1:0]   mem_rd_addr, mem_wr_addr;
    logic                        reg_rd_en, reg_wr_en;
    logic [REG_ADDR_WIDTH-1:0]   reg_rd_addr, reg_wr_addr;
    logic                        out_valid;
    logic [MEM_ADDR_WIDTH-1:0]   addr_out;

    fetch_stage2_1 #(
        .BANK_DEPTH        (BANK_DEPTH),
        .BRAM_ACTIVE_BANKS (BRAM_ACTIVE_BANKS),
        .BRAM_TOTAL_BANKS  (BRAM_TOTAL_BANKS),
        .REG_DEPTH         (REG_DEPTH),
        .MEM_ADDR_WIDTH    (MEM_ADDR_WIDTH),
        .REG_ADDR_WIDTH    (REG_ADDR_WIDTH)
    ) dut (
        .clk         (clk),
        .arst_n      (arst_n),
        .first_frame (first_frame),
        .frame_start (frame_start),
        .in_valid    (in_valid),
        .mem_rd_en   (mem_rd_en),
        .mem_rd_addr (mem_rd_addr),
        .mem_wr_en   (mem_wr_en),
        .mem_wr_addr (mem_wr_addr),
        .reg_rd_en   (reg_rd_en),
        .reg_rd_addr (reg_rd_addr),
        .reg_wr_en   (reg_wr_en),
        .reg_wr_addr (reg_wr_addr),
        .out_valid   (out_valid),
        .addr_out    (addr_out)
    );

    // =========================================================================
    // Clock
    // =========================================================================
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // =========================================================================
    // Reference model: mirrors the DUT's bank rotation using plain
    // division/mod (fine for a checker, unlike the synthesizable DUT).
    // =========================================================================
    int cur_bank_ref, prev_bank_ref;   // DUT's cur_bank/prev_bank
    int pos_cnt_ref;                    // flat position within the current frame (0..POS_PER_FRAME-1)
    bit first_frame_ref;

    task automatic ref_reset();
        cur_bank_ref   = 0;
        prev_bank_ref  = 0;
        pos_cnt_ref    = 0;
        first_frame_ref = 1;
    endtask

    task automatic ref_frame_start();
        // Mirrors: prev_bank<=cur_bank; cur_bank<=(cur_bank==0)?TOTAL-1:cur_bank-1
        prev_bank_ref = cur_bank_ref;
        cur_bank_ref  = (cur_bank_ref == 0) ? (BRAM_TOTAL_BANKS-1) : (cur_bank_ref-1);
        pos_cnt_ref   = 0;
        first_frame_ref = 0;
    endtask

    // Expected read-side signals for the position about to be presented
    // this cycle (pos_cnt_ref, BEFORE advancing).
    function automatic void expected_read(
        output bit                      exp_mem_rd_en,
        output int                      exp_mem_rd_addr,
        output bit                      exp_reg_rd_en,
        output int                      exp_reg_rd_addr
    );
        int bank_adv, local_pos, phys_bank;
        begin
            exp_mem_rd_en = 0; exp_mem_rd_addr = 0;
            exp_reg_rd_en = 0; exp_reg_rd_addr = 0;
            if (pos_cnt_ref < BRAM_REGION_SIZE) begin
                bank_adv  = pos_cnt_ref / BANK_DEPTH;
                local_pos = pos_cnt_ref % BANK_DEPTH;
                phys_bank = (prev_bank_ref + bank_adv) % BRAM_TOTAL_BANKS;
                exp_mem_rd_en   = ~first_frame_ref;
                exp_mem_rd_addr = phys_bank*BANK_DEPTH + local_pos;
            end else begin
                exp_reg_rd_en   = ~first_frame_ref;
                exp_reg_rd_addr = pos_cnt_ref - BRAM_REGION_SIZE;
            end
        end
    endfunction

    // Expected write-side signals for a given (already-elapsed) position.
    function automatic void expected_write(
        input  int pos,
        output bit exp_mem_wr_en,
        output int exp_mem_wr_addr,
        output bit exp_reg_wr_en,
        output int exp_reg_wr_addr
    );
        int bank_adv, local_pos, phys_bank;
        begin
            exp_mem_wr_en = 0; exp_mem_wr_addr = 0;
            exp_reg_wr_en = 0; exp_reg_wr_addr = 0;
            if (pos < BRAM_REGION_SIZE) begin
                bank_adv  = pos / BANK_DEPTH;
                local_pos = pos % BANK_DEPTH;
                phys_bank = (cur_bank_ref + bank_adv) % BRAM_TOTAL_BANKS;
                exp_mem_wr_en   = 1;
                exp_mem_wr_addr = phys_bank*BANK_DEPTH + local_pos;
            end else begin
                exp_reg_wr_en   = 1;
                exp_reg_wr_addr = pos - BRAM_REGION_SIZE;
            end
        end
    endfunction

    // =========================================================================
    // Scoreboard
    // =========================================================================
    int pass_count = 0;
    int fail_count = 0;
    int last_read_pos_q[$];   // queue of positions whose read was just checked,
                               // so the write check one cycle later knows which
                               // position to expect

    task automatic check(input string label, input bit got, input bit exp, input int got_addr, input int exp_addr, input bit check_addr);
        if (got !== exp || (check_addr && exp && (got_addr !== exp_addr))) begin
            $display("[FAIL] %-28s en(exp=%0b got=%0b) addr(exp=%0d got=%0d)",
                      label, exp, got, exp_addr, got_addr);
            fail_count++;
        end else begin
            $display("[PASS] %-28s en=%0b addr=%0d", label, got, got_addr);
            pass_count++;
        end
    endtask

    // =========================================================================
    // Stimulus tasks
    // =========================================================================
    task automatic do_reset();
        first_frame = 1'b1;
        frame_start = 1'b0;
        in_valid    = 1'b0;
        arst_n = 1'b0;
        repeat(3) @(negedge clk);
        arst_n = 1'b1;
        repeat(2) @(negedge clk);
        ref_reset();
    endtask

    task automatic pulse_frame_start();
        frame_start = 1'b1;
        first_frame = 1'b0;
        @(negedge clk);
        frame_start = 1'b0;
        ref_frame_start();
    endtask

    // Drives one in_valid pulse, checks the read side THIS cycle, records the
    // position for a write-side check one cycle later.
    task automatic send_and_check_read();
        bit exp_mem_rd_en, exp_reg_rd_en;
        int exp_mem_rd_addr, exp_reg_rd_addr;
        int this_pos;

        expected_read(exp_mem_rd_en, exp_mem_rd_addr, exp_reg_rd_en, exp_reg_rd_addr);
        this_pos = pos_cnt_ref;

        in_valid = 1'b1;
        @(negedge clk); // settle combinational outputs after the posedge

        check($sformatf("pos=%0d mem_rd", this_pos), mem_rd_en, exp_mem_rd_en, mem_rd_addr, exp_mem_rd_addr, 1);
        check($sformatf("pos=%0d reg_rd", this_pos), reg_rd_en, exp_reg_rd_en, reg_rd_addr, exp_reg_rd_addr, 1);

        in_valid = 1'b0;
        last_read_pos_q.push_back(this_pos);
        pos_cnt_ref = pos_cnt_ref + 1;

        // Any write check due this cycle (from the pixel sent last cycle)?
        if (last_read_pos_q.size() > 1) begin
            check_pending_write();
        end
    endtask

    task automatic check_pending_write();
        bit exp_mem_wr_en, exp_reg_wr_en;
        int exp_mem_wr_addr, exp_reg_wr_addr;
        int wpos;
        wpos = last_read_pos_q.pop_front();
        expected_write(wpos, exp_mem_wr_en, exp_mem_wr_addr, exp_reg_wr_en, exp_reg_wr_addr);
        check($sformatf("pos=%0d mem_wr", wpos), mem_wr_en, exp_mem_wr_en, mem_wr_addr, exp_mem_wr_addr, 1);
        check($sformatf("pos=%0d reg_wr", wpos), reg_wr_en, exp_reg_wr_en, reg_wr_addr, exp_reg_wr_addr, 1);
    endtask

    // Drain the final pending write check after a frame's last pixel
    task automatic drain_last_write();
        @(negedge clk);
        if (last_read_pos_q.size() > 0) check_pending_write();
    endtask

    task automatic run_frame(input string label, input int frame_no);
        $display("\n--- %s (frame %0d) ---", label, frame_no);
        for (int p = 0; p < POS_PER_FRAME; p++) begin
            send_and_check_read();
        end
        drain_last_write();
    endtask

    // =========================================================================
    // Test sequence
    // =========================================================================
    initial begin
        $display("=================================================");
        $display(" fetch_stage2_1 Testbench (BRAM wrap + fixed regfile)");
        $display(" BANK_DEPTH=%0d ACTIVE=%0d TOTAL=%0d REG_DEPTH=%0d POS_PER_FRAME=%0d",
                  BANK_DEPTH, BRAM_ACTIVE_BANKS, BRAM_TOTAL_BANKS, REG_DEPTH, POS_PER_FRAME);
        $display("=================================================");

        do_reset();

        // Frame 1: no reads anywhere, writes populate bank window starting at 0
        run_frame("FRAME 1 (first_frame, write-only)", 1);

        // Frame 2: reads bank window starting at 0 (frame 1's write), writes
        // bank window starting at BRAM_TOTAL_BANKS-1 (=3); regfile read+write
        // both fire on the same fixed regfile.
        pulse_frame_start();
        run_frame("FRAME 2", 2);

        // Frame 3: reads window starting at 3, writes window starting at 2.
        pulse_frame_start();
        run_frame("FRAME 3", 3);

        // Frame 4: reads window starting at 2, writes window starting at 1
        // (confirms the decrement continues correctly past the wrap).
        pulse_frame_start();
        run_frame("FRAME 4", 4);

        repeat(5) @(negedge clk);

        $display("=================================================");
        $display(" RESULT: %0d PASS / %0d FAIL", pass_count, fail_count);
        $display("=================================================");
        $finish;
    end

endmodule
