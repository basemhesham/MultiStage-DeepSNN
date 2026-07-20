module top_controller #(
    parameter int FRAGMENT_ROWS   = 13,
    parameter int FRAGMENT_COLS   = 13,
    parameter int FRAGMENTS_MAX   = FRAGMENT_ROWS * FRAGMENT_COLS,
    parameter int TEMPORAL_FRAMES = 16
)(
    input  logic clk,
    input  logic rst,
    input  logic arst_n,
    input  logic enable,
    input  logic done_load_o,
    input  logic conv_done_o,

    output logic [0:3199] mem_enable,
    output logic          rd_enable,
    output logic [1:0]    stage,
    output logic [2:0]    frame,
    output logic          stage_sel,
    output logic [5:0]    conv2_filter,
    output logic [6:0]    conv3_filter,
    output logic [5:0]    rd_mem_adderss,
    output logic [5:0]    wr_mem_adderss,
    output logic          zero,
    output logic          zero_sel,
    output logic          padding_flag,
    output logic          gap_valid,
    output logic          fetch_en_i,
    output logic          next_i,
    output logic          done
);

    localparam int FRAGMENT_SIDE    = 10;
    localparam int STAGE1_CHANNELS  = 32;
    localparam int STAGE1_POSITIONS = FRAGMENT_SIDE * FRAGMENT_SIDE;
    localparam int STAGE2_SIDE      = 4;
    localparam int STAGE2_POSITIONS = STAGE2_SIDE * STAGE2_SIDE;
    localparam int STAGE2_FRAMES    = 6;    // 5 full 3-output frames + 1 edge frame
    localparam int STAGE2_FILTERS   = 64;
    localparam int STAGE3_FILTERS   = 128;

    localparam int STAGE1_CNT_W   = $clog2(STAGE1_POSITIONS);
    localparam int STAGE2_FRAME_W = $clog2(STAGE2_FRAMES);
    localparam int FRAGMENT_W     = (FRAGMENTS_MAX <= 1) ? 1 : $clog2(FRAGMENTS_MAX);
    localparam int TEMPORAL_W     = (TEMPORAL_FRAMES <= 1) ? 1 : $clog2(TEMPORAL_FRAMES);

    typedef enum logic [2:0] {
        IDLE,
        CLEAR_STAGE2_WORD,
        STAGE1,
        CLEAR_STAGE3_WORD,
        STAGE2,
        STAGE3,
        DONE
    } state_t;

    state_t cs, ns;

    logic fetch_en_sent;

    logic [STAGE1_CNT_W-1:0]   stage1_pos;
    logic [STAGE2_FRAME_W-1:0] stage2_frame_idx;
    logic [FRAGMENT_W-1:0]     fragment_counter;
    logic [TEMPORAL_W-1:0]     temporal_counter;

    function automatic int fragment_row(
        input logic [FRAGMENT_W-1:0] fragment_idx
    );
        return fragment_idx / FRAGMENT_COLS;
    endfunction

    function automatic int fragment_col(
        input logic [FRAGMENT_W-1:0] fragment_idx
    );
        return fragment_idx % FRAGMENT_COLS;
    endfunction

    function automatic int stage1_valid_positions(
        input logic [FRAGMENT_W-1:0] fragment_idx
    );
        int frag_row;
        int frag_col;
        int row_count;
        int col_count;
        begin
            frag_row  = fragment_row(fragment_idx);
            frag_col  = fragment_col(fragment_idx);
            row_count = ((frag_row == 0) || (frag_row == FRAGMENT_ROWS - 1)) ?
                        (FRAGMENT_SIDE - 1) : FRAGMENT_SIDE;
            col_count = ((frag_col == 0) || (frag_col == FRAGMENT_COLS - 1)) ?
                        (FRAGMENT_SIDE - 1) : FRAGMENT_SIDE;

            return row_count * col_count;
        end
    endfunction

    wire stage1_last   = (stage1_pos == stage1_valid_positions(fragment_counter) - 1);
    wire stage2_last   = (stage2_frame_idx == STAGE2_FRAMES - 1) &&
                         (conv2_filter     == STAGE2_FILTERS - 1);
    wire stage3_last   = (conv3_filter     == STAGE3_FILTERS - 1);
    wire fragment_last = (fragment_counter == FRAGMENTS_MAX - 1);
    wire temporal_last = (temporal_counter == TEMPORAL_FRAMES - 1);
    wire run_complete  = stage3_last && fragment_last && temporal_last;

    function automatic logic [0:3199] stage1_write_mask(
        input logic [STAGE1_CNT_W-1:0] pos,
        input logic [FRAGMENT_W-1:0] fragment_idx
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
                        (FRAGMENT_SIDE - 1) : FRAGMENT_SIDE;

            local_valid_row = pos / col_count;
            local_valid_col = pos % col_count;
            local_row       = row_start + local_valid_row;
            local_col       = col_start + local_valid_col;
            base            = ((local_row * FRAGMENT_SIDE) + local_col) * STAGE1_CHANNELS;

            mask[base +: STAGE1_CHANNELS] = {STAGE1_CHANNELS{1'b1}};
            return mask;
        end
    endfunction

    function automatic logic [0:3199] stage2_write_mask(
        input logic [5:0] filter,
        input logic [STAGE2_FRAME_W-1:0] frame_idx,
        input logic [FRAGMENT_W-1:0] fragment_idx
    );
        logic [0:3199] mask;
        int base;
        int pos;
        int first_pos;
        int positions_in_frame;
        int p;
        begin
            mask = '0;
            base = filter * STAGE2_POSITIONS;
            first_pos = frame_idx * 3;
            positions_in_frame = (frame_idx == STAGE2_FRAMES - 1) ? 1 : 3;

            for (p = 0; p < 3; p = p + 1) begin
                if (p < positions_in_frame) begin
                    pos = first_pos + p;
                    if (stage2_position_valid(pos, fragment_idx)) begin
                        mask[base + pos] = 1'b1;
                    end
                end
            end

            return mask;
        end
    endfunction

    function automatic logic stage2_position_valid(
        input int local_pos,
        input logic [FRAGMENT_W-1:0] fragment_idx
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

    always_comb begin
        ns = cs;

        unique case (cs)
            IDLE:              ns = enable ? CLEAR_STAGE2_WORD : IDLE;
            CLEAR_STAGE2_WORD: ns = done_load_o ? STAGE1 : CLEAR_STAGE2_WORD;
            STAGE1:            ns = (stage1_last && conv_done_o) ? CLEAR_STAGE3_WORD : STAGE1;
            CLEAR_STAGE3_WORD: ns = STAGE2;
            STAGE2:            ns = stage2_last ? STAGE3 : STAGE2;
            STAGE3:            ns = stage3_last ? (run_complete ? DONE : CLEAR_STAGE2_WORD) : STAGE3;
            DONE:              ns = enable ? DONE : IDLE;
            default:           ns = IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            cs               <= IDLE;
            stage1_pos       <= '0;
            stage2_frame_idx <= '0;
            conv2_filter     <= '0;
            conv3_filter     <= '0;
            fragment_counter <= '0;
            temporal_counter <= '0;
        end else if (rst) begin
            cs               <= IDLE;
            stage1_pos       <= '0;
            stage2_frame_idx <= '0;
            conv2_filter     <= '0;
            conv3_filter     <= '0;
            fragment_counter <= '0;
            temporal_counter <= '0;
        end else begin
            cs <= ns;

            if (cs == IDLE && ns == CLEAR_STAGE2_WORD) begin
                stage1_pos       <= '0;
                stage2_frame_idx <= '0;
                conv2_filter     <= '0;
                conv3_filter     <= '0;
                fragment_counter <= '0;
                temporal_counter <= '0;
            end else begin
                unique case (cs)
                    STAGE1: begin
                        stage1_pos <= stage1_last ? '0 : stage1_pos + 1'b1;
                    end

                    STAGE2: begin
                        if (stage2_last) begin
                            stage2_frame_idx <= '0;
                            conv2_filter     <= '0;
                        end else if (stage2_frame_idx == STAGE2_FRAMES - 1) begin
                            stage2_frame_idx <= '0;
                            conv2_filter     <= conv2_filter + 1'b1;
                        end else begin
                            stage2_frame_idx <= stage2_frame_idx + 1'b1;
                        end
                    end

                    STAGE3: begin
                        if (stage3_last) begin
                            conv3_filter <= '0;

                            if (!run_complete) begin
                                if (fragment_last) begin
                                    fragment_counter <= '0;
                                    temporal_counter <= temporal_counter + 1'b1;
                                end else begin
                                    fragment_counter <= fragment_counter + 1'b1;
                                end
                            end
                        end else begin
                            conv3_filter <= conv3_filter + 1'b1;
                        end
                    end

                    default: begin
                        stage1_pos       <= stage1_pos;
                        stage2_frame_idx <= stage2_frame_idx;
                        conv2_filter     <= conv2_filter;
                        conv3_filter     <= conv3_filter;
                        fragment_counter <= fragment_counter;
                        temporal_counter <= temporal_counter;
                    end
                endcase
            end
        end
    end

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            fetch_en_i    <= 1'b0;
            fetch_en_sent <= 1'b0;
        end else if (rst) begin
            fetch_en_i    <= 1'b0;
            fetch_en_sent <= 1'b0;
        end else begin
            fetch_en_i <= 1'b0;
            if (cs == CLEAR_STAGE2_WORD && done_load_o && !fetch_en_sent) begin
                fetch_en_i    <= 1'b1;
                fetch_en_sent <= 1'b1;
            end
            if (!done_load_o)
                fetch_en_sent <= 1'b0;
        end
    end

    always_comb begin
        mem_enable      = '0;
        rd_enable       = 1'b0;
        stage           = 2'b11;
        frame           = 3'd1;
        stage_sel       = 1'b0;
        rd_mem_adderss  = 6'd0;
        wr_mem_adderss  = 6'd0;
        zero            = 1'b0;
        zero_sel        = 1'b0;
        padding_flag    = 1'b0;
        gap_valid       = 1'b0;
        next_i          = (cs == STAGE2 || cs == STAGE3);
        done            = (cs == DONE);

        unique case (cs)
            CLEAR_STAGE2_WORD: begin
                mem_enable     = '1;
                wr_mem_adderss = 6'd0;
                zero_sel       = 1'b1;
                padding_flag   = 1'b1;
            end

            STAGE1: begin
                stage          = 2'b00;
                mem_enable     = stage1_write_mask(stage1_pos, fragment_counter);
                wr_mem_adderss = 6'd0;
            end

            CLEAR_STAGE3_WORD: begin
                mem_enable     = '1;
                wr_mem_adderss = 6'd1;
                zero_sel       = 1'b1;
                padding_flag   = 1'b1;
            end

            STAGE2: begin
                stage          = 2'b01;
                frame          = stage2_frame_idx + 3'd1;
                stage_sel      = 1'b1;
                rd_enable      = 1'b1;
                rd_mem_adderss = stage2_last ? 6'd1 : 6'd0;
                wr_mem_adderss = 6'd1;
                mem_enable     = stage2_write_mask(conv2_filter, stage2_frame_idx, fragment_counter);
            end

            STAGE3: begin
                stage          = 2'b10;
                stage_sel      = 1'b1;
                rd_enable      = 1'b1;
                rd_mem_adderss = 6'd1;
                wr_mem_adderss = 6'd2;
                mem_enable[conv3_filter] = 1'b1;
                gap_valid      = temporal_last;
            end

            default: begin
            end
        endcase
    end

endmodule
