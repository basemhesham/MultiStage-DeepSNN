module top_controller #(
    parameter int FRAGMENT_ROWS   = 13,
    parameter int FRAGMENT_COLS   = 13,
    parameter int FRAGMENTS_MAX   = FRAGMENT_ROWS * FRAGMENT_COLS,
    parameter int TEMPORAL_FRAMES = 16
)(
    input  logic clk, //clock of system
    input  logic rst, //reset of system(soft)
    input  logic arst_n, //asynchronous reset(hard)
    input  logic enable, //enable of the controller
    input  logic done_load_o, //input done from mapping controller
    input  logic conv_done_o, //input done from mapping controller

    output logic [0:3199] mem_enable,//shaaban unit output into spike memory stage1 (32 shaaban x 10 x 10)
    output logic          rd_enable,//not used in top module
    output logic [1:0]    stage,//signal that defines which stage we are in
    output logic [2:0]    frame,//signal that defines which frame we are in(16 frames)
    output logic          stage_sel,//When asserted, it indicates that we are in a stage.
    output logic [5:0]    conv2_filter,//Which fitler in stage2 we are using
    output logic [6:0]    conv3_filter,//which filter in stage3 we are using
    output logic [5:0]    rd_mem_adderss,//read address from pixel memory
    output logic [5:0]    wr_mem_adderss,//write address to spike memory
    output logic          zero,//not used
    output logic          zero_sel,//For clearing stages before using them(clear stage 2 before using it,etc..)
    output logic          padding_flag,//not used
    output logic          gap_valid,//defines that we finished all frames.
    output logic          fetch_en_i,//controls the state transition in mapping controller
    output logic          next_i,//Control signal for state transition in mapping controller
    output logic          done//done signel for global average pooling
);

    localparam int FRAGMENT_SIDE    = 10;//Fragment size 10x10=100
    localparam int STAGE1_CHANNELS  = 32;//Stage1 filters
    localparam int STAGE1_POSITIONS = FRAGMENT_SIDE * FRAGMENT_SIDE;//Width of Stage1 =100
    localparam int STAGE2_SIDE      = 4;//Stage2 side=4 (4x4 output)
    localparam int STAGE2_POSITIONS = STAGE2_SIDE * STAGE2_SIDE;//Stage2 positions output(16)
    localparam int STAGE2_FRAMES    = 6;// 5 full 3-output frames + 1 edge frame
    localparam int STAGE2_FILTERS   = 64;//Number of filters in stage2
    localparam int STAGE3_FILTERS   = 128;//Number of filters in stage3

    localparam int STAGE1_CNT_W   = $clog2(STAGE1_POSITIONS);//number of bits in the 10x10 stage1
    localparam int STAGE2_FRAME_W = $clog2(STAGE2_FRAMES);//number of bits for the frames in stage2
    localparam int FRAGMENT_W     = (FRAGMENTS_MAX <= 1) ? 1 : $clog2(FRAGMENTS_MAX);//Maximum fragment width(13x13=169)
    localparam int TEMPORAL_W     = (TEMPORAL_FRAMES <= 1) ? 1 : $clog2(TEMPORAL_FRAMES);//Maximum frame (16)
    localparam int STAGE2_SIDE_W  = $clog2(STAGE2_SIDE);//bits needed to shift/mask by STAGE2_SIDE (power of 2)

	////////////////////////////
	//
	//States definition
	//
	////////////////////////////
	
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

    logic fetch_en_sent;//flag to indicate that we sent the fetch signal to mapping controller

    logic [STAGE1_CNT_W-1:0]   stage1_pos;//Defines the position inside the 100 positions(10x10)
    logic [STAGE2_FRAME_W-1:0] stage2_frame_idx;//Defines index inside stage2 frames
    logic [FRAGMENT_W-1:0]     fragment_counter;//Fragment counter that counts the 169 fragments
    logic [TEMPORAL_W-1:0]     temporal_counter;//Temporal counter that counts the 16 frames

    // ------------------------------------------------------------------
    // Fragment geometry for the current fragment_counter
    // frag_row / frag_col are now maintained as running counters that
    // step in lock-step with fragment_counter, instead of being derived
    // combinationally via divide/modulo of fragment_counter by
    // FRAGMENT_COLS (a non-power-of-2 divisor).
    // ------------------------------------------------------------------
    logic [7:0] frag_row;//Fragment row index(13 max)
    logic [3:0] frag_col;//Fragment col index(13 max)

    // Stage 1 valid-position count for the current fragment
    // (replaces stage1_valid_positions function)
    logic [3:0] stage1_row_count;//counts based on the frag row
    logic [3:0] stage1_col_count;//counts based on the frag col
    logic [7:0] stage1_valid_positions;//Valid positions(0 to 169)

    always_comb begin
        stage1_row_count = ((frag_row == 0) || (frag_row == FRAGMENT_ROWS - 1)) ?
                            (FRAGMENT_SIDE - 1) : FRAGMENT_SIDE;//calculation of frag row count
        stage1_col_count = ((frag_col == 0) || (frag_col == FRAGMENT_COLS - 1)) ?
                            (FRAGMENT_SIDE - 1) : FRAGMENT_SIDE;//calculation of frag col count

        stage1_valid_positions = stage1_row_count * stage1_col_count;//calculation of valid positions
    end

    wire stage1_last   = ({1'b0,stage1_pos} == stage1_valid_positions - 1);
    wire stage2_last   = (stage2_frame_idx == STAGE2_FRAMES - 1) &&
                         (conv2_filter     == STAGE2_FILTERS - 1);
    wire stage3_last   = (conv3_filter     == STAGE3_FILTERS - 1);
    wire fragment_last = (fragment_counter == FRAGMENTS_MAX - 1);
    wire temporal_last = (temporal_counter == TEMPORAL_FRAMES - 1);
    wire run_complete  = stage3_last && fragment_last && temporal_last;

    // ------------------------------------------------------------------
    // Stage 1 write mask (replaces stage1_write_mask function)
    // stage1_local_row / stage1_local_col are now derived from running
    // row/col counters (stage1_local_row_cnt / stage1_local_col_cnt)
    // instead of dividing/moduloing stage1_pos by stage1_col_count
    // (a variable, non-power-of-2 divisor).
    // ------------------------------------------------------------------
    logic [0:3199] stage1_mask;
    logic            stage1_row_start;
    logic            stage1_col_start;
    logic [7:0]            stage1_local_row;
    logic [4:0]    stage1_local_col;
    logic [40:0]   stage1_base;

    logic [3:0] stage1_local_row_cnt;//running row counter within the current fragment
    logic [3:0] stage1_local_col_cnt;//running col counter within the current fragment

    always_comb begin
        stage1_row_start = (frag_row == 0) ? 1 : 0;
        stage1_col_start = (frag_col == 0) ? 1 : 0;
        stage1_local_row = {7'd0,stage1_row_start} + {4'd0,stage1_local_row_cnt};
        stage1_local_col = {4'd0,stage1_col_start} + {1'd0,stage1_local_col_cnt};
        stage1_base[17:0]      = ((stage1_local_row * FRAGMENT_SIDE) + {7'd0,stage1_local_col}) * STAGE1_CHANNELS;
		stage1_base[40:18]=0;
        stage1_mask = '0;
        stage1_mask[stage1_base +: STAGE1_CHANNELS] = {STAGE1_CHANNELS{1'b1}};
    end

    // ------------------------------------------------------------------
    // Stage 2 write mask (replaces stage2_write_mask + stage2_position_valid
    // functions). STAGE2_SIDE is a fixed power of 2 (4), so the divide/
    // modulo by STAGE2_SIDE is replaced with a shift/mask.
    // ------------------------------------------------------------------
    logic [0:3199] stage2_mask;
    logic [0:3199] stage2_partial_mask [0:2];   // one partial mask per generate instance
    logic [9:0]            stage2_base;
    logic [4:0]            stage2_first_pos;
    logic [1:0]            stage2_positions_in_frame;

    always_comb begin
        stage2_base               = conv2_filter * STAGE2_POSITIONS;
        stage2_first_pos          = stage2_frame_idx * 3;
        stage2_positions_in_frame = (stage2_frame_idx == STAGE2_FRAMES - 1) ? 1 : 3;
    end
	logic [9:0] arith_op [0:2];
    generate
        for (genvar p = 0; p < 3; p = p + 1) begin : gen_stage2_pos
            logic [4:0]   stage2_pos_g;
            logic [4:0]   stage2_local_row_g;
            logic [4:0]   stage2_local_col_g;
            logic stage2_pos_valid_g;
			
            always_comb begin
                stage2_pos_g       = stage2_first_pos + p;
                stage2_local_row_g = stage2_pos_g >> STAGE2_SIDE_W;          // was: stage2_pos_g / STAGE2_SIDE
                stage2_local_col_g = stage2_pos_g & (STAGE2_SIDE - 1);       // was: stage2_pos_g % STAGE2_SIDE
                stage2_pos_valid_g = !(((frag_row == 0) && (stage2_local_row_g == 0)) ||
                                       ((frag_row == FRAGMENT_ROWS - 1) && (stage2_local_row_g == STAGE2_SIDE - 1)) ||
                                       ((frag_col == 0) && (stage2_local_col_g == 0)) ||
                                       ((frag_col == FRAGMENT_COLS - 1) && (stage2_local_col_g == STAGE2_SIDE - 1)));

				arith_op[p]=stage2_base + {5'd0,stage2_pos_g};
                stage2_partial_mask[p] = '0;
                if ((p < stage2_positions_in_frame) && stage2_pos_valid_g) begin
                    stage2_partial_mask[p][arith_op[p]] = 1'b1;
                end
            end
        end
    endgenerate

    assign stage2_mask = stage2_partial_mask[0] | stage2_partial_mask[1] | stage2_partial_mask[2];

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
            cs                    <= IDLE;
            stage1_pos            <= '0;
            stage1_local_row_cnt  <= '0;
            stage1_local_col_cnt  <= '0;
            stage2_frame_idx      <= '0;
            conv2_filter          <= '0;
            conv3_filter          <= '0;
            fragment_counter      <= '0;
            frag_row              <= '0;
            frag_col              <= '0;
            temporal_counter      <= '0;
        end else begin
            cs <= ns;

            if (cs == IDLE && ns == CLEAR_STAGE2_WORD) begin
                stage1_pos            <= '0;
                stage1_local_row_cnt  <= '0;
                stage1_local_col_cnt  <= '0;
                stage2_frame_idx      <= '0;
                conv2_filter          <= '0;
                conv3_filter          <= '0;
                fragment_counter      <= '0;
                frag_row              <= '0;
                frag_col              <= '0;
                temporal_counter      <= '0;
            end else begin
                unique case (cs)
                    STAGE1: begin
						if(stage1_last) begin
							stage1_pos           <= '0;
							stage1_local_row_cnt <= '0;
							stage1_local_col_cnt <= '0;
						end
						else begin
							stage1_pos <= stage1_pos + 1'b1;
							if (stage1_local_col_cnt == stage1_col_count - 1) begin
								stage1_local_col_cnt <= '0;
								stage1_local_row_cnt <= stage1_local_row_cnt + 1'b1;
							end else begin
								stage1_local_col_cnt <= stage1_local_col_cnt + 1'b1;
							end
						end
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
                                    frag_row         <= '0;
                                    frag_col         <= '0;
                                    temporal_counter <= temporal_counter + 1'b1;
                                end else begin
                                    fragment_counter <= fragment_counter + 1'b1;
                                    if (frag_col == FRAGMENT_COLS - 1) begin
                                        frag_col <= '0;
                                        frag_row <= frag_row + 1'b1;
                                    end else begin
                                        frag_col <= frag_col + 1'b1;
                                    end
                                end
                            end
                        end else begin
                            conv3_filter <= conv3_filter + 1'b1;
                        end
                    end

                    default: begin
                        stage1_pos           <= stage1_pos;
                        stage1_local_row_cnt <= stage1_local_row_cnt;
                        stage1_local_col_cnt <= stage1_local_col_cnt;
                        stage2_frame_idx     <= stage2_frame_idx;
                        conv2_filter         <= conv2_filter;
                        conv3_filter         <= conv3_filter;
                        fragment_counter     <= fragment_counter;
                        frag_row             <= frag_row;
                        frag_col             <= frag_col;
                        temporal_counter     <= temporal_counter;
                    end
                endcase
            end
        end
    end

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
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
                mem_enable     = stage1_mask;
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
                mem_enable     = stage2_mask;
            end

            STAGE3: begin
                stage          = 2'b10;
                stage_sel      = 1'b1;
                rd_enable      = 1'b1;
                rd_mem_adderss = 6'd1;
                wr_mem_adderss = 6'd2;
                mem_enable[{5'd0,conv3_filter}] = 1'b1;
                gap_valid      = temporal_last;
            end

            default: begin
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
            end
        endcase
    end

endmodule