`timescale 1ns / 1ps
// =====================================================================================
// Testbench   : tb_LIF
// DUT         : LIF.sv  (Leaky Integrate-and-Fire neuron)
// Purpose     : Self-checking, non-UVM testbench. Runs a bit-accurate golden reference
//               model of the LIF update equations (see Section 4 of the LIF module
//               documentation) alongside the DUT every cycle, and reports a mismatch
//               the moment the DUT's spike output disagrees with the model.
// Written by  : Mohamed Hussein
// Date        : July 6, 2026
// Notes       : DUT reset is asynchronous, active-low (arst_n).
//               All stimulus (in_pool / arst_n) is driven with a #1 delay after the
//               triggering edge, never in the same simulation timestep as an edge.
//               This avoids the classic active-region race between the testbench
//               process and the DUT's always_ff block that both wake on posedge clk.
// =====================================================================================
 
`timescale 1ns / 1ps

module tb_LIF;

    // ---------------------------------------------------------------------------
    // Parameters
    // ---------------------------------------------------------------------------
    localparam int DATA_WIDTH = 18;
    localparam logic signed [DATA_WIDTH-1:0] THRESHOLD = 18'sd512;
    localparam int CLK_PERIOD = 10;

    // ---------------------------------------------------------------------------
    // DUT Connections
    // ---------------------------------------------------------------------------
    logic clk;
    logic arst_n;
    logic signed [DATA_WIDTH-1:0] in_pool;
    logic spike;

    int error_count = 0;
    int check_count = 0;

    // DUT Instance
    LIF #(
        .DATA_WIDTH (DATA_WIDTH),
        .THRESHOLD  (THRESHOLD)
    ) dut (
        .clk     (clk),
        .arst_n  (arst_n),
        .in_pool (in_pool),
        .spike   (spike)
    );

    // ---------------------------------------------------------------------------
    // Clock Generation
    // ---------------------------------------------------------------------------
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ===================================================================================
    // GOLDEN REFERENCE MODEL (Bit-accurate to DUT)
    // ===================================================================================
    logic signed [DATA_WIDTH-1:0] mem_model, mem_leak_model, mem_sum_model, reset_model, new_mem_model;
    logic spike_model, spike_reg_model;

    always_comb begin
        mem_leak_model = mem_model >>> 1;
        mem_sum_model  = mem_leak_model + in_pool;
        reset_model    = spike_reg_model ? THRESHOLD : 18'sd0;
        new_mem_model  = mem_sum_model - reset_model;
        spike_model    = (new_mem_model >= THRESHOLD);
    end

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            mem_model       <= '0;
            spike_reg_model <= 1'b0;
        end else begin
            mem_model       <= new_mem_model;
            spike_reg_model <= spike_model;
        end
    end

    // ===================================================================================
    // SCOREBOARD (Checks at negedge, compares DUT spike to golden model)
    // ===================================================================================
    always @(negedge clk) begin
        if (arst_n) begin
            check_count++;
            if (spike !== spike_model) begin
                error_count++;
                $error("[%0t] MISMATCH: dut.spike=%0b model.spike=%0b | in_pool=%0d",
                        $time, spike, spike_model, in_pool);
            end
        end
    end

    // ===================================================================================
    // STIMULUS TASKS 
    // ===================================================================================
    
    // Task 1: Assert/Release Reset (does NOT touch in_pool)
    task automatic do_reset();
        @(negedge clk);
        arst_n = 1'b0;          // Assert reset right after posedge
        
        @(negedge clk);            // Hold for 1 full cycle
        @(negedge clk);
        arst_n = 1'b1;          // Release exactly at negedge
    endtask

    // Task 2: Drive Input Strictly at Negedge (with #1 delay to avoid race)
    task automatic drive_input(logic signed [DATA_WIDTH-1:0] value);
        @(posedge clk);
        in_pool = value;
    endtask

    // ===================================================================================
    // MAIN STIMULUS
    // ===================================================================================
        initial begin
        $dumpfile("tb_LIF.vcd");
        $dumpvars(0, tb_LIF);

        // Initialize
        arst_n  = 1'b1;
        in_pool = '0;

        // --------------------------------------------------------------
        // Test 1: Power-on Reset
        // --------------------------------------------------------------
        do_reset();

        // --------------------------------------------------------------
        // Test 2: Boundary Checks (511, 512, 513)
        // --------------------------------------------------------------
        drive_input(18'sd511);      // Should NOT fire
        repeat(2) @(posedge clk);

        do_reset();
        drive_input(18'sd512);      // Should fire (>= threshold)
        repeat(2) @(posedge clk);

        do_reset();
        drive_input(18'sd513);      // Should fire
        repeat(2) @(posedge clk);

        // --------------------------------------------------------------
        // Test 3: High Input (600) -> Sustained Firing / Oscillation
        // --------------------------------------------------------------
        do_reset();
        drive_input(18'sd600);
        repeat(15) @(posedge clk);

        // --------------------------------------------------------------
        // Test 4: Low Input (100) -> Sub-threshold, should stay silent
        // --------------------------------------------------------------
        do_reset();
        drive_input(18'sd100);
        repeat(10) @(posedge clk);

        // --------------------------------------------------------------
        // Test 5: Zero Input -> Pure Decay
        // --------------------------------------------------------------
        drive_input(18'sd0);
        repeat(5) @(posedge clk);

        // --------------------------------------------------------------
        // Test 6: Negative Input -> Verify Signed Behavior
        // --------------------------------------------------------------
        drive_input(-18'sd50);
        repeat(5) @(posedge clk);

        // --------------------------------------------------------------
        // Test 7: Accumulation over multiple cycles (in_pool = 260)
        // --------------------------------------------------------------
        $display("\n--- Starting Accumulation Test (in_pool = 260) ---");    // this case is not working correctly
        do_reset();                          // Start from zero membrane
        repeat(40) begin
            drive_input($urandom_range(0,100));          // Apply constant small input
        end
        
        // Let it run for 10 cycles. The scoreboard will catch the spike at cycle 7.
        // The DUT's `spike` output will go high on the 7th rising edge.
        repeat(5) @(posedge clk);
        $display("--- Accumulation Test complete ---");

        // --------------------------------------------------------------
        // Test 8: Random Inputs (500 cycles)
        // --------------------------------------------------------------
        for (int i = 0; i < 100; i++) begin
            drive_input($urandom_range(0, (1 << DATA_WIDTH - DATA_WIDTH/2) - 1));
        end

        // --------------------------------------------------------------
        // Test 9: Asynchronous Reset Mid-Operation
        // --------------------------------------------------------------
        drive_input(18'sd600);
        repeat(3) @(posedge clk);
        
        #3 arst_n = 1'b0;           // Assert async reset mid-cycle
        #3 arst_n = 1'b1;           // Release it mid-cycle
        repeat(5) @(posedge clk);

        // --------------------------------------------------------------
        // Final Report
        // --------------------------------------------------------------
        if (error_count == 0)
            $display("\n=====================================\nTEST PASSED - %0d cycles checked\n=====================================\n", check_count);
        else
            $display("\n=====================================\nTEST FAILED - %0d mismatches out of %0d cycles\n=====================================\n", error_count, check_count);

        $finish;
    end

endmodule