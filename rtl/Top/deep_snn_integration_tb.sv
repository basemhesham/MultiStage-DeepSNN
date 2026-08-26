`timescale 1ns/1ns

module deep_snn_integration_tb;

    localparam int DATA_WIDTH       = 18;
    localparam int PIXEL_W          = 18;
    localparam int CLK_PERIOD       = 10;
    localparam int FRAGMENT_ROWS    = 2;
    localparam int FRAGMENT_COLS    = 2;
    localparam int FRAGMENTS_MAX    = 4;
    localparam int TEMPORAL_FRAMES  = 1;
    localparam int STAGE1_POSITIONS = 81;
    localparam int STAGE2_CYCLES    = 64 * 6;
    localparam int STAGE3_CYCLES    = 128;
    localparam int MAX_CYCLES       = 3000;

    logic clk;
    logic rst;
    logic arst_n;
    logic enable;

    logic                         pixel_mem_wr_en;
    logic [5:0]                   pixel_mem_wr_addr;
    logic [(384*PIXEL_W)-1:0]     pixel_mem_wr_data;
    logic                         sim_pixels_override;
    logic [(12*32*9*PIXEL_W)-1:0] sim_pixels;
    logic                         sim_pixel_mem_override;
    logic [(384*PIXEL_W)-1:0]     sim_pixel_mem_data;

    logic [31:0]                  spike_out;
    logic [(4*DATA_WIDTH)-1:0]    class_logits;
    logic                         classifier_done;
    logic                         classifier_busy;
    logic                         snn_done;
    logic                         done;

    logic signed [259:0][DATA_WIDTH-1:0] input_image [0:259];

    logic signed [DATA_WIDTH-1:0] ref_mac [0:11][0:31];
    logic signed [DATA_WIDTH-1:0] ref_tree [0:11];
    logic signed [DATA_WIDTH-1:0] ref_tree_tap [0:11][0:9];
    logic signed [DATA_WIDTH-1:0] ref_correction [0:7];
    logic signed [DATA_WIDTH-1:0] ref_flat_s1 [0:127];
    logic signed [DATA_WIDTH-1:0] ref_shb [0:31][0:3];
    logic signed [DATA_WIDTH-1:0] ref_pool [0:31];
    logic signed [DATA_WIDTH-1:0] actual_pool [0:31];
    logic signed [DATA_WIDTH-1:0] lif_mem [0:31];
    logic                         lif_spike_reg [0:31];
    logic signed [DATA_WIDTH-1:0] lif_next_mem [0:31];
    logic                         lif_next_spike [0:31];

    logic [3199:0] expected_mem [0:2];
    logic [3199:0] expected_rd_data;
    logic [3199:0] expected_write_shadow;
    logic [5:0]    expected_active_write_address;
    logic          expected_active_write_valid;
    logic [2:0]    initialized_address;

    int checked_cycles;
    int failed_counter;
    int stage1_cycles;
    int stage2_cycles;
    int stage3_cycles;
    int clear_cycles;

    always #(CLK_PERIOD/2) clk = ~clk;

    function automatic logic signed [DATA_WIDTH-1:0] trunc18(
        input longint signed value
    );
        trunc18 = value[DATA_WIDTH-1:0];
    endfunction

    function automatic int fragment_row(input int fragment);
        fragment_row = fragment / FRAGMENT_COLS;
    endfunction

    function automatic int fragment_col(input int fragment);
        fragment_col = fragment % FRAGMENT_COLS;
    endfunction

    function automatic logic [0:3199] expected_stage1_mask(
        input int fragment,
        input int position
    );
        logic [0:3199] mask;
        int row_start;
        int col_start;
        int local_row;
        int local_col;
        int base;
        begin
            mask = '0;
            row_start = (fragment_row(fragment) == 0) ? 1 : 0;
            col_start = (fragment_col(fragment) == 0) ? 1 : 0;
            local_row = row_start + (position / 9);
            local_col = col_start + (position % 9);
            base = ((local_row * 10) + local_col) * 32;
            mask[base +: 32] = '1;
            expected_stage1_mask = mask;
        end
    endfunction

    function automatic bit stage2_position_valid(
        input int fragment,
        input int position
    );
        int local_row;
        int local_col;
        begin
            local_row = position / 4;
            local_col = position % 4;
            stage2_position_valid =
                !(((fragment_row(fragment) == 0) && (local_row == 0)) ||
                  ((fragment_row(fragment) == FRAGMENT_ROWS - 1) &&
                   (local_row == 3)) ||
                  ((fragment_col(fragment) == 0) && (local_col == 0)) ||
                  ((fragment_col(fragment) == FRAGMENT_COLS - 1) &&
                   (local_col == 3)));
        end
    endfunction

    function automatic logic [0:3199] expected_stage2_mask(
        input int fragment,
        input int filter_index,
        input int frame_index
    );
        logic [0:3199] mask;
        int first_position;
        int positions_in_frame;
        int position;
        begin
            mask = '0;
            first_position = frame_index * 3;
            positions_in_frame = (frame_index == 5) ? 1 : 3;

            for (int lane = 0; lane < 3; lane++) begin
                if (lane < positions_in_frame) begin
                    position = first_position + lane;
                    if (stage2_position_valid(fragment, position))
                        mask[(filter_index * 16) + position] = 1'b1;
                end
            end

            expected_stage2_mask = mask;
        end
    endfunction

    task automatic load_stage1_patch;
        int fragment;
        int position;
        int source_row;
        int source_col;
        int fragment_base_row;
        int fragment_base_col;
        begin
            sim_pixel_mem_data = '0;

            if (DUT.src_sel == 2'b00) begin
                fragment = DUT.u_top_controller.fragment_counter;
                position = DUT.u_top_controller.stage1_pos;
                fragment_base_row = fragment_row(fragment) * 9;
                fragment_base_col = fragment_col(fragment) * 9;
                source_row = (fragment_base_row + (position / 9)) * 2;
                source_col = (fragment_base_col + (position % 9)) * 2;

                for (int patch_row = 0; patch_row < 6; patch_row++) begin
                    for (int patch_col = 0; patch_col < 6; patch_col++) begin
                        sim_pixel_mem_data[
                            ((patch_row * 6 + patch_col) * PIXEL_W)
                            +: PIXEL_W
                        ] = input_image[source_row + patch_row]
                                             [source_col + patch_col];
                    end
                end
            end
        end
    endtask

    task automatic record_failure(input string message);
        begin
            if (failed_counter < 20)
                $display("Mismatch cycle=%0d stage=%0b: %s",
                         checked_cycles, DUT.src_sel, message);
            failed_counter++;
        end
    endtask

    task automatic check_controller;
        logic [0:3199] expected_mask;
        int fragment;
        int position;
        int frame_index;
        begin
            fragment = DUT.u_top_controller.fragment_counter;

            case (DUT.src_sel)
                2'b00: begin
                    position = DUT.u_top_controller.stage1_pos;
                    expected_mask = expected_stage1_mask(fragment, position);
                    stage1_cycles++;

                    if ((DUT.ctrl_mem_enable !== expected_mask) ||
                        (DUT.ctrl_wr_mem_adderss != 0) ||
                        DUT.ctrl_zero_sel)
                        record_failure("Stage1 controller outputs");
                end

                2'b01: begin
                    frame_index = DUT.frame - 1;
                    expected_mask = expected_stage2_mask(
                        fragment,
                        DUT.conv2_filter,
                        frame_index
                    );
                    stage2_cycles++;

                    if ((DUT.ctrl_mem_enable !== expected_mask) ||
                        !DUT.ctrl_rd_enable ||
                        (DUT.ctrl_wr_mem_adderss != 1) ||
                        (DUT.frame != frame_index + 1))
                        record_failure("Stage2 controller outputs");
                end

                2'b10: begin
                    expected_mask = '0;
                    expected_mask[DUT.conv3_filter] = 1'b1;
                    stage3_cycles++;

                    if ((DUT.ctrl_mem_enable !== expected_mask) ||
                        !DUT.ctrl_rd_enable ||
                        (DUT.ctrl_rd_mem_adderss != 1) ||
                        (DUT.ctrl_wr_mem_adderss != 2))
                        record_failure("Stage3 controller outputs");

                    if (DUT.spike_mem_wr_data[DUT.conv3_filter] !==
                        spike_out[0])
                        record_failure("Stage3 spike writeback lane");
                end

                default: begin
                    if (DUT.ctrl_padding_flag) begin
                        clear_cycles++;
                        if ((DUT.ctrl_mem_enable !== '1) ||
                            !DUT.ctrl_zero_sel)
                            record_failure("Controller clear cycle");
                    end
                end
            endcase
        end
    endtask

    task automatic calculate_reference_datapath;
        longint signed accumulator;
        longint signed bn_accumulator;
        logic signed [DATA_WIDTH-1:0] conv_value;
        logic signed [DATA_WIDTH-1:0] relu_value;
        logic signed [DATA_WIDTH-1:0] bn_value;
        logic signed [DATA_WIDTH-1:0] max_value;
        logic signed [DATA_WIDTH-1:0] add_truncated;
        logic [0:3199] unused_mask;
        int global_extra;
        int tree_index;
        int channel_index;
        begin
            for (int group = 0; group < 12; group++) begin
                for (int channel = 0; channel < 32; channel++) begin
                    accumulator = 0;
                    for (int tap = 0; tap < 9; tap++) begin
                        accumulator +=
                            $signed(DUT.pixels_to_conv[group][channel][tap]) *
                            $signed(DUT.weights_mapped[group][channel][tap]);
                    end
                    ref_mac[group][channel] = trunc18(accumulator >>> 9);

                    if (DUT.mac_to_connect[group][channel] !==
                        ref_mac[group][channel])
                        record_failure("conv9 MAC result");
                end

                accumulator = 0;
                for (int channel = 0; channel < 32; channel++)
                    accumulator += $signed(ref_mac[group][channel]);
                ref_tree[group] = trunc18(accumulator);

                for (int tap_group = 0; tap_group < 10; tap_group++) begin
                    accumulator = 0;
                    for (int lane = 0; lane < 3; lane++)
                        accumulator +=
                            $signed(ref_mac[group][(tap_group * 3) + lane]);
                    ref_tree_tap[group][tap_group] = trunc18(accumulator);
                end
            end

            for (int correction = 0; correction < 8; correction++) begin
                accumulator = 0;
                for (int lane = 0; lane < 3; lane++) begin
                    global_extra = (correction * 3) + lane;
                    tree_index = global_extra / 2;
                    channel_index = 30 + (global_extra % 2);
                    accumulator +=
                        $signed(ref_mac[tree_index][channel_index]);
                end
                ref_correction[correction] = trunc18(accumulator);
            end

            for (int group = 0; group < 4; group++) begin
                for (int tap_group = 0; tap_group < 10; tap_group++) begin
                    ref_flat_s1[(group * 32) + tap_group] =
                        ref_tree_tap[group * 3][tap_group];
                    ref_flat_s1[(group * 32) + 11 + tap_group] =
                        ref_tree_tap[(group * 3) + 1][tap_group];
                    ref_flat_s1[(group * 32) + 22 + tap_group] =
                        ref_tree_tap[(group * 3) + 2][tap_group];
                end
                ref_flat_s1[(group * 32) + 10] =
                    ref_correction[group * 2];
                ref_flat_s1[(group * 32) + 21] =
                    ref_correction[(group * 2) + 1];
            end

            for (int shb = 0; shb < 32; shb++) begin
                for (int slot = 0; slot < 4; slot++) begin
                    case (DUT.src_sel)
                        2'b00:
                            ref_shb[shb][slot] =
                                ref_flat_s1[(shb * 4) + slot];
                        2'b01:
                            ref_shb[shb][slot] =
                                (shb < 3) ?
                                ref_tree[(shb * 4) + slot] : '0;
                        2'b10:
                            ref_shb[shb][slot] =
                                (shb == 0) ?
                                trunc18(
                                    $signed(ref_tree[slot * 2]) +
                                    $signed(ref_tree[(slot * 2) + 1])
                                ) : '0;
                        default:
                            ref_shb[shb][slot] = '0;
                    endcase

                    if ($signed(DUT.shb_bus[shb][
                            slot*DATA_WIDTH +: DATA_WIDTH
                        ]) !== ref_shb[shb][slot])
                        record_failure("adder-tree/Shaaban routing");
                end

                max_value = '0;
                for (int slot = 0; slot < 4; slot++) begin
                    accumulator =
                        $signed(ref_shb[shb][slot]) +
                        $signed(DUT.conv_bias_param[shb]);
                    conv_value = trunc18(accumulator);
                    relu_value = (accumulator > 0) ? conv_value : '0;
                    bn_accumulator =
                        ($signed(relu_value) *
                         $signed(DUT.mult_weight_param[shb])) +
                        ($signed(DUT.add_weight_param[shb]) <<< 9);
                    bn_value = trunc18(bn_accumulator >>> 9);

                    if ((slot == 0) ||
                        ($signed(bn_value) > $signed(max_value)))
                        max_value = bn_value;
                end
                ref_pool[shb] = max_value;

                if (actual_pool[shb] !== ref_pool[shb])
                    record_failure("BatchNorm/max-pool result");

                add_truncated = trunc18(
                    ($signed(lif_mem[shb]) >>> 1) +
                    $signed(ref_pool[shb])
                );
                lif_next_mem[shb] = trunc18(
                    $signed(add_truncated) -
                    (lif_spike_reg[shb] ? 18'sd512 : 18'sd0)
                );
                lif_next_spike[shb] =
                    ($signed(lif_next_mem[shb]) >= 18'sd512);

                if (spike_out[shb] !== lif_next_spike[shb])
                    record_failure("LIF spike result");
            end
        end
    endtask

    task automatic check_stage_input_scaling;
        begin
            if ((DUT.src_sel == 2'b01) || (DUT.src_sel == 2'b10)) begin
                for (int group = 0; group < 12; group++) begin
                    for (int channel = 0; channel < 32; channel++) begin
                        for (int tap = 0; tap < 9; tap++) begin
                            if ((DUT.pixels_to_conv[group][channel][tap] !== 18'sd0) &&
                                (DUT.pixels_to_conv[group][channel][tap] !== 18'sd512))
                                record_failure("inter-stage spike Q8.9 conversion");
                        end
                    end
                end
            end
        end
    endtask

    initial begin
        clk                    = 1'b0;
        rst                    = 1'b1;
        arst_n                 = 1'b0;
        enable                 = 1'b0;
        pixel_mem_wr_en        = 1'b0;
        pixel_mem_wr_addr      = '0;
        pixel_mem_wr_data      = '0;
        sim_pixels_override    = 1'b0;
        sim_pixels             = '0;
        sim_pixel_mem_override = 1'b1;
        sim_pixel_mem_data     = '0;
        expected_mem[0]        = '0;
        expected_mem[1]        = '0;
        expected_mem[2]        = '0;
        expected_rd_data       = '0;
        expected_write_shadow  = '0;
        expected_active_write_address = '0;
        expected_active_write_valid = 1'b0;
        initialized_address    = '0;
        checked_cycles         = 0;
        failed_counter         = 0;
        stage1_cycles          = 0;
        stage2_cycles          = 0;
        stage3_cycles          = 0;
        clear_cycles           = 0;

        for (int shb = 0; shb < 32; shb++) begin
            lif_mem[shb]       = '0;
            lif_spike_reg[shb] = 1'b0;
        end

        $readmemb("bin_export/input/input_t0.txt", input_image);

        repeat (3) @(posedge clk);
        arst_n = 1'b1;
        rst    = 1'b0;
        @(negedge clk);
        enable = 1'b1;

        for (int cycle = 0; cycle < MAX_CYCLES; cycle++) begin
            @(negedge clk);
            load_stage1_patch();
            #1;

            if (snn_done)
                break;

            check_controller();
            check_stage_input_scaling();
            calculate_reference_datapath();
            checked_cycles++;

            @(posedge clk);
            begin
                logic write_enable;
                logic zero_select;
                logic [5:0] write_address;
                logic [5:0] read_address;
                logic [0:3199] write_mask;
                logic [3199:0] write_data;
                logic [3199:0] next_write_word;
                logic read_was_initialized;

                write_enable = DUT.spike_mem_wr_en;
                zero_select  = DUT.ctrl_zero_sel;
                write_address = DUT.ctrl_wr_mem_adderss;
                read_address  = DUT.ctrl_rd_mem_adderss;
                write_mask    = DUT.ctrl_mem_enable;
                write_data    = DUT.spike_mem_wr_data;

                expected_rd_data = expected_mem[read_address];
                read_was_initialized =
                    (read_address < 3) &&
                    initialized_address[read_address];

                if (write_enable) begin
                    if (expected_active_write_valid &&
                        (expected_active_write_address == write_address))
                        next_write_word = expected_write_shadow;
                    else
                        next_write_word = '0;

                    for (int bit_index = 0;
                         bit_index < 3200;
                         bit_index++) begin
                        if (write_mask[bit_index])
                            next_write_word[bit_index] =
                                zero_select ? 1'b0 : write_data[bit_index];
                    end

                    expected_mem[write_address] = next_write_word;
                    expected_write_shadow = next_write_word;
                    expected_active_write_address = write_address;
                    expected_active_write_valid = 1'b1;
                    if (write_address < 3)
                        initialized_address[write_address] = 1'b1;
                end

                for (int shb = 0; shb < 32; shb++) begin
                    lif_mem[shb]       = lif_next_mem[shb];
                    lif_spike_reg[shb] = lif_next_spike[shb];
                end

                #1;
                if (read_was_initialized &&
                    (DUT.spike_mem_data !== expected_rd_data))
                    record_failure("spike RAM synchronous read");

                if (write_enable &&
                    (DUT.u_spike_mem.mem[write_address] !==
                     expected_mem[write_address]))
                    record_failure("spike RAM writeback");
            end
        end

        if (!snn_done)
            $fatal(1, "Integration test timed out before controller done");

        if (stage1_cycles != FRAGMENTS_MAX * STAGE1_POSITIONS)
            record_failure("Stage1 controller cycle count");
        if (stage2_cycles != FRAGMENTS_MAX * STAGE2_CYCLES)
            record_failure("Stage2 controller cycle count");
        if (stage3_cycles != FRAGMENTS_MAX * STAGE3_CYCLES)
            record_failure("Stage3 controller cycle count");
        if (clear_cycles != FRAGMENTS_MAX * 2)
            record_failure("controller clear cycle count");

        $display("------------------------------------------------------------");
        $display("Checked integrated cycles = %0d", checked_cycles);
        $display("Stage1 cycles             = %0d", stage1_cycles);
        $display("Stage2 cycles             = %0d", stage2_cycles);
        $display("Stage3 cycles             = %0d", stage3_cycles);
        $display("Total mismatches          = %0d", failed_counter);

        if (failed_counter != 0)
            $fatal(1, "Integrated Stage1/Stage2/Stage3 verification failed");

        $display(
            "PASS: controller, shared memories, and all three stages work together with no mismatches."
        );
        $finish;
    end

    deep_snn_top #(
        .CTRL_FRAGMENT_ROWS   (FRAGMENT_ROWS),
        .CTRL_FRAGMENT_COLS   (FRAGMENT_COLS),
        .CTRL_FRAGMENTS_MAX   (FRAGMENTS_MAX),
        .CTRL_TEMPORAL_FRAMES (TEMPORAL_FRAMES)
    ) DUT (
        .clk                    (clk),
        .rst                    (rst),
        .arst_n                 (arst_n),
        .enable                 (enable),
        .pixel_mem_wr_en        (pixel_mem_wr_en),
        .pixel_mem_wr_addr      (pixel_mem_wr_addr),
        .pixel_mem_wr_data      (pixel_mem_wr_data),
        .sim_pixels_override    (sim_pixels_override),
        .sim_pixels             (sim_pixels),
        .sim_pixel_mem_override (sim_pixel_mem_override),
        .sim_pixel_mem_data     (sim_pixel_mem_data),
        .spike_out              (spike_out),
        .class_logits           (class_logits),
        .classifier_done        (classifier_done),
        .classifier_busy        (classifier_busy),
        .snn_done               (snn_done),
        .done                   (done)
    );

    genvar observer;
    generate
        for (observer = 0; observer < 32; observer++) begin : gen_pool_observer
            assign actual_pool[observer] =
                DUT.u_shaaban_array.gen_shaaban_array[observer]
                    .u_shb.final_pool_out;
        end
    endgenerate

endmodule
