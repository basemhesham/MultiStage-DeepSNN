`timescale 1ns / 1ps
// =====================================================================================
// Testbench   : tb_LIF
// DUT         : LIF.sv  (Leaky Integrate-and-Fire neuron)
// Purpose     : Self-checking testbench tailored for the Time-Multiplexed LIF.
//               Since the DUT is now purely combinational, the TB simulates the 
//               external history BRAM by catching `hist_out` and feeding it to `hist_in`.
// =====================================================================================
 
module tb_LIF;

    //    // ---------------------------------------------------------------------------
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
    
    // New Interface Signals
    logic in_valid;
    logic first_frame;
    logic signed [DATA_WIDTH-1:0] in_pool;
    logic signed [DATA_WIDTH-1:0] hist_in;
    
    // DUT Outputs
    logic spike_out;
    logic signed [DATA_WIDTH-1:0] hist_out;

    int error_count = 0;
    int check_count = 0;

    //    // ---------------------------------------------------------------------------
    // DUT Instance
    // ---------------------------------------------------------------------------
    LIF #(
        .DATA_WIDTH (DATA_WIDTH),
        .THRESHOLD  (THRESHOLD),
        .ZERO       (18'sd0)
    ) dut (
        .clk         (clk),
        .arst_n      (arst_n),
        .in_valid    (in_valid),
        .first_frame (first_frame),
        .in_pool     (in_pool),
        .hist_in     (hist_in),
        .spike_out   (spike_out),
        .hist_out    (hist_out)
    );

    //    // ---------------------------------------------------------------------------
    // Clock Generation
    // ---------------------------------------------------------------------------
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ---------------------------------------------------------------------------
    // Simulated External History Memory (BRAM)
    // ---------------------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0] tb_bram_hist;
    
    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            tb_bram_hist <= '0;
        end else if (in_valid) begin
            // Latch the calculated history to feed into the next cycle
            tb_bram_hist <= hist_out; 
        end
    end
    
    assign hist_in = tb_bram_hist;

    //    // ===================================================================================
    // GOLDEN REFERENCE MODEL (Bit-accurate to new Comb DUT)
    // ===================================================================================
    logic signed [DATA_WIDTH-1:0] expected_actual_hist;
    logic signed [DATA_WIDTH-1:0] expected_u_t;
    logic signed [DATA_WIDTH-1:0] expected_u_t_leak;
    logic signed [DATA_WIDTH-1:0] expected_reset_penalty;
    logic                         expected_spike_out;
    logic signed [DATA_WIDTH-1:0] expected_hist_out;

    always_comb begin
        // 1. Operand isolation
        expected_actual_hist   = first_frame ? 18'sd0 : hist_in;
        // 2. Membrane potential
        expected_u_t           = expected_actual_hist + in_pool;
        // 3. Spike Evaluation
        expected_spike_out     = (expected_u_t >= THRESHOLD);
        // 4. Leak and Penalty
        expected_u_t_leak      = expected_u_t >>> 1;
        expected_reset_penalty = expected_spike_out ? THRESHOLD : 18'sd0;
        // 5. Final History
        expected_hist_out      = expected_u_t_leak - expected_reset_penalty;
    end

    //    // ===================================================================================
    // SCOREBOARD (Checks at negedge, compares DUT to golden comb model)
    // ===================================================================================
    always @(negedge clk) begin
        if (arst_n && in_valid) begin
            check_count++;
            if (spike_out !== expected_spike_out || hist_out !== expected_hist_out) begin
                error_count++;
                $error("[%0t] MISMATCH: dut(S=%0b, H=%0d) expected(S=%0b, H=%0d) | in_pool=%0d, hist_in=%0d, first_frame=%0b",
                        $time, spike_out, hist_out, expected_spike_out, expected_hist_out, in_pool, hist_in, first_frame);
            end
        end
    end

    //    // ===================================================================================
    // STIMULUS TASKS 
    // ===================================================================================
    
    // Task 1: Assert/Release Reset
    task automatic do_reset();
        @(negedge clk);
        arst_n = 1'b0;          
        in_valid = 1'b0;
        first_frame = 1'b1;
        in_pool = '0;
        
        @(negedge clk);            
        @(negedge clk);
        arst_n = 1'b1;          
    endtask

    // Task 2: Drive Input Strictly at Negedge
    task automatic drive_input(logic signed [DATA_WIDTH-1:0] value, logic is_first = 1'b0);
        @(negedge clk);
        #1;
        in_pool = value;
        first_frame = is_first;
        in_valid = 1'b1;
    endtask

    //    // ===================================================================================
    // MAIN STIMULUS
    // ===================================================================================
    initial begin
        $dumpfile("tb_LIF.vcd");
        $dumpvars(0, tb_LIF);

        // Initialize
        arst_n      = 1'b0;
        in_valid    = 1'b0;
        first_frame = 1'b0;
        in_pool     = '0;
        #100;

        // --------------------------------------------------------------
        // Test 1: Power-on Reset
        // --------------------------------------------------------------
        do_reset();

        // --------------------------------------------------------------
        // Test 2: Boundary Checks (first_frame behavior)
        // --------------------------------------------------------------
        drive_input(18'sd511, 1'b1);      // Should NOT fire
        repeat(2) @(posedge clk);

        do_reset();
        drive_input(18'sd512, 1'b1);      // Should fire (>= threshold)
        repeat(2) @(posedge clk);

        do_reset();
        drive_input(18'sd513, 1'b1);      // Should fire
        repeat(5) @(posedge clk);

        // --------------------------------------------------------------
        // Test 3: High Input (600) -> Sustained Firing
        // --------------------------------------------------------------
        do_reset();
        drive_input(18'sd600, 1'b1); // Frame 0
        drive_input(18'sd600, 1'b0); // Frame 1+ (Hold it)
        repeat(15) @(posedge clk);

        // --------------------------------------------------------------
        // Test 4: Low Input (100) -> Sub-threshold, should stay silent
        // --------------------------------------------------------------
        do_reset();
        drive_input(18'sd100, 1'b1); // Frame 0
        drive_input(18'sd100, 1'b0); // Frame 1+
        repeat(10) @(posedge clk);

        // --------------------------------------------------------------
        // Test 5: Zero Input -> Pure Decay
        // --------------------------------------------------------------
        drive_input(18'sd0, 1'b0);
        repeat(5) @(posedge clk);

        // --------------------------------------------------------------
        // Test 6: Negative Input -> Verify Signed Behavior
        // --------------------------------------------------------------
        drive_input(-18'sd50, 1'b1); // Frame 0
        drive_input(-18'sd50, 1'b0); // Frame 1+
        repeat(5) @(posedge clk);

        // --------------------------------------------------------------
        // Test 7: Accumulation over multiple cycles (Fixed Math)
        // Note: With Beta=0.5, inputs < 256 NEVER cross a 512 threshold.
        // We use 260, which mathematicaly converges to 520, firing on cycle 7.
        // --------------------------------------------------------------
        $display("\n--- Starting Accumulation Test (in_pool = 260) ---");
        do_reset();                          
        
        drive_input(18'sd260, 1'b1); // Cycle 1 (Frame 0: isolated hist)
        drive_input(18'sd260, 1'b0); // Cycle 2 (Frame 1+: accumulating)
        
        // Let it run for 5 more cycles. Scoreboard will catch spike on cycle 7.
        repeat(5) @(posedge clk);
        $display("--- Accumulation Test complete ---");

        // --------------------------------------------------------------
        // Test 8: Random Inputs 
        // --------------------------------------------------------------
        do_reset();
        for (int i = 0; i < 100; i++) begin
            // Randomly toggle first_frame to stress operand isolation
            logic rand_first = ($urandom % 10 == 0); 
            drive_input($urandom_range(0, (1 << DATA_WIDTH - DATA_WIDTH/2) - 1), rand_first);
        end

        // --------------------------------------------------------------
        // Final Report
        // --------------------------------------------------------------
        if (error_count == 0)
            $display("\n=====================================\nTEST PASSED - %0d checks completed\n=====================================\n", check_count);
        else
            $display("\n=====================================\nTEST FAILED - %0d mismatches out of %0d checks\n=====================================\n", error_count, check_count);

        $finish;
    end

endmodule