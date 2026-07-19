// =============================================================================
// tb_conv_adder_shaaban_top.sv
// -----------------------------------------------------------------------------
// Stage-1 integration testbench for:
//     top_conv9_array -> adder_tree_shaaban_connect -> top_shaaban_array
// (wrapped together as conv_Adder_shaaban_top)
//
// WHAT THIS TESTBENCH DOES
//   1. Loads the 32x5x5 Stage-1 conv filter weights from w_conv1_weight.bin
//      (packed binary-digit text rows) and re-maps them into the RTL's
//      weights_mapped[12][32][9] layout, using the EXACT same
//      window/block/channel-rotation rule that the (not-instantiated-here)
//      top_pixel_source_mapper/top_weight_mapper apply -- see
//      build_weights_mapped() below. Weights are static for the whole run.
//   2. Loads real Stage-1 Batch-Norm parameters (BN1_WEIGHTS/BN1_BIAS) --
//      conv_bias_param is always 0 per the design ("Usually zero" in the
//      DUT's own port comment).
//   3. Streams pixels_mapped[12][32][9] cycle-by-cycle from
//      stage1_conv_array_input_t0_SAMPLE.txt (the file already produced by
//      the Python front-end model -- one "# cycle=..." header line followed
//      by 3456 space-separated 18-bit hex values, per FETCH cycle).
//   4. Drives src_sel = 2'b00 throughout (Stage 1 routing).
//   5. Each cycle, after allowing one clock for the DUT's single register
//      (LIF's mem_reg/spike_reg) to update, dumps every requested stage's
//      outputs to its own text file for later comparison against a Python
//      reference model.
//
// WHY ONE CLOCK PER CYCLE IS ENOUGH ("waiting for valid")
//   Every block between the conv9 array and the LIF's combinational
//   new_mem/spike_int is PURELY COMBINATIONAL under `SIM` (the DSP48E2
//   wrappers in conv9.sv and Batch_Norm.v both collapse to plain `assign`
//   statements when `SIM` is defined). The ONLY state in the whole design
//   is LIF's mem_reg/spike_reg. So: drive pixels_mapped at negedge clk,
//   move to the next negedge clk (one posedge occurs in between, updating
//   mem_reg with THIS cycle's contribution), then every signal in the
//   design -- combinational stages AND the freshly-updated membrane state
//   -- is simultaneously valid and stable to sample. No multi-cycle
//   pipeline fill is required; this matches the DUT's own architecture,
//   not a simplifying assumption.
//
// RESET POLARITY
//   shaban_unit_top wires its `rst` input straight to LIF's `arst_n`, and
//   LIF treats arst_n as active-low, asynchronous (`if (!arst_n)`). This
//   was cross-checked against the two example testbenches shipped in the
//   same RTL package, both of which drive rst=0 then release with rst=1.
//   We do the same here.
//
// SIMULATOR INVOCATION
//   The behavioral (non-DSP48E2-primitive) paths in conv9.sv and
//   Batch_Norm.v are guarded by `ifdef SIM. Compile with the SIM macro
//   defined, e.g.:
//       vlog   +define+SIM  <all .v/.sv files>  tb_conv_adder_shaaban_top.sv
//       xrun   +define+SIM  <all .v/.sv files>  tb_conv_adder_shaaban_top.sv
//       vcs    +define+SIM  <all .v/.sv files>  tb_conv_adder_shaaban_top.sv
//   A `define SIM is also placed at the top of this file as a best-effort
//   fallback for tool flows that preprocess in single-invocation file order,
//   but the command-line +define+SIM is the portable, recommended method.
//
// -----------------------------------------------------------------------------
// GOLDEN-MODEL COMPATIBILITY UPDATE (this revision)
// -----------------------------------------------------------------------------
//   Scope of this change, per explicit direction: the pixel side stays as-is
//   -- pixels_mapped is still produced/parsed externally by the Python
//   front-end (rtl_mapping_model.py) and streamed in from PIXELS_FILE; this
//   testbench does not read input_t0.bin directly and does not reconstruct
//   full [channel][row][col] spatial tensors. Golden-model comparison
//   (against bn1_out.bin / pool1_out.bin / lif1_out.bin, which store full
//   [C][H][W] tensors as one packed-18-bit-two's-complement-binary value per
//   element, "# shape: [...] | lines N cols M" headered, identical to the
//   w_conv1_weight.bin / w_bn1_*.bin / w_conv1_bias.bin convention already
//   parsed by load_weights()/load_bn_*_file() below) is still done
//   externally by a Python script. What changed here is only what that
//   script needs FROM this testbench to do that comparison correctly:
//     1. Input-side parsing (Section 7) now actually PARSES the
//        "# cycle=... sweep=... win=... row=... col=... valid=...
//        conv_done=... frame_done=..." header line instead of discarding
//        it. This metadata is the only way to know which (row, col) of the
//        golden [C][H][W] tensors a given cycle's outputs correspond to,
//        and previously it was thrown away.
//     2. write_cycle_tag() (Section 8) now emits that same metadata on
//        every "CYCLE" line of every dump file, so the Python comparison
//        script can align each cycle's dumped values to the correct
//        (row, col) slice of bn1_out.bin/pool1_out.bin/lif1_out.bin.
//     3. The three dumps that have a direct golden-model counterpart --
//        dump_batch_norm() (-> bn1_out.bin), dump_max_pooling()'s
//        final_pool_out field (-> pool1_out.bin), and dump_lif_spike()
//        (-> lif1_out.bin) -- now ADDITIONALLY emit each value as a packed
//        18-bit two's-complement binary string (see bin18() in Section 5),
//        i.e. the exact on-disk encoding used by the golden .bin files, so
//        the same bit-parsing routine used on the golden files can be
//        reused verbatim on the RTL dumps. The original decimal fields are
//        left in place (appended-to, not replaced), so any existing
//        parsing of these files keeps working unchanged.
//   No DUT connectivity, timing, reset behavior, or pipeline logic was
//   touched. Every change here is confined to file I/O/formatting tasks in
//   Sections 5, 7, and 8.
//
// -----------------------------------------------------------------------------
// FOLLOW-UP UPDATE: PIXELS_FILE is now pre-stripped of '#' lines
// -----------------------------------------------------------------------------
//   The stimulus file is now run through a separate script
//   (remove_comment_lines.py) BEFORE it reaches this testbench, so it no
//   longer contains any "# cycle=..." header lines -- just the raw
//   whitespace-separated hex data, cycle after cycle. Section 7's
//   comment-parsing logic (skip_comment_lines(), the cur_sweep/cur_win/
//   cur_row/cur_col/cur_valid/cur_conv_done/cur_frame_done/cur_header_valid
//   state) has accordingly been removed; read_next_cycle() now just reads
//   hex values directly ($fscanf("%h",...) already skips leading
//   whitespace/newlines on its own, so no comment-skip step is needed).
//   write_cycle_tag() (Section 8) is back to tagging dumps with only the
//   cycle index -- the (row, col) metadata that used to come from those
//   header lines is not available to this testbench anymore. If you need
//   it again for golden-model alignment, keep an un-stripped copy of the
//   stimulus file, or have the preprocessing step save the stripped
//   header fields to a separate sidecar file instead of discarding them.
// =============================================================================

