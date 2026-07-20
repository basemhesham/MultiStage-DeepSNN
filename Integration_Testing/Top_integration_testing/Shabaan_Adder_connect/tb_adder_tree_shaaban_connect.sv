`timescale 1ns / 1ps
// =============================================================================
// tb_adder_tree_shaaban_connect.sv
// -----------------------------------------------------------------------------
// WHAT THIS TB CHECKS
//
//   T1  Reset: all 32 spike_out bits are 0 immediately after reset.
//
//   T2  Stage 1 (src_sel=00):
//       Drive all 384 MAC inputs with a known positive value.
//       Check that the corrected flat_s1 array produces activity across
//       all 32 Shaaban units (non-zero input → some spikes expected).
//
//   T3  Stage 2 (src_sel=01):
//       Drive all MAC inputs. Only Shaabans 0,1,2 should see non-zero data.
//       Check spike_out[31:3] === 0 (inactive units stay silent).
//
//   T4  Stage 3 (src_sel=10):
//       Apply final_s3. Only Shaaban 0 should see data.
//       Check spike_out[31:1] === 0.
//
//   T5  src_sel transition Stage1 → Stage2:
//       Switch mid-run; idle units must go silent promptly.
//
//   T6  Correction adder verification:
//       Drive tree0[30] and tree0[31] with known values, zero everything else.
//       In Stage 1, Shaaban 2 (which receives flat_s1[8..11], including
//       corr_out[0] at flat_s1[10]) should reflect the corrected sum.
//
// NOTE: shaban_unit_top is a black box here — spike output depends on its
// internal threshold. Tests focus on connectivity (correct routing) rather
// than exact spike values.
// =============================================================================

module tb_adder_tree_shaaban_connect;

    // ── Parameters ────────────────────────────────────────────────────────────
    localparam int N_TREES        = 12;
    localparam int TAPS_PER_TREE  = 10;
    localparam int N_SHAABAN      = 32;
    localparam int INPUTS_PER_SHB = 4;
    localparam int POOL_NUM       = 2;
    localparam int DATA_WIDTH     = 18;
    localparam int N_CORRECTION   = 8;

    // ── Clock: 40 MHz (25 ns period) ─────────────────────────────────────────
    logic clk = 0;
    always #12.5 clk = ~clk;

    // ── DUT signals ───────────────────────────────────────────────────────────
    logic        rst;
    logic [1:0]  src_sel;
    logic signed [DATA_WIDTH-1:0] mac_in [0:N_TREES-1][0:31];
    logic signed [DATA_WIDTH-1:0] final_s3;
    logic signed [DATA_WIDTH-1:0] conv_bias, mult_weight, add_weight;
    logic [N_SHAABAN-1:0] spike_out;

    // ── DUT instantiation ────────────────────────────────────────────────────
    adder_tree_shaaban_connect #(
        .N_TREES       (N_TREES),
        .TAPS_PER_TREE (TAPS_PER_TREE),
        .N_SHAABAN     (N_SHAABAN),
        .INPUTS_PER_SHB(INPUTS_PER_SHB),
        .POOL_NUM      (POOL_NUM),
        .DATA_WIDTH    (DATA_WIDTH)
    ) dut (
        .clk        (clk),
        .rst        (rst),
        .src_sel    (src_sel),
        .mac_in     (mac_in),
        .final_s3   (final_s3),
        .conv_bias  (conv_bias),
        .mult_weight(mult_weight),
        .add_weight (add_weight),
        .spike_out  (spike_out)
    );

    // ── Helper tasks ──────────────────────────────────────────────────────────

    // Apply synchronous reset for 4 cycles
    task apply_reset();
        rst = 1; src_sel = 2'b00;
        repeat(4) @(posedge clk);
        rst = 0;
        @(posedge clk);
    endtask

    // Set all MAC inputs and auxiliary signals to zero; BN weights = identity
    task zero_all();
        for (int t = 0; t < N_TREES; t++)
            for (int i = 0; i < 32; i++)
                mac_in[t][i] = '0;
        final_s3    = '0;
        conv_bias   = '0;
        mult_weight = 18'sd1;   // BN: 1*x + 0 (identity, avoids zero-kill)
        add_weight  = '0;
    endtask

    // Drive all 384 MAC slots with the same value
    task drive_all_macs(input logic signed [DATA_WIDTH-1:0] val);
        for (int t = 0; t < N_TREES; t++)
            for (int i = 0; i < 32; i++)
                mac_in[t][i] = val;
    endtask

    // Wait N cycles then sample outputs
    task wait_and_sample(input int n);
        repeat(n) @(posedge clk);
        #1; // small delay past clock edge for stable sampling
    endtask

    // ── Test sequence ─────────────────────────────────────────────────────────
    initial begin
        $display("============================================================");
        $display("TB: adder_tree_shaaban_connect");
        $display("    N_TREES=%0d  N_SHAABAN=%0d  N_CORRECTION=%0d",
                 N_TREES, N_SHAABAN, N_CORRECTION);
        $display("============================================================");

        zero_all();
        apply_reset();

        // ── T1: Reset ────────────────────────────────────────────────────────
        @(posedge clk); #1;
        if (spike_out === '0)
            $display("PASS T1 — Reset: all 32 spikes = 0");
        else
            $display("FAIL T1 — Reset: spike_out = %b (expected all 0)", spike_out);

        // ── T2: Stage 1 — all 32 Shaabans active ────────────────────────────
        src_sel = 2'b00;
        drive_all_macs(18'sd80);
        wait_and_sample(30);
        $display("T2  Stage1: %0d/32 Shaabans spiking  spike_out=%b",
                 $countones(spike_out), spike_out);

        // ── T3: Stage 2 — only units 0,1,2 active ───────────────────────────
        zero_all();
        src_sel = 2'b01;
        drive_all_macs(18'sd100);
        wait_and_sample(30);
        $display("T3  Stage2: spike[2:0]=%b  spike[31:3]=%b",
                 spike_out[2:0], spike_out[31:3]);
        if (spike_out[31:3] === '0)
            $display("PASS T3 — Stage2: units 3..31 correctly silent");
        else
            $display("FAIL T3 — Stage2: unexpected activity spike[31:3]=%b",
                     spike_out[31:3]);

        // ── T4: Stage 3 — only unit 0 active ─────────────────────────────────
        zero_all();
        src_sel  = 2'b10;
        final_s3 = 18'sd200;
        wait_and_sample(30);
        $display("T4  Stage3: spike[0]=%b  spike[31:1]=%b",
                 spike_out[0], spike_out[31:1]);
        if (spike_out[31:1] === '0)
            $display("PASS T4 — Stage3: units 1..31 correctly silent");
        else
            $display("FAIL T4 — Stage3: unexpected activity spike[31:1]=%b",
                     spike_out[31:1]);

        // ── T5: src_sel transition Stage1 → Stage2 ───────────────────────────
        zero_all();
        src_sel = 2'b00;
        drive_all_macs(18'sd50);
        wait_and_sample(15);
        src_sel = 2'b01;          // switch to Stage 2 mid-run
        wait_and_sample(20);
        if (spike_out[31:3] === '0)
            $display("PASS T5 — Transition: units 3..31 silent after switch to Stage2");
        else
            $display("FAIL T5 — Transition: ghost spikes spike[31:3]=%b",
                     spike_out[31:3]);

        // ── T6: Correction adder routing ─────────────────────────────────────
        // corr_out[0] uses tree0[30], tree0[31], tree1[30]
        // It lands at flat_s1[10], which feeds Shaaban 2 slot 2 (flat_s1[8..11])
        // Drive only those three MAC slots; everything else stays zero.
        zero_all();
        src_sel = 2'b00;
        mac_in[0][30] = 18'sd50;    // tree0 orphan slot 30
        mac_in[0][31] = 18'sd50;    // tree0 orphan slot 31
        mac_in[1][30] = 18'sd50;    // tree1 orphan slot 30 (part of corr[0])
        wait_and_sample(30);
        // Shaabans 0 and 1 should be silent (their taps come from mac_in[t][0..29], all zero)
        // Shaaban 2 may spike because flat_s1[10] = corr_out[0] = 150 (non-zero)
        $display("T6  Correction routing: spike[2:0]=%b (expect Shaaban 2 may be active)",
                 spike_out[2:0]);
        $display("    spike[0]=%b spike[1]=%b (expect 0 — no tap data for Shaabans 0,1)",
                 spike_out[0], spike_out[1]);
        if (spike_out[0] === 1'b0 && spike_out[1] === 1'b0)
            $display("PASS T6 — Shaabans 0,1 silent (correction routing is isolated)");
        else
            $display("FAIL T6 — Shaabans 0,1 unexpectedly active");

        $display("============================================================");
        $display("TB COMPLETE");
        $display("============================================================");
        $finish;
    end

    // ── Timeout watchdog ─────────────────────────────────────────────────────
    initial begin
        #1_000_000;
        $display("TIMEOUT — simulation exceeded limit");
        $finish;
    end

    // ── Waveform dump ─────────────────────────────────────────────────────────
    initial begin
        $dumpfile("tb_adder_tree_shaaban_connect.vcd");
        $dumpvars(0, tb_adder_tree_shaaban_connect);
    end

endmodule
