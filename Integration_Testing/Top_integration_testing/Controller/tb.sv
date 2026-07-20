module tb;

    localparam int FRAGMENT_ROWS   = 13;
    localparam int FRAGMENT_COLS   = 13;
    localparam int FRAGMENTS_MAX   = FRAGMENT_ROWS * FRAGMENT_COLS;
    localparam int TEMPORAL_FRAMES = 1;
    localparam int STAGE1_SIDE     = 10;
    localparam int STAGE1_CHANNELS = 32;
    localparam int STAGE2_SIDE     = 4;
    localparam int STAGE2_FRAMES   = 6;
    localparam int STAGE2_FILTERS  = 64;
    localparam int STAGE3_FILTERS  = 128;
    localparam int MAX_CYCLES      = 150000;

    logic clk;
    logic rst;
    logic arst_n;
    logic enable;

    logic [0:3199] mem_enable;
    logic          rd_enable;
    logic [1:0]    stage;
    logic [2:0]    frame;
    logic          stage_sel;
    logic [5:0]    conv2_filter;
    logic [6:0]    conv3_filter;
    logic [5:0]    rd_mem_adderss;
    logic [5:0]    wr_mem_adderss;
    logic          zero;
    logic          zero_sel;
    logic          padding_flag;
    logic          gap_valid;
    logic          done;

    int checks;

    bit saw_stage1_top_left;
    bit saw_stage1_middle;
    bit saw_stage1_left_edge;
    bit saw_stage1_top_right;
    bit saw_stage1_bottom_right;
    bit saw_stage2_top_left_empty;
    bit saw_stage2_top_left_one_valid;
    bit saw_stage2_middle;
    bit saw_stage2_bottom_right;
    bit saw_done;

    top_controller #(
        .FRAGMENT_ROWS   (FRAGMENT_ROWS),
        .FRAGMENT_COLS   (FRAGMENT_COLS),
        .FRAGMENTS_MAX   (FRAGMENTS_MAX),
        .TEMPORAL_FRAMES (TEMPORAL_FRAMES)
    ) dut (
        .clk             (clk),
        .rst             (rst),
        .arst_n          (arst_n),
        .enable          (enable),
        .mem_enable      (mem_enable),
        .rd_enable       (rd_enable),
        .stage           (stage),
        .frame           (frame),
        .stage_sel       (stage_sel),
        .conv2_filter    (conv2_filter),
        .conv3_filter    (conv3_filter),
        .rd_mem_adderss  (rd_mem_adderss),
        .wr_mem_adderss  (wr_mem_adderss),
        .zero            (zero),
        .zero_sel        (zero_sel),
        .padding_flag    (padding_flag),
        .gap_valid       (gap_valid),
        .done            (done)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic int fragment_row(input int fragment_idx);
        return fragment_idx / FRAGMENT_COLS;
    endfunction

    function automatic int fragment_col(input int fragment_idx);
        return fragment_idx % FRAGMENT_COLS;
    endfunction

    function automatic int count_ones(input logic [0:3199] value);
        int count;
        begin
            count = 0;
            for (int i = 0; i < 3200; i++) begin
                if (value[i]) count++;
            end
            return count;
        end
    endfunction

    function automatic logic [0:3199] expected_stage1_mask(
        input int fragment_idx,
        input int pos
    );
        logic [0:3199] mask;
        int frag_row;
        int frag_col;
        int row_start;
        int col_start;
        int col_count;
        int local_valid_row;
        int local_valid_col;
        int local_row;
        int local_col;
        int base;
        begin
            mask = '0;
            frag_row = fragment_row(fragment_idx);
            frag_col = fragment_col(fragment_idx);

            row_start = (frag_row == 0) ? 1 : 0;
            col_start = (frag_col == 0) ? 1 : 0;
            col_count = ((frag_col == 0) || (frag_col == FRAGMENT_COLS - 1)) ?
                        (STAGE1_SIDE - 1) : STAGE1_SIDE;

            local_valid_row = pos / col_count;
            local_valid_col = pos % col_count;
            local_row       = row_start + local_valid_row;
            local_col       = col_start + local_valid_col;
            base            = ((local_row * STAGE1_SIDE) + local_col) * STAGE1_CHANNELS;

            mask[base +: STAGE1_CHANNELS] = {STAGE1_CHANNELS{1'b1}};
            return mask;
        end
    endfunction

    function automatic bit stage2_position_valid(
        input int fragment_idx,
        input int local_pos
    );
        int frag_row;
        int frag_col;
        int local_row;
        int local_col;
        begin
            frag_row  = fragment_row(fragment_idx);
            frag_col  = fragment_col(fragment_idx);
            local_row = local_pos / STAGE2_SIDE;
            local_col = local_pos % STAGE2_SIDE;

            return !(((frag_row == 0) && (local_row == 0)) ||
                     ((frag_row == FRAGMENT_ROWS - 1) && (local_row == STAGE2_SIDE - 1)) ||
                     ((frag_col == 0) && (local_col == 0)) ||
                     ((frag_col == FRAGMENT_COLS - 1) && (local_col == STAGE2_SIDE - 1)));
        end
    endfunction

    function automatic logic [0:3199] expected_stage2_mask(
        input int fragment_idx,
        input int filter_idx,
        input int frame_idx
    );
        logic [0:3199] mask;
        int base;
        int first_pos;
        int positions_in_frame;
        int local_pos;
        begin
            mask = '0;
            base = filter_idx * (STAGE2_SIDE * STAGE2_SIDE);
            first_pos = frame_idx * 3;
            positions_in_frame = (frame_idx == STAGE2_FRAMES - 1) ? 1 : 3;

            for (int p = 0; p < 3; p++) begin
                if (p < positions_in_frame) begin
                    local_pos = first_pos + p;
                    if (stage2_position_valid(fragment_idx, local_pos)) begin
                        mask[base + local_pos] = 1'b1;
                    end
                end
            end

            return mask;
        end
    endfunction

    function automatic logic [0:3199] expected_stage3_mask(input int filter_idx);
        logic [0:3199] mask;
        begin
            mask = '0;
            mask[filter_idx] = 1'b1;
            return mask;
        end
    endfunction

    task automatic check_mask(
        input string label,
        input logic [0:3199] actual,
        input logic [0:3199] expected
    );
        begin
            checks++;
            if (actual !== expected) begin
                $display("ERROR: %s", label);
                $display("  expected ones = %0d", count_ones(expected));
                $display("  actual ones   = %0d", count_ones(actual));
                for (int i = 0; i < 3200; i++) begin
                    if (actual[i] !== expected[i]) begin
                        $display("  first mismatch bit %0d: expected=%0b actual=%0b",
                                 i, expected[i], actual[i]);
                        break;
                    end
                end
                $fatal(1);
            end
        end
    endtask

    task automatic check_cycle;
        int fragment_idx;
        int stage1_pos;
        int frame_idx;
        logic [0:3199] expected;
        begin
            fragment_idx = dut.fragment_counter;

            if (padding_flag) begin
                check_mask("padding clear mask", mem_enable, '1);
                if (!zero_sel) begin
                    $fatal(1, "padding_flag asserted without zero_sel");
                end
            end

            unique case (stage)
                2'b00: begin
                    stage1_pos = dut.stage1_pos;
                    expected = expected_stage1_mask(fragment_idx, stage1_pos);
                    check_mask("Stage 1 mem_enable", mem_enable, expected);

                    if ((fragment_idx == 0) && (stage1_pos == 0)) begin
                        saw_stage1_top_left = 1'b1;
                        if ((count_ones(mem_enable) != 32) ||
                            (mem_enable[352 +: 32] !== 32'hFFFF_FFFF)) begin
                            $fatal(1, "Stage 1 top-left first real cell should be bits 352..383");
                        end
                    end

                    if ((fragment_idx == 14) && (stage1_pos == 0)) begin
                        saw_stage1_middle = 1'b1;
                        if (mem_enable[0 +: 32] !== 32'hFFFF_FFFF) begin
                            $fatal(1, "Stage 1 middle fragment should start at bits 0..31");
                        end
                    end

                    if ((fragment_idx == 13) && (stage1_pos == 0)) begin
                        saw_stage1_left_edge = 1'b1;
                        if (mem_enable[32 +: 32] !== 32'hFFFF_FFFF) begin
                            $fatal(1, "Stage 1 left-edge fragment should start at bits 32..63");
                        end
                    end

                    if ((fragment_idx == 12) && (stage1_pos == 0)) begin
                        saw_stage1_top_right = 1'b1;
                        if (mem_enable[320 +: 32] !== 32'hFFFF_FFFF) begin
                            $fatal(1, "Stage 1 top-right fragment should start at bits 320..351");
                        end
                    end

                    if ((fragment_idx == FRAGMENTS_MAX - 1) && (stage1_pos == 0)) begin
                        saw_stage1_bottom_right = 1'b1;
                        if (mem_enable[0 +: 32] !== 32'hFFFF_FFFF) begin
                            $fatal(1, "Stage 1 bottom-right fragment should start at bits 0..31");
                        end
                    end
                end

                2'b01: begin
                    frame_idx = frame - 1;
                    expected = expected_stage2_mask(fragment_idx, conv2_filter, frame_idx);
                    check_mask("Stage 2 mem_enable", mem_enable, expected);

                    if ((fragment_idx == 0) && (conv2_filter == 0) && (frame_idx == 0)) begin
                        saw_stage2_top_left_empty = 1'b1;
                        if (count_ones(mem_enable) != 0) begin
                            $fatal(1, "Stage 2 top-left frame 1 should enable no bits");
                        end
                    end

                    if ((fragment_idx == 0) && (conv2_filter == 0) && (frame_idx == 1)) begin
                        saw_stage2_top_left_one_valid = 1'b1;
                        if ((count_ones(mem_enable) != 1) || !mem_enable[5]) begin
                            $fatal(1, "Stage 2 top-left frame 2 should enable only local position 5");
                        end
                    end

                    if ((fragment_idx == 14) && (conv2_filter == 0) && (frame_idx == 0)) begin
                        saw_stage2_middle = 1'b1;
                        if ((count_ones(mem_enable) != 3) ||
                            !mem_enable[0] || !mem_enable[1] || !mem_enable[2]) begin
                            $fatal(1, "Stage 2 middle frame 1 should enable local positions 0,1,2");
                        end
                    end

                    if ((fragment_idx == FRAGMENTS_MAX - 1) &&
                        (conv2_filter == 0) && (frame_idx == 5)) begin
                        saw_stage2_bottom_right = 1'b1;
                        if (count_ones(mem_enable) != 0) begin
                            $fatal(1, "Stage 2 bottom-right frame 6 should skip local position 15");
                        end
                    end
                end

                2'b10: begin
                    expected = expected_stage3_mask(conv3_filter);
                    check_mask("Stage 3 mem_enable", mem_enable, expected);
                    if (!rd_enable || (rd_mem_adderss != 6'd1) || (wr_mem_adderss != 6'd2)) begin
                        $fatal(1, "Stage 3 read/write controls are incorrect");
                    end
                end

                default: begin
                end
            endcase

            if (done) begin
                saw_done = 1'b1;
            end
        end
    endtask

    initial begin
        rst = 1'b0;
        arst_n = 1'b0;
        enable = 1'b0;
        checks = 0;

        repeat (3) @(negedge clk);
        arst_n = 1'b1;
        repeat (2) @(negedge clk);
        enable = 1'b1;

        for (int cycle = 0; cycle < MAX_CYCLES; cycle++) begin
            @(negedge clk);
            check_cycle();
            if (done) begin
                break;
            end
        end

        if (!saw_done) begin
            $fatal(1, "Controller did not assert done before timeout");
        end

        if (!saw_stage1_top_left || !saw_stage1_middle || !saw_stage1_left_edge ||
            !saw_stage1_top_right || !saw_stage1_bottom_right ||
            !saw_stage2_top_left_empty || !saw_stage2_top_left_one_valid ||
            !saw_stage2_middle || !saw_stage2_bottom_right) begin
            $fatal(1, "Coverage failure: not all controller padding cases were observed");
        end

        enable = 1'b0;
        @(negedge clk);

        $display("TB PASS: top_controller checked %0d cycles/masks", checks);
        $finish;
    end

endmodule
