// =============================================================================
// tb_deep_snn_top.sv
// =============================================================================
// Testbench for deep_snn_top.
//
// Purpose:
//   - Instantiate the DUT with default parameters.
//   - Drive clk/reset and the two start pulses (start_i, enable).
//   - Act as the external memory behind mem_addr_o / mem_rd_o / mem_data_i:
//     the input file is parsed into an array of MAP_WORD_W-bit words and
//     served back word-by-word as the DUT reads them.
//   - Watch classifier_done / done / map_done_o and report results.
//
// Input file format (input_t0.bin):
//   Plain ASCII text made up only of '0', '1' and newline characters.
//   Bits are packed MSB-first into MAP_WORD_W-bit words back-to-back
//   (newlines are just line-wrapping and are ignored, not word separators).
//
// IMPORTANT ASSUMPTION (please confirm against mapping_controller RTL):
//   This model assumes a synchronous, 1-cycle-latency memory: the DUT
//   presents mem_addr_o/mem_rd_o, and mem_data_i becomes valid on the
//   following clock edge. If your mapping_controller instead expects
//   combinational (same-cycle) data, flip MEM_SYNC_LATENCY below to 0.
// =============================================================================

`timescale 1ns/1ps

module tb_deep_snn_top;

    // -------------------------------------------------------------------
    // Config
    // -------------------------------------------------------------------
    localparam string MEM_FILE         = "input_t0.bin";
    localparam int    MEM_SYNC_LATENCY = 1;     // 1 = registered read, 0 = combinational
    localparam int    CLK_PERIOD_NS    = 10;
    localparam int    MAX_WORDS        = 65536; // sized by mem_addr_o width (16 bits)
    localparam int    TIMEOUT_CYCLES   = 2_000_000;

    // -------------------------------------------------------------------
    // DUT parameters (defaults from deep_snn_top; override here if needed)
    // -------------------------------------------------------------------
    localparam int PIXEL_W    = 18;
    localparam int DATA_WIDTH = 18;
    localparam int N_SHAABAN  = 32;
    localparam int MAP_WORD_W = 72;

    // -------------------------------------------------------------------
    // DUT I/O
    // -------------------------------------------------------------------
    logic                          clk;
    logic                          rst;
    logic                          arst_n;
    logic                          enable;

    logic                          pixel_mem_wr_en;
    logic [5:0]                    pixel_mem_wr_addr;
    logic [(384*PIXEL_W)-1:0]      pixel_mem_wr_data;
    logic                          start_i;
    logic [MAP_WORD_W-1:0]         mem_data_i;

`ifdef SIM
    logic                          sim_pixels_override;
    logic [(12*32*9*PIXEL_W)-1:0]  sim_pixels;
    logic                          sim_pixel_mem_override;
    logic [(384*PIXEL_W)-1:0]      sim_pixel_mem_data;
`endif

    logic [N_SHAABAN-1:0]          spike_out;
    logic [(4*DATA_WIDTH)-1:0]     class_logits;
    logic                          classifier_done;
    logic                          classifier_busy;
    logic                          snn_done;
    logic                          done;
    logic [15:0]                   mem_addr_o;
    logic                          mem_rd_o;
    logic                          map_done_o;

    // -------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------
    deep_snn_top #(
        .PIXEL_W    (PIXEL_W),
        .DATA_WIDTH (DATA_WIDTH),
        .N_SHAABAN  (N_SHAABAN),
        .MAP_WORD_W (MAP_WORD_W)
    ) DUT (
        .clk                (clk),
        .rst                (rst),
        .arst_n             (arst_n),
        .enable             (enable),

        .pixel_mem_wr_en    (pixel_mem_wr_en),
        .pixel_mem_wr_addr  (pixel_mem_wr_addr),
        .pixel_mem_wr_data  (pixel_mem_wr_data),
        .start_i            (start_i),
        .mem_data_i         (mem_data_i),

`ifdef SIM
        .sim_pixels_override    (sim_pixels_override),
        .sim_pixels              (sim_pixels),
        .sim_pixel_mem_override  (sim_pixel_mem_override),
        .sim_pixel_mem_data      (sim_pixel_mem_data),
