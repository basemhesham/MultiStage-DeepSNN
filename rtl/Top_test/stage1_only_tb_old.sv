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

module stage1_only_tb_old;

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

    // =========================================================================
    // Clock
    // =========================================================================
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // Image memory model (dummy_image_256x256.hex -> packed 72-bit words)
    // =========================================================================
    logic [PIXEL_W-1:0]    pixel_flat [0:(IMG_ROWS_FULL*IMG_COLS_FULL)-1];
    logic [MAP_WORD_W-1:0] image_mem  [0:MEM_DEPTH-1];

    initial begin
        // One 18-bit hex value per line, 256*256 = 65536 lines, row-major.
        $readmemh("dummy_image_256x256.hex", pixel_flat);

        for (int w = 0; w < MEM_DEPTH; w++) begin
            // 4 pixels/word, pixel 0 in the LSBs (matches WORD_W=4*PIXEL_W
            // packing assumed by mapping_controller).
            image_mem[w] = { pixel_flat[w*4 + 3],
                              pixel_flat[w*4 + 2],
                              pixel_flat[w*4 + 1],
                              pixel_flat[w*4 + 0] };
        end
    end

    

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

    // 1-cycle read latency, as documented in Mapping_Cntrl.sv:
    // "addr presented cycle N, data valid cycle N+1"
    always_ff @(posedge clk) begin
        if (mem_rd_o /*&& (DUT.u_mapping_controller.next_state != DUT.u_mapping_controller.FETCH)*/)
            mem_data_i <= image_mem[mem_addr_o[MEM_ADDR_BITS-1:0]];
    end

    initial begin

        f_mapping         = $fopen("mapping_controller.txt", "w");
        f_pixel_mapper    = $fopen("pixel_source_mapper.txt", "w");
        f_conv9           = $fopen("conv9_array.txt", "w");
        f_adder_tree      = $fopen("adder_tree_connect.txt", "w");
        f_shaaban         = $fopen("shaaban_array.txt", "w");
        f_spike_writeback = $fopen("spike_writeback.txt", "w");
        f_controller      = $fopen("top_controller.txt", "w");

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
        enable = 1'b0;

        // One pulse tells mapping_controller to start fetching mem_data_i
        start_i = 1'b1;
        @(posedge clk);
        start_i = 1'b0;
    end

    // =========================================================================
    // Stage-1-only cutoff
    // -----------------------------------------------------------------------
    // `ns` is top_controller's internal next-state signal (type state_t).
    // The moment it becomes STAGE2 we know top_controller is about to leave
    // Stage 1, so the TB is done -- finish immediately without simulating
    // any of Stage 2/Stage 3.
    // =========================================================================
    always @(posedge clk) begin
        if (DUT.u_top_controller.ns == DUT.u_top_controller.STAGE2) begin
            $display("==========================================================");
            $display("[%0t] Stage 1 finished (ns == STAGE2). Ending testbench.", $time);
            $display("==========================================================");

            $fclose(f_mapping);
            $fclose(f_pixel_mapper);
            $fclose(f_conv9);
            $fclose(f_adder_tree);
            $fclose(f_shaaban);
            $fclose(f_spike_writeback);
            $fclose(f_controller);

            $finish;
        end
    end

    // Safety net in case Stage 1 never completes
    initial begin
        #(CLK_PERIOD * 2_000_000);
        $fatal(1, "TIMEOUT: simulation never reached STAGE2 (Stage 1 did not finish)");
    end

    // =========================================================================
    // Per-block debug printing (only while top_controller is actually in
    // STAGE1, i.e. only for cycles that belong to the stage we're verifying)
    // =========================================================================
    wire in_stage1 = (DUT.u_top_controller.cs == DUT.u_top_controller.STAGE1);

    // Block 1: mapping_controller (mem_data_i -> conv_pixels_o)
    always @(posedge clk) begin
        if (DUT.map_conv_valid_o)
            $fdisplay(f_mapping,
            "[%0t] conv_valid_o=1 conv_done_o=%0b frame_done_o=%0b addr=%0d",
            $time,
            DUT.map_conv_done_o,
            DUT.map_frame_done_o,
            mem_addr_o);
    end

    // Block 2: top_pixel_source_mapper (pixels_mapped)
    always @(posedge clk) begin
        if (in_stage1)
            $fdisplay(f_pixel_mapper,
            "[%0t] stage1_pos=%0d pixels_mapped[0][0][0..2]=%0d,%0d,%0d",
            $time,
            DUT.u_top_controller.stage1_pos,
            DUT.pixels_mapped[0][0][0],
            DUT.pixels_mapped[0][0][1],
            DUT.pixels_mapped[0][0][2]);
    end

    // Block 3: top_conv9_array (mac_to_connect)
    always @(posedge clk) begin
        if (in_stage1)
            $fdisplay(f_conv9,
            "[%0t] mac_to_connect[0][0]=%0d mac_to_connect[0][1]=%0d",
            $time,
            DUT.mac_to_connect[0][0],
            DUT.mac_to_connect[0][1]);
    end

    // Block 4: adder_tree_shaaban_connect (shb_bus)
    always @(posedge clk) begin
        if (in_stage1)
            $fdisplay(f_adder_tree,
            "[%0t] shb_bus[0]=%0d shb_bus[1]=%0d",
            $time,
            DUT.shb_bus[0],
            DUT.shb_bus[1]);
    end

    // Block 5: top_shaaban_array (LIF + spikes)
    always @(posedge clk) begin
        if (in_stage1)
            $fdisplay(f_shaaban,
            "[%0t] spike_out=%b",
            $time,
            spike_out);
    end

    // Block 6: top_spike_writeback (packed word going to spike_mem)
    always @(posedge clk) begin
        if (in_stage1)
            $fdisplay(f_spike_writeback,
            "[%0t] spike_mem_wr_data[63:0]=%h",
            $time,
            DUT.spike_mem_wr_data[63:0]);
    end

    // Controller state transitions (always printed, gives the overall picture)
    always @(posedge clk) begin
        if (DUT.u_top_controller.cs != DUT.u_top_controller.ns)
            $fdisplay(f_controller,
            "[%0t] cs -> ns : %0s -> %0s",
            $time,
            DUT.u_top_controller.cs.name(),
            DUT.u_top_controller.ns.name());
    end

endmodule