`define SIM
`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// Real Stage-1 BatchNorm parameters (BN1_WEIGHTS / BN1_BIAS), taken from the
// bn_parameters_pkg package embedded in the reference shaaban_adder_tree_top_test.sv
// shipped with the RTL. Populated via task-based per-element assignment
// (rather than a `localparam ... = '{...}` array-literal, which some
// simulators' SystemVerilog front-ends parse unreliably) so this file
// compiles portably across tools.
// -----------------------------------------------------------------------------

module tb_conv_adder_shaaban_top;

    // =========================================================================
    // SECTION 1: Parameters (must mirror the DUT's)
    // =========================================================================
    localparam int DATA_WIDTH     = 18;
    localparam int N_SHAABAN      = 32;
    localparam int MAC_OUT_W      = 40;
    localparam int INPUTS_PER_SHB = 4;
    localparam int N_TREES        = 12;
    localparam int N_TAPS         = 9;
    localparam int N_FILTERS      = 32;   // Stage-1 conv1 filter count
    localparam int KDIM           = 5;    // Stage-1 kernel is 5x5

    // Safety cap in case a much larger (e.g. full 87024-cycle) stimulus file
    // is later substituted in place of the sample file.
    localparam int MAX_CYCLES     = 1_000_000;

    // Real Stage-1 BatchNorm parameters (see task load_bn_parameters below).
    logic signed [DATA_WIDTH-1:0] BN1_BIAS    [0:N_SHAABAN-1];
    logic signed [DATA_WIDTH-1:0] BN1_WEIGHTS [0:N_SHAABAN-1];

    // =========================================================================
    // SECTION 2: DUT signals
    // =========================================================================
    logic clk;
    logic rst;                 // active-low, async (see header note)
    logic [1:0] src_sel;

    logic signed [DATA_WIDTH-1:0] conv_bias_param   [0:N_SHAABAN-1];
    logic signed [DATA_WIDTH-1:0] mult_weight_param [0:N_SHAABAN-1];
    logic signed [DATA_WIDTH-1:0] add_weight_param  [0:N_SHAABAN-1];

    logic signed [DATA_WIDTH-1:0] pixels_mapped  [0:N_TREES-1][0:N_SHAABAN-1][0:N_TAPS-1];
    logic signed [DATA_WIDTH-1:0] weights_mapped [0:N_TREES-1][0:N_SHAABAN-1][0:N_TAPS-1];

    logic [N_SHAABAN-1:0] spike_out;
    logic [0:N_SHAABAN-1] shaaban_spike_bus [0:N_SHAABAN-1];

    // =========================================================================
    // SECTION 3: DUT instantiation
    // =========================================================================
    conv_Adder_shaaban_top #(
        .DATA_WIDTH     (DATA_WIDTH),
        .N_SHAABAN      (N_SHAABAN),
        .MAC_OUT_W      (MAC_OUT_W),
        .INPUTS_PER_SHB (INPUTS_PER_SHB),
        .N_TREES        (N_TREES)
    ) dut (
        .clk               (clk),
        .rst               (rst),
        .src_sel           (src_sel),
        .conv_bias_param   (conv_bias_param),
        .mult_weight_param (mult_weight_param),
        .add_weight_param  (add_weight_param),
        .pixels_mapped     (pixels_mapped),
        .weights_mapped    (weights_mapped),
        .spike_out         (spike_out),
        .shaaban_spike_bus (shaaban_spike_bus)
    );

    // =========================================================================
    // SECTION 3b: Internal-signal probes
    // -------------------------------------------------------------------------
    // None of Bias+ReLU, BatchNorm, MaxPool, or the LIF membrane potential are
    // brought out to top-level ports anywhere in this design, so they can
    // only be observed via hierarchical references into the DUT. Rather than
    // index the generate-created shaban_unit_top instance array with a
    // *runtime* loop variable at every dump call (a pattern some simulators'
    // elaborators reject, since a generate-block instance selector must be
    // constant), this `generate` loop uses the GENVAR itself -- which *is*
    // an elaboration-time constant -- to continuously assign each unit's
    // internal signals into plain flat arrays once. The dump tasks in
    // Section 8 then just read ordinary array elements at runtime.
    // =========================================================================
    logic signed [DATA_WIDTH-1:0] probe_bias_relu  [0:N_SHAABAN-1][0:INPUTS_PER_SHB-1];
    logic signed [DATA_WIDTH-1:0] probe_batch_norm [0:N_SHAABAN-1][0:INPUTS_PER_SHB-1];
    logic signed [DATA_WIDTH-1:0] probe_max_pool   [0:N_SHAABAN-1][0:1];
    logic signed [DATA_WIDTH-1:0] probe_final_pool [0:N_SHAABAN-1];
    logic signed [DATA_WIDTH-1:0] probe_mem_reg    [0:N_SHAABAN-1];

    genvar gs, gi;
    generate
        for (gs = 0; gs < N_SHAABAN; gs++) begin : gen_probe_unit
            for (gi = 0; gi < INPUTS_PER_SHB; gi++) begin : gen_probe_lane
                assign probe_bias_relu[gs][gi] =
                    dut.u_shaaban_adder_tree.u_shaaban_array.gen_shaaban_array[gs].u_shb.conv_bias_relu_out[gi];
                assign probe_batch_norm[gs][gi] =
                    dut.u_shaaban_adder_tree.u_shaaban_array.gen_shaaban_array[gs].u_shb.batch_norm_out[gi];
            end
            assign probe_max_pool[gs][0] =
                dut.u_shaaban_adder_tree.u_shaaban_array.gen_shaaban_array[gs].u_shb.max_pool_out[0];
            assign probe_max_pool[gs][1] =
                dut.u_shaaban_adder_tree.u_shaaban_array.gen_shaaban_array[gs].u_shb.max_pool_out[1];
            assign probe_final_pool[gs] =
                dut.u_shaaban_adder_tree.u_shaaban_array.gen_shaaban_array[gs].u_shb.final_pool_out;
            assign probe_mem_reg[gs] =
                dut.u_shaaban_adder_tree.u_shaaban_array.gen_shaaban_array[gs].u_shb.LIF_ints.mem_reg;
        end
    endgenerate

    // =========================================================================
    // SECTION 4: Clock / Reset generation
    // =========================================================================
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 10ns period, 100MHz

    task automatic apply_reset();
        begin
            rst     = 1'b0;   // arst_n = 0 -> LIF held in reset
            src_sel = 2'b00;  // Stage 1 routing throughout this test
            repeat (5) @(negedge clk);
            rst = 1'b1;       // arst_n = 1 -> release, normal operation begins
            @(negedge clk);
        end
    endtask

    // =========================================================================
    // SECTION 5: Weight loading + Stage-1 weight mapping
    // -------------------------------------------------------------------------
    // filter_w[f][r][c] : raw, un-mapped Stage-1 filter weights, f=0..31,
    //                     r,c = 0..4 (5x5 kernel), decoded from
    //                     w_conv1_weight.bin (32 filters x 5 lines/filter x
    //                     5 packed-18-bit-binary values/line, per its own
    //                     "# shape: [32, 1, 5, 5]" header).
    // =========================================================================
    logic signed [DATA_WIDTH-1:0] filter_w [0:N_FILTERS-1][0:KDIM-1][0:KDIM-1];

    // Fixed-width line buffer for $fgets. Some simulators' $fgets
    // implementation requires a `reg`/`logic` destination rather than a
    // SystemVerilog `string` (confirmed empirically against this project's
    // actual data files -- a `string`-typed $fgets destination was silently
    // rejected at runtime on one tested simulator), so every line-oriented
    // read in this file uses this reg-based approach for portability.
    // 128 bytes comfortably covers the longest line we read here (the
    // 90-character, 5-value weight rows).
    localparam int LINE_BYTES = 128;

    // $fgets right-justifies a short line within a wider reg buffer (i.e.
    // the LAST character read ends up at bits [7:0], not the first). Given
    // `code` = the byte count $fgets returned for that read, this extracts
    // the k-th character (0-indexed from the START of the line) correctly
    // regardless of how many bytes were actually read.
    function automatic byte get_line_char(
        input logic [8*LINE_BYTES-1:0] line_reg,
        input int code,
        input int idx
    );
        get_line_char = line_reg[(code - idx) * 8 - 1 -: 8];
    endfunction

    // Parse an 18-character run of '0'/'1' characters starting at start_idx
    // within a line buffer into a signed 18-bit value (MSB-first). Manual
    // bit-by-bit parsing is required because the weight file packs 5 values
    // per line with NO separating whitespace (90 raw characters/line),
    // which $fscanf("%b") cannot tokenize on its own.
    function automatic logic signed [DATA_WIDTH-1:0] parse_bits18(
        input logic [8*LINE_BYTES-1:0] line_reg,
        input int code,
        input int start_idx
    );
        logic [DATA_WIDTH-1:0] val;
        begin
            for (int k = 0; k < DATA_WIDTH; k++)
                val[DATA_WIDTH-1-k] = (get_line_char(line_reg, code, start_idx + k) == "1");
            parse_bits18 = val; // reinterpreted as signed by the return type
        end
    endfunction

    // Inverse of parse_bits18(): render an 18-bit signed value as the exact
    // packed two's-complement binary string the golden .bin files use
    // (e.g. w_conv1_bias.bin, bn1_out.bin, pool1_out.bin, lif1_out.bin --
    // all "# shape: [...] " files, one 18-char '0'/'1' field per element,
    // no separator). Used by the golden-model-compatible dump tasks in
    // Section 8 so their output can be parsed with the same routine used
    // for the golden files themselves.
    function automatic string bin18(input logic signed [DATA_WIDTH-1:0] val);
        bin18 = $sformatf("%018b", val[DATA_WIDTH-1:0]);
    endfunction

    task automatic load_weights(input string filename);
        integer fh;
        integer code;
        logic [8*LINE_BYTES-1:0] line_reg;
        int     filt, row;
        begin
            fh = $fopen(filename, "r");
            if (fh == 0) begin
                $display("ERROR: could not open weight file '%s'", filename);
                $finish;
            end

            // Skip any leading comment line(s), e.g.
            // "# shape: [32, 1, 5, 5] | lines 160 cols 5" -- read-ahead one
            // line at a time and keep discarding while it starts with '#'.
            code = $fgets(line_reg, fh);
            while (code > 0 && get_line_char(line_reg, code, 0) == "#")
                code = $fgets(line_reg, fh);
            // `line_reg`/`code` now hold the first real (non-comment) data
            // line already read from the file; process it as filter 0,
            // row 0 before continuing the normal read loop below.

            for (filt = 0; filt < N_FILTERS; filt++) begin
                for (row = 0; row < KDIM; row++) begin
                    if (!(filt == 0 && row == 0))
                        code = $fgets(line_reg, fh);
                    // Each data line holds 5 x 18-bit packed values = 90
                    // characters; slice out one 18-char field per column.
                    for (int col = 0; col < KDIM; col++)
                        filter_w[filt][row][col] = parse_bits18(line_reg, code, col * DATA_WIDTH);
                end
            end

            $fclose(fh);
            $display("[%0t] Loaded %0d Stage-1 filters (%0dx%0d each) from '%s'",
                      $time, N_FILTERS, KDIM, KDIM, filename);
        end
    endtask

    // -------------------------------------------------------------------------
    // GLOBAL_CH channel-rotation -- identical rule to the one documented
    // (informational, "unused in pixels_mapped" on the pixel side) inside
    // top_pixel_source_mapper.sv. On the WEIGHT side this rotation is what
    // actually decides which of the 32 real filters a given (gp1,cp1) slot
    // must supply, so it is load-bearing here (unlike on the pixel side,
    // where every cp1 within a BLOCK sees identical pixel data and only the
    // weight differs per filter).
    // -------------------------------------------------------------------------
    function automatic int global_ch(input int block_g, input int lane);
        begin
            case (block_g)
                0: global_ch = (block_g * 32) + lane;
                1: global_ch = (block_g * 32) +
                                 ((lane < 30) ? lane + 1 :
                                  (lane == 30) ? 0 : 31);
                default: global_ch = (block_g * 32) +
                                 ((lane < 30) ? lane + 2 : lane - 30);
            endcase
        end
    endfunction

    // Build weights_mapped[12][32][9] from filter_w[32][5][5].
    //
    //   window   = gp1 / 3           (irrelevant for weights: a filter's
    //                                  kernel does not depend on WHICH of
    //                                  the 4 parallel spatial windows is
    //                                  being processed -- only the pixel
    //                                  side has a window offset)
    //   block_g  = gp1 % 3
    //   gch      = global_ch(block_g, cp1)
    //   filter   = gch % 32           (which of the 32 trained filters)
    //   block    = gch % 3            (which 9-tap slice of that filter's
    //                                  25-weight kernel: 0=taps[0:8],
    //                                  1=taps[9:17], 2=taps[18:24]+2 zero)
    //   slot     = block*9 + tp1      (0..24, same "24-(5*row+col)"
    //                                  packing convention the pixel-side
    //                                  mapping_controller uses)
    //   (row,col)= slot -> 5*row+col = 24-slot
    task automatic build_weights_mapped();
        int window, block_g, gch, filt, block, tap_offset, slot, row, col;
        begin
            for (int gp1 = 0; gp1 < N_TREES; gp1++) begin
                block_g = gp1 % 3;
                for (int cp1 = 0; cp1 < N_SHAABAN; cp1++) begin
                    gch        = global_ch(block_g, cp1);
                    filt       = gch % N_FILTERS;
                    block      = gch % 3;
                    tap_offset = block * 9;
                    for (int tp1 = 0; tp1 < N_TAPS; tp1++) begin
                        if (block == 2 && tp1 >= 7) begin
                            weights_mapped[gp1][cp1][tp1] = '0; // 27->25 zero-pad
                        end else begin
                            slot = tap_offset + tp1;             // 0..24
                            row  = (24 - slot) / 5;
                            col  = (24 - slot) % 5;
                            weights_mapped[gp1][cp1][tp1] = filter_w[filt][row][col];
                        end
                    end
                end
            end
            $display("[%0t] weights_mapped[12][32][9] built from filter_w.", $time);
        end
    endtask

    // =========================================================================
    // SECTION 6: BatchNorm / conv-bias parameter loading (from dataset files)
    // -------------------------------------------------------------------------
    // w_bn1_weight.bin, w_bn1_bias.bin, and w_conv1_bias.bin all share the
    // same on-disk format as the per-line fields of w_conv1_weight.bin: a
    // "# shape: [32] | lines 32 cols 1" header (skipped by the same
    // skip-comment-lines convention as everywhere else in this file),
    // followed by 32 lines of one packed-18-bit-binary value each.
    // =========================================================================
    logic signed [DATA_WIDTH-1:0] conv1_bias_raw [0:N_SHAABAN-1];

    // Three concrete loaders (rather than one generic task taking the target
    // array by `ref`) -- some simulators do not support `ref` arguments with
    // unpacked-array dimensions, so this trades a little repetition for
    // portability. All three files share the identical on-disk layout.
    task automatic load_bn_weight_file(input string filename);
        integer fh;
        integer code;
        logic [8*LINE_BYTES-1:0] line_reg;
        int     i;
        begin
            fh = $fopen(filename, "r");
            if (fh == 0) begin
                $display("ERROR: could not open parameter file '%s'", filename);
                $finish;
            end
            code = $fgets(line_reg, fh);
            while (code > 0 && get_line_char(line_reg, code, 0) == "#")
                code = $fgets(line_reg, fh);
            for (i = 0; i < N_SHAABAN; i++) begin
                if (i != 0) code = $fgets(line_reg, fh);
                BN1_WEIGHTS[i] = parse_bits18(line_reg, code, 0);
            end
            $fclose(fh);
            $display("[%0t] Loaded %0d values from '%s'", $time, N_SHAABAN, filename);
        end
    endtask

    task automatic load_bn_bias_file(input string filename);
        integer fh;
        integer code;
        logic [8*LINE_BYTES-1:0] line_reg;
        int     i;
        begin
            fh = $fopen(filename, "r");
            if (fh == 0) begin
                $display("ERROR: could not open parameter file '%s'", filename);
                $finish;
            end
            code = $fgets(line_reg, fh);
            while (code > 0 && get_line_char(line_reg, code, 0) == "#")
                code = $fgets(line_reg, fh);
            for (i = 0; i < N_SHAABAN; i++) begin
                if (i != 0) code = $fgets(line_reg, fh);
                BN1_BIAS[i] = parse_bits18(line_reg, code, 0);
            end
            $fclose(fh);
            $display("[%0t] Loaded %0d values from '%s'", $time, N_SHAABAN, filename);
        end
    endtask

    task automatic load_conv_bias_file(input string filename);
        integer fh;
        integer code;
        logic [8*LINE_BYTES-1:0] line_reg;
        int     i;
        begin
            fh = $fopen(filename, "r");
            if (fh == 0) begin
                $display("ERROR: could not open parameter file '%s'", filename);
                $finish;
            end
            code = $fgets(line_reg, fh);
            while (code > 0 && get_line_char(line_reg, code, 0) == "#")
                code = $fgets(line_reg, fh);
            for (i = 0; i < N_SHAABAN; i++) begin
                if (i != 0) code = $fgets(line_reg, fh);
                conv1_bias_raw[i] = parse_bits18(line_reg, code, 0);
            end
            $fclose(fh);
            $display("[%0t] Loaded %0d values from '%s'", $time, N_SHAABAN, filename);
        end
    endtask

    task automatic load_bn_parameters(
        input string bn_weight_file,
        input string bn_bias_file,
        input string conv_bias_file
    );
        begin
            load_bn_weight_file(bn_weight_file);
            load_bn_bias_file(bn_bias_file);
            load_conv_bias_file(conv_bias_file);

            for (int i = 0; i < N_SHAABAN; i++) begin
                conv_bias_param[i]   = conv1_bias_raw[i];
                mult_weight_param[i] = BN1_WEIGHTS[i];
                add_weight_param[i]  = BN1_BIAS[i];
            end
            $display("[%0t] BatchNorm parameters (BN1_WEIGHTS/BN1_BIAS) loaded.", $time);
        end
    endtask

    // =========================================================================
    // SECTION 7: Pixel stimulus file reader (Stage-1 conv-array input stream)
    // -------------------------------------------------------------------------
    // Format expected here: PLAIN DATA ONLY, no "# ..." header lines.
    // The Python front-end (rtl_mapping_model.py) still emits "# cycle=...
    // sweep=... win=... row=... col=... valid=... conv_done=... frame_done=..."
    // header lines per cycle, but those are now stripped out of the file
    // BEFORE it reaches this testbench, using remove_comment_lines.py. This
    // testbench therefore no longer parses or expects any '#' lines -- it
    // just reads 3456 whitespace-separated 5-hex-digit values per cycle,
    // back to back, until EOF.
    //
    // NOTE: this means the sweep/win/row/col metadata that used to come
    // from those header lines is NOT available to this testbench anymore,
    // so write_cycle_tag() (Section 8) can only tag dumps with the cycle
    // index, not with (row, col). If you need that metadata for aligning
    // dumps against the golden [C][H][W] tensors again, keep a copy of the
    // un-stripped file around (or have your preprocessing step write the
    // stripped header fields to a separate sidecar file) rather than
    // relying on this testbench to recover it.
    // =========================================================================
    integer pixel_fh;
    integer cycles_loaded;

    task automatic open_pixel_stream(input string filename);
        begin
            pixel_fh = $fopen(filename, "r");
            if (pixel_fh == 0) begin
                $display("ERROR: could not open pixel stimulus file '%s'", filename);
                $finish;
            end
            cycles_loaded = 0;
        end
    endtask

    // Reads exactly one cycle's 3456 hex values into pixels_mapped. Sets
    // success=1 on a fully-read cycle, success=0 on EOF/malformed data (so
    // the caller can stop the stimulus loop). $fscanf's "%h" conversion
    // already skips any leading whitespace/newlines on its own, so no
    // comment-skipping step is needed now that the file is data-only.
    task automatic read_next_cycle(output bit success);
        int     code;
        logic [DATA_WIDTH-1:0] raw;
        begin : read_block
            success = 1;
            if ($feof(pixel_fh)) begin
                success = 0;
                disable read_block;
            end

            for (int gp1 = 0; gp1 < N_TREES; gp1++) begin
                for (int cp1 = 0; cp1 < N_SHAABAN; cp1++) begin
                    for (int tp1 = 0; tp1 < N_TAPS; tp1++) begin
                        code = $fscanf(pixel_fh, "%h", raw);
                        if (code != 1) begin
                            success = 0;
                            disable read_block; // malformed/short file
                        end
                        pixels_mapped[gp1][cp1][tp1] = raw; // bit pattern -> signed reinterpret
                    end
                end
            end
            cycles_loaded++;
        end
    endtask

    // =========================================================================
    // SECTION 8: Output file handles + per-stage dump tasks
    // =========================================================================
    integer f_mac, f_tree, f_bias, f_bn, f_pool, f_mem, f_spike, f_final;

    task automatic open_output_files();
        begin
            f_mac   = $fopen("stage1_mac_outputs.txt",         "w");
            f_tree  = $fopen("stage1_adder_tree_outputs.txt",  "w");
            f_bias  = $fopen("stage1_bias_relu_outputs.txt",   "w");
            f_bn    = $fopen("stage1_batch_norm_outputs.txt",  "w");
            f_pool  = $fopen("stage1_max_pooling_outputs.txt", "w");
            f_mem   = $fopen("stage1_lif_membrane_outputs.txt","w");
            f_spike = $fopen("stage1_lif_spike_outputs.txt",   "w");
            f_final = $fopen("stage1_final_outputs.txt",       "w");

            if (f_mac==0 || f_tree==0 || f_bias==0 || f_bn==0 ||
                f_pool==0 || f_mem==0 || f_spike==0 || f_final==0) begin
                $display("ERROR: could not open one or more output files");
                $finish;
            end

            // Header row for every file: makes each file self-describing
            // for a Python-side comparison script. Every "CYCLE" line
            // within these files now also carries sweep/win/row/col/
            // valid/conv_done/frame_done metadata (see write_cycle_tag,
            // parsed from the pixel stream's own header by
            // skip_comment_lines) so a comparison script can map a given
            // cycle onto the correct (row, col) element of the golden
            // [C][H][W] .bin tensors.
            $fwrite(f_mac,   "# tree,lane -> mac_to_connect[12][32], row-major (tree0 lane0..31, tree1 lane0..31, ...)\n");
            $fwrite(f_tree,  "# tree_tap[12][10] (row-major) | tree_final[12] | ext_sum_correction[8] | s3_results[4] | shb_conv_bus[32] (4x18b packed hex each)\n");
            $fwrite(f_bias,  "# shaaban_unit[32] x conv_bias_relu_out[4], row-major\n");
            // bn1_out.bin golden format: "# shape: [32,256,256] | lines
            // 8192 cols 256", one packed-18-bit-two's-complement-binary
            // field per element, no separator. Each line below now ALSO
            // carries, per shaaban unit, the 4 lane values re-encoded that
            // same way (bin18(), Section 5) immediately after the original
            // decimal fields, so this file can be diffed against
            // bn1_out.bin element-for-element using the same bit-parsing
            // routine (parse_bits18-style) on both sides.
            $fwrite(f_bn,    "# shaaban_unit[32] x batch_norm_out[4], row-major | decimal fields, then bin18(value) fields matching bn1_out.bin's packed-18-bit-binary encoding\n");
            // pool1_out.bin golden format: "# shape: [32,128,128] | lines
            // 4096 cols 128", same packed-18-bit-binary encoding, and
            // corresponds to final_pool_out specifically (post-maxpool,
            // pre-LIF) -- NOT the two intermediate max_pool_out lanes.
            $fwrite(f_pool,  "# shaaban_unit[32] x (max_pool_out[2], final_pool_out[1]), row-major | trailing bin18(final_pool_out) field matches pool1_out.bin's packed-18-bit-binary encoding\n");
            $fwrite(f_mem,   "# shaaban_unit[32] x LIF mem_reg (post-update membrane potential)\n");
            // lif1_out.bin golden format: "# shape: [32,128,128] | lines
            // 4096 cols 128", spike value (0/1) stored in the same
            // packed-18-bit-binary field width as every other golden
            // tensor.
            $fwrite(f_spike, "# shaaban_unit[32] x LIF spike bit | decimal field, then bin18(spike) field matching lif1_out.bin's packed-18-bit-binary encoding\n");
            $fwrite(f_final, "# Stage-1 final spike_out[31:0]: 32-bit binary vector, then per-neuron listing\n");
        end
    endtask

    task automatic close_output_files();
        begin
            $fclose(f_mac);
            $fclose(f_tree);
            $fclose(f_bias);
            $fclose(f_bn);
            $fclose(f_pool);
            $fclose(f_mem);
            $fclose(f_spike);
            $fclose(f_final);
        end
    endtask

    // GOLDEN-MODEL COMPATIBILITY UPDATE: the cycle tag now also carries the
    // sweep/win/row/col/valid/conv_done/frame_done metadata parsed from the
    // pixel stream's header line for THIS cycle (see skip_comment_lines,
    // Section 7). This is what an external Python comparison script needs
    // to map a cycle's dumped values onto the correct (row, col) element of
    // the golden [C][H][W] bn1_out.bin/pool1_out.bin/lif1_out.bin tensors.
    // If the source header didn't parse for this cycle (cur_header_valid
    // == 0, e.g. a legacy/malformed stimulus file), row/col are written as
    // -1 so the mismatch is visible rather than silently defaulting to 0,0.
    // Cycle tag only carries the cycle index now -- the sweep/win/row/col/
    // valid/conv_done/frame_done metadata that used to come from the
    // stimulus file's "# cycle=..." header lines is gone now that those
    // lines are stripped out upstream (see Section 7 note).
    task automatic write_cycle_tag(input integer fd, input int cyc);
        begin
            $fwrite(fd, "CYCLE %0d\n", cyc);
        end
    endtask

    // ---- Conv (MAC) outputs -------------------------------------------------
    task automatic dump_mac(input int cyc);
        begin
            write_cycle_tag(f_mac, cyc);
            for (int g = 0; g < N_TREES; g++) begin
                for (int c = 0; c < N_SHAABAN; c++)
                    $fwrite(f_mac, "%0d ", dut.mac_to_connect[g][c]);
                $fwrite(f_mac, "\n");
            end
        end
    endtask

    // ---- Adder Tree outputs -------------------------------------------------
    task automatic dump_adder_tree(input int cyc);
        begin
            write_cycle_tag(f_tree, cyc);

            $fwrite(f_tree, "TREE_TAP\n");
            for (int t = 0; t < N_TREES; t++) begin
                for (int k = 0; k < 10; k++)
                    $fwrite(f_tree, "%0d ", dut.u_shaaban_adder_tree.u_connect.tree_tap[t][k]);
                $fwrite(f_tree, "\n");
            end

            $fwrite(f_tree, "TREE_FINAL\n");
            for (int t = 0; t < N_TREES; t++)
                $fwrite(f_tree, "%0d ", dut.u_shaaban_adder_tree.u_connect.tree_final[t]);
            $fwrite(f_tree, "\n");

            $fwrite(f_tree, "EXT_SUM_CORRECTION\n");
            for (int c = 0; c < 8; c++)
                $fwrite(f_tree, "%0d ", dut.u_shaaban_adder_tree.u_connect.ext_sum_correction[c]);
            $fwrite(f_tree, "\n");

            $fwrite(f_tree, "S3_RESULTS\n");
            for (int i = 0; i < 4; i++)
                $fwrite(f_tree, "%0d ", dut.u_shaaban_adder_tree.u_connect.s3_results[i]);
            $fwrite(f_tree, "\n");

            $fwrite(f_tree, "SHB_CONV_BUS\n");
            for (int s = 0; s < N_SHAABAN; s++)
                $fwrite(f_tree, "%h ", dut.u_shaaban_adder_tree.shb_bus[s]);
            $fwrite(f_tree, "\n");
        end
    endtask

    // ---- Bias + ReLU outputs (per Shaaban unit, 4 lanes each) ---------------
    task automatic dump_bias_relu(input int cyc);
        begin
            write_cycle_tag(f_bias, cyc);
            for (int s = 0; s < N_SHAABAN; s++) begin
                for (int i = 0; i < INPUTS_PER_SHB; i++)
                    $fwrite(f_bias, "%0d ", probe_bias_relu[s][i]);
                $fwrite(f_bias, "\n");
            end
        end
    endtask

    // ---- BatchNorm outputs (per Shaaban unit, 4 lanes each) -----------------
    task automatic dump_batch_norm(input int cyc);
        begin
            write_cycle_tag(f_bn, cyc);
            for (int s = 0; s < N_SHAABAN; s++) begin
                // Original decimal fields, unchanged, for readability /
                // any existing tooling that already parses this file.
                for (int i = 0; i < INPUTS_PER_SHB; i++)
                    $fwrite(f_bn, "%0d ", probe_batch_norm[s][i]);
                // Golden-model-compatible fields: same 4 values re-encoded
                // as packed 18-bit two's-complement binary strings, i.e.
                // bn1_out.bin's own on-disk element encoding.
                for (int i = 0; i < INPUTS_PER_SHB; i++)
                    $fwrite(f_bn, "%s", bin18(probe_batch_norm[s][i]));
                $fwrite(f_bn, "\n");
            end
        end
    endtask

    // ---- MaxPool outputs (2 first-level + 1 final, per Shaaban unit) --------
    task automatic dump_max_pooling(input int cyc);
        begin
            write_cycle_tag(f_pool, cyc);
            for (int s = 0; s < N_SHAABAN; s++) begin
                // Original decimal fields, unchanged. Only final_pool_out
                // (the 3rd field) has a golden-model counterpart --
                // pool1_out.bin -- so only it gets a trailing bin18 field.
                $fwrite(f_pool, "%0d %0d %0d %s\n",
                    probe_max_pool[s][0],
                    probe_max_pool[s][1],
                    probe_final_pool[s],
                    bin18(probe_final_pool[s]));
            end
        end
    endtask

    // ---- LIF membrane potential (post-update, "if accessible") -------------
    task automatic dump_lif_membrane(input int cyc);
        begin
            write_cycle_tag(f_mem, cyc);
            for (int s = 0; s < N_SHAABAN; s++)
                $fwrite(f_mem, "%0d ", probe_mem_reg[s]);
            $fwrite(f_mem, "\n");
        end
    endtask

    // ---- LIF spike outputs ---------------------------------------------------
    task automatic dump_lif_spike(input int cyc);
        begin
            write_cycle_tag(f_spike, cyc);
            for (int s = 0; s < N_SHAABAN; s++)
                // Decimal field (unchanged) followed by the golden-model-
                // compatible field: the single spike bit widened to the
                // full 18-bit signed field and re-encoded as a packed
                // two's-complement binary string, matching lif1_out.bin's
                // own on-disk element encoding.
                $fwrite(f_spike, "%0d %s ", spike_out[s],
                        bin18({{(DATA_WIDTH-1){1'b0}}, spike_out[s]}));
            $fwrite(f_spike, "\n");
        end
    endtask

    // ---- Final Stage-1 output (same data as LIF spikes, packaged as the
    //      pipeline's actual final result) -----------------------------------
    task automatic dump_final(input int cyc);
        begin
            write_cycle_tag(f_final, cyc);
            $fwrite(f_final, "%032b\n", spike_out);
            for (int s = 0; s < N_SHAABAN; s++)
                $fwrite(f_final, "neuron[%0d]=%0b\n", s, spike_out[s]);
        end
    endtask

    task automatic dump_all_stages(input int cyc);
        begin
            dump_mac(cyc);
            dump_adder_tree(cyc);
            dump_bias_relu(cyc);
            dump_batch_norm(cyc);
            dump_max_pooling(cyc);
            dump_lif_membrane(cyc);
            dump_lif_spike(cyc);
            dump_final(cyc);
        end
    endtask

    // =========================================================================
    // SECTION 9: Main stimulus
    // =========================================================================
    initial begin
        // NOTE: adjust these paths to wherever your files actually live.
        // All five come from Data_Set.zip except PIXELS_FILE, which is the
        // Python-front-end-generated, already-RTL-mapped stimulus file (see
        // below for why input_t0.bin itself isn't read directly here).
        string WEIGHTS_FILE;
        string BN_WEIGHT_FILE;
        string BN_BIAS_FILE;
        string CONV_BIAS_FILE;
        string PIXELS_FILE;
        WEIGHTS_FILE   = "w_conv1_weight.bin";
        BN_WEIGHT_FILE = "w_bn1_weight.bin";
        BN_BIAS_FILE   = "w_bn1_bias.bin";
        CONV_BIAS_FILE = "w_conv1_bias.bin";
        PIXELS_FILE    = "stage1_conv_array_input_t0_FULL.txt";

        // NOTE ON input_t0.bin: this is the raw 256x256 image, not something
        // this testbench reads directly. This DUT (conv_Adder_shaaban_top)
        // starts at pixels_mapped/weights_mapped -- it does not include
        // mapping_controller or top_pixel_source_mapper (neither is part of
        // this RTL.zip), so there is no RTL in this integration test to turn
        // a raw image into conv windows. PIXELS_FILE is the already-mapped,
        // cycle-by-cycle pixels_mapped[12][32][9] stream that rtl_mapping_model.py
        // produces FROM input_t0.bin; that Python model is the front-end
        // stage, this testbench is the back-end stage, and they meet at
        // exactly the pixels_mapped boundary.

        // ---- Elaboration-time setup (weights/BN are static for Stage 1) ----
        load_weights(WEIGHTS_FILE);
        build_weights_mapped();
        load_bn_parameters(BN_WEIGHT_FILE, BN_BIAS_FILE, CONV_BIAS_FILE);

        // Pixels start at all-zero until the first real cycle is loaded.
        foreach (pixels_mapped[g,c,t]) pixels_mapped[g][c][t] = '0;

        open_output_files();
        open_pixel_stream(PIXELS_FILE);

        apply_reset();

        // ---- Drive one pixels_mapped tensor per clock, capture every stage --
        begin : stimulus_loop
            int cyc;
            bit ok;
            cyc = 0;
            while (cyc < MAX_CYCLES) begin
                read_next_cycle(ok);
                if (!ok) disable stimulus_loop; // EOF reached

                // pixels_mapped for this cycle is now loaded; weights_mapped
                // and src_sel are already stable from setup above.
                @(negedge clk); // one clock: the DUT's only register (LIF)
                                // updates on the intervening posedge, and by
                                // this negedge every combinational stage plus
                                // the freshly-updated membrane state are
                                // simultaneously valid (see header note).

                dump_all_stages(cyc);
                cyc++;
            end
            $display("[%0t] Processed %0d cycle(s) from '%s'.", $time, cyc, PIXELS_FILE);
        end

        close_output_files();
        $fclose(pixel_fh);
        $display("[%0t] Simulation complete.", $time);
        $finish;
    end

    // =========================================================================
    // SECTION 10: Live monitor (console visibility only, not file output)
    // =========================================================================
    initial begin
        $monitor("[%0t] rst=%0b src_sel=%0b spike_out=%h",
                 $time, rst, src_sel, spike_out);
    end

endmodule