`endif

        .spike_out          (spike_out),
        .class_logits       (class_logits),
        .classifier_done    (classifier_done),
        .classifier_busy    (classifier_busy),
        .snn_done           (snn_done),
        .done               (done),
        .mem_addr_o         (mem_addr_o),
        .mem_rd_o           (mem_rd_o),
        .map_done_o         (map_done_o)
    );

    // -------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------
    initial clk = 1'b0;
    always #(CLK_PERIOD_NS/2) clk = ~clk;

    // -------------------------------------------------------------------
    // Memory model: parse input_t0.bin into MAP_WORD_W-bit words
    // -------------------------------------------------------------------
    logic [MAP_WORD_W-1:0] mem_array [0:MAX_WORDS-1];
    int                    num_words;

    task automatic load_mem_file();
        int fd;
        int c;
        int bit_cnt;
        int word_idx;
        logic [MAP_WORD_W-1:0] w;
        begin
            fd = $fopen(MEM_FILE, "r");
            if (fd == 0) begin
                $fatal(1, "[TB] ERROR: could not open memory file '%s'", MEM_FILE);
            end

            word_idx = 0;
            bit_cnt  = 0;
            w        = '0;

            c = $fgetc(fd);
            while (c != -1) begin
                if (c == "0" || c == "1") begin
                    w = {w[MAP_WORD_W-2:0], (c == "1") ? 1'b1 : 1'b0}; // MSB-first pack
                    bit_cnt++;
                    if (bit_cnt == MAP_WORD_W) begin
                        if (word_idx >= MAX_WORDS) begin
                            $fatal(1, "[TB] ERROR: %s has more than MAX_WORDS=%0d words",
                                   MEM_FILE, MAX_WORDS);
                        end
                        mem_array[word_idx] = w;
                        word_idx++;
                        bit_cnt = 0;
                        w       = '0;
                    end
                end
                // any other character (newline, CR, etc.) is ignored
                c = $fgetc(fd);
            end
            $fclose(fd);

            if (bit_cnt != 0) begin
                $display("[TB] WARNING: %0d leftover bits at EOF did not form a full %0d-bit word (ignored)",
                          bit_cnt, MAP_WORD_W);
            end

            num_words = word_idx;
            $display("[TB] Loaded %0d words (%0d bits each) from '%s'", num_words, MAP_WORD_W, MEM_FILE);
        end
    endtask

    initial begin
        load_mem_file();
    end

    // -------------------------------------------------------------------
    // Serve mem_data_i from mem_array based on mem_addr_o / mem_rd_o
    // -------------------------------------------------------------------
    function automatic logic [MAP_WORD_W-1:0] read_word(input logic [15:0] addr);
        if (addr < num_words)
            return mem_array[addr];
        else begin
            $display("[TB] WARNING: mem_addr_o=%0d out of range (num_words=%0d) at time %0t",
                       addr, num_words, $time);
            return '0;
        end
    endfunction

    generate
        if (MEM_SYNC_LATENCY == 1) begin : gen_sync_mem
            // Registered (1-cycle) read: address/rd sampled this edge,
            // data returned on the following edge.
            always_ff @(posedge clk or negedge arst_n) begin
                if (!arst_n)
                    mem_data_i <= '0;
                else if (mem_rd_o)
                    mem_data_i <= read_word(mem_addr_o);
            end
        end else begin : gen_comb_mem
            // Combinational (same-cycle) read.
            always_comb begin
                mem_data_i = mem_rd_o ? read_word(mem_addr_o) : '0;
            end
        end
    endgenerate

    // Log each word actually consumed by the DUT
    int words_read_count = 0;
    always_ff @(posedge clk) begin
        if (mem_rd_o) begin
            words_read_count <= words_read_count + 1;
        end
    end

    // -------------------------------------------------------------------
    // Reset / stimulus
    // -------------------------------------------------------------------
    initial begin
        // Idle defaults
        rst                = 1'b1;
        arst_n             = 1'b0;
        enable             = 1'b0;
        start_i            = 1'b0;
        pixel_mem_wr_en    = 1'b0;
        pixel_mem_wr_addr  = '0;
        pixel_mem_wr_data  = '0;
`ifdef SIM
        sim_pixels_override    = 1'b0;
        sim_pixels              = '0;
        sim_pixel_mem_override  = 1'b0;
        sim_pixel_mem_data      = '0;
`endif

        // Async reset pulse
        repeat (4) @(posedge clk);
        arst_n = 1'b1;
        repeat (2) @(posedge clk);
        rst    = 1'b0;
        repeat (2) @(posedge clk);

        // Kick off the mapping controller: it will start pulling
        // mem_data_i word-by-word via mem_addr_o/mem_rd_o.
        @(posedge clk);
        start_i <= 1'b1;
        @(posedge clk);
        start_i <= 1'b0;

        // Kick off the top controller / SNN pipeline.
        // NOTE: adjust timing here if your design requires enable to wait
        // for map_done_o before pulsing (see comments at top of file).
        @(posedge clk);
        enable <= 1'b1;
        @(posedge clk);
        enable <= 1'b0;
    end

    // -------------------------------------------------------------------
    // Completion / timeout watchdog
    // -------------------------------------------------------------------
    int cycle_count = 0;
    always_ff @(posedge clk) begin
        cycle_count <= cycle_count + 1;
    end

    initial begin
        wait (map_done_o === 1'b1);
        $display("[TB] map_done_o asserted at time %0t (%0d words consumed)", $time, words_read_count);
    end

    initial begin
        wait (done === 1'b1);
        $display("[TB] done asserted at time %0t", $time);
        $display("[TB] classifier_done=%0b  spike_out=%h  class_logits=%h",
                   classifier_done, spike_out, class_logits);
        repeat (5) @(posedge clk);
        $display("[TB] Simulation finished normally.");
        $finish;
    end

    initial begin
        wait (cycle_count >= TIMEOUT_CYCLES);
        $display("[TB] ERROR: TIMEOUT after %0d cycles without 'done'. words_read=%0d/%0d",
                   TIMEOUT_CYCLES, words_read_count, num_words);
        $finish;
    end

    // -------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------
    initial begin
        $dumpfile("tb_deep_snn_top.vcd");
        $dumpvars(0, tb_deep_snn_top);
    end

endmodule
