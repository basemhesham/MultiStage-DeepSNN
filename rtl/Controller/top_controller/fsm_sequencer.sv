//==============================================================================
// Module      : fsm_sequencer
// Description :
//    The core state machine for the SNN pipeline controller. Owns the FSM
//    state register and every iteration counter (Stage-1 position, Stage-2
//    frame/filter, Stage-3 filter, fragment, temporal frame, and fragment
//    row/col). Advances them each cycle according to the state and the
//    "last position" conditions computed below.
//
//    Pipeline overview:
//      IDLE               -> waits for 'enable'
//      CLEAR_STAGE2_WORD  -> zeroes the Stage-2 memory word before Stage1 runs
//      STAGE1             -> streams the current fragment's valid positions
//                            (10x10, clipped at image edges) through the
//                            Stage-1 conv/LIF array, one position per cycle
//      CLEAR_STAGE3_WORD  -> zeroes the Stage-3 memory word before Stage2 runs
//      STAGE2             -> streams the current fragment's valid positions
//                            (4x4, clipped at image edges) through the
//                            Stage-2 conv array, up to 3 positions per cycle,
//                            one filter at a time
//      STAGE3             -> streams the single Stage-3 output position
//                            through the Stage-3 conv array, one filter at
//                            a time
//      DONE               -> asserted once every fragment, every temporal
//                            frame, and every Stage-3 filter has been
//                            processed (see 'run_complete')
//
//    stage1_valid_positions and stage2_last_frame_idx are supplied by
//    stage1_geometry_unit / stage2_geometry_unit (combinational functions of
//    frag_row/frag_col and, for Stage-2, conv2_filter), since they are
//    needed here to detect the end of each stage's sweep.
//==============================================================================
module fsm_sequencer
	import top_controller_pkg::*;
#(
	parameter int FRAGMENT_ROWS    = 32 						, // fragment rows spanning the source image
    parameter int FRAGMENT_COLS    = 32 						, // fragment columns spanning the source image
	parameter int FRAGMENTS_MAX    = FRAGMENT_ROWS*FRAGMENT_COLS, // total fragments per temporal frame (FRAGMENT_ROWS * FRAGMENT_COLS)
	parameter int TEMPORAL_FRAMES  = 16 						, // temporal frames replayed through the pipeline
	parameter int STAGE1_POSITIONS = 100						, // Stage-1 positions in a full (non-edge) fragment, used only to size stage1_pos
	parameter int STAGE2_FRAMES    = 6  						, // Stage-2 "frames" per fragment, used only to size stage2_frame_idx
	parameter int STAGE2_FILTERS   = 64 						, // number of Stage-2 filters
	parameter int STAGE3_FILTERS   = 128						, // number of Stage-3 filters

	// -- Derived bit widths (mirrors the localparam formulas in top_controller) --
	localparam int STAGE1_CNT_W   = $clog2(STAGE1_POSITIONS)                            , // bits for stage1_pos (0..99)
	localparam int STAGE2_FRAME_W = $clog2(STAGE2_FRAMES)                                , // bits for stage2_frame_idx (0..5)
	localparam int FRAGMENT_W     = (FRAGMENTS_MAX   <= 1) ? 1 : $clog2(FRAGMENTS_MAX)   , // bits for fragment_counter (0..168)
	localparam int TEMPORAL_W     = (TEMPORAL_FRAMES <= 1) ? 1 : $clog2(TEMPORAL_FRAMES)   // bits for temporal_counter (0..15)
)
(
	input  wire logic clk        , // clock of system
	input  wire logic rst        , // reset of system (soft)
	input  wire logic arst_n     , // asynchronous reset (hard)
	input  wire logic enable     , // enable of the controller
	input  wire logic done_load_o, // input done from mapping controller
	input  wire logic conv_done_o, // input done from mapping controller
	input  wire logic fetch_en_i,

	input  wire logic [7:0] stage1_valid_positions, // total valid Stage-1 positions for the current fragment (from stage1_geometry_unit)
	input  wire logic [3:0] stage1_col_count      , // valid Stage-1 col count for the current fragment (from stage1_geometry_unit)
	input  wire logic [2:0] stage2_last_frame_idx  , // index of the last active Stage-2 frame for the current fragment (from stage2_geometry_unit)

	output      state_t state_q, // registered (current) FSM state

	output logic [STAGE1_CNT_W-1:0]   stage1_pos          , // linear position counter within the current fragment's Stage-1 sweep
	output logic [3:0]                stage1_local_row_cnt, // running Stage-1 row counter within the current fragment
	output logic [3:0]                stage1_local_col_cnt, // running Stage-1 col counter within the current fragment
	output logic [STAGE2_FRAME_W-1:0] stage2_frame_idx    , // current Stage-2 frame (group of up to 3 positions) within the fragment
	output logic [5:0]                conv2_filter        , // current Stage-2 filter index
	output logic [11:0]               conv3_filter        , // current Stage-3 filter index
	output logic [FRAGMENT_W-1:0]     fragment_counter    , // counts fragments processed within the current temporal frame
	output logic [7:0]                frag_row            , // fragment row index within the FRAGMENT_ROWS x FRAGMENT_COLS grid
	output logic [7:0]                frag_col            , // fragment column index within the FRAGMENT_ROWS x FRAGMENT_COLS grid
	output logic [TEMPORAL_W-1:0]     temporal_counter    , // counts temporal frames replayed through the pipeline

	output logic stage2_last  , // final Stage-2 frame of the final Stage-2 filter (also needed by output_mux_unit)
	output logic temporal_last  // final temporal frame of the run (also needed by output_mux_unit, for gap_valid)
);

	//==========================================================================
	// "Last Position" Flags -- used below to know when to advance
	//==========================================================================
	wire stage1_last   = ({1'b0, stage1_pos} == stage1_valid_positions - 1);          // current cycle is the fragment's final Stage-1 position
	wire stage3_last   = (conv3_filter     == STAGE3_FILTERS - 1);                    // final Stage-3 filter
	wire fragment_last = (fragment_counter == FRAGMENTS_MAX - 1);                     // final fragment of the current temporal frame
	wire run_complete  = stage3_last && fragment_last && temporal_last;               // entire run (all fragments, all frames) is finished

	assign stage2_last   = (stage2_frame_idx == stage2_last_frame_idx) && (conv2_filter == STAGE2_FILTERS - 1); // final Stage-2 frame of the final Stage-2 filter
	assign temporal_last = (temporal_counter == TEMPORAL_FRAMES - 1);                 // final temporal frame of the run

	reg stage1_last_p;

	//==========================================================================
	// FSM Next-State Logic
	//==========================================================================
	state_t state_d; // combinational next FSM state

	always_comb
		begin
			state_d = state_q; // default: hold current state

			unique case (state_q)
				IDLE:              state_d = enable ? CLEAR_STAGE2_WORD : IDLE;                                    // start a run once 'enable' is asserted
				CLEAR_STAGE2_WORD: state_d = (done_load_o&&fetch_en_i) ? STAGE1 : CLEAR_STAGE2_WORD;                              // wait for the fragment to be loaded before starting Stage1
				STAGE1:            state_d = (stage1_last && conv_done_o) ? CLEAR_STAGE3_WORD : STAGE1;             // advance once the final position is processed and conv is done
				CLEAR_STAGE3_WORD: state_d = STAGE2;                                                                // single-cycle clear, always advances to Stage2
				STAGE2:            state_d = stage2_last ? STAGE3 : STAGE2;                                         // advance once the final frame of the final filter is done
				STAGE3:            state_d = stage3_last ? (run_complete ? DONE : CLEAR_STAGE2_WORD) : STAGE3;      // finish the run, or loop back for the next fragment/frame
				DONE:              state_d = enable ? DONE : IDLE;                                                  // hold in DONE while 'enable' stays asserted, else return to IDLE
				default:           state_d = IDLE;                                                                  // unreachable states recover to IDLE
			endcase
		end

	always_ff @( posedge clk ) begin
		stage1_last_p <= stage1_last;
	end
	//==========================================================================
	// FSM State Register and Counter Update Logic (sequential)
	//==========================================================================
	always_ff @(posedge clk or negedge arst_n)
		begin
			if (!arst_n)
				begin
					// Asynchronous hard reset: force everything to its initial state.
					state_q              <= IDLE;
					stage1_pos           <= '0;
					stage1_local_row_cnt <= '0;
					stage1_local_col_cnt <= '0;
					stage2_frame_idx     <= '0;
					conv2_filter         <= '0;
					conv3_filter         <= '0;
					fragment_counter     <= '0;
					frag_row             <= '0;
					frag_col             <= '0;
					temporal_counter     <= '0;
				end
			else if (rst)
				begin
					// Synchronous soft reset: same effect as the async reset above.
					state_q              <= IDLE;
					stage1_pos           <= '0;
					stage1_local_row_cnt <= '0;
					stage1_local_col_cnt <= '0;
					stage2_frame_idx     <= '0;
					conv2_filter         <= '0;
					conv3_filter         <= '0;
					fragment_counter     <= '0;
					frag_row             <= '0;
					frag_col             <= '0;
					temporal_counter     <= '0;
				end
			else
				begin
					state_q <= state_d;

					if (state_q == IDLE && state_d == CLEAR_STAGE2_WORD)
						begin
							// Starting a brand-new run: re-initialize every counter.
							stage1_pos           <= '0;
							stage1_local_row_cnt <= '0;
							stage1_local_col_cnt <= '0;
							stage2_frame_idx     <= '0;
							conv2_filter         <= '0;
							conv3_filter         <= '0;
							fragment_counter     <= '0;
							frag_row             <= '0;
							frag_col             <= '0;
							temporal_counter     <= '0;
						end
					else
						begin
							unique case (state_q)

								STAGE1:
									begin
										if (stage1_last || stage1_last_p)
											begin
												// Fragment's Stage-1 sweep is complete: reset the
												// position and local row/col counters for the next
												// fragment (advanced below, in the STAGE3 branch).
												stage1_pos           <= '0;
												stage1_local_row_cnt <= '0;
												stage1_local_col_cnt <= '0;
											end
										else
											begin
												// Advance to the next Stage-1 position, wrapping the
												// local column counter into the local row counter at
												// the end of each valid row.
												stage1_pos <= stage1_pos + 1'b1;
												if (stage1_local_col_cnt == stage1_col_count - 1)
													begin
														stage1_local_col_cnt <= '0;
														stage1_local_row_cnt <= stage1_local_row_cnt + 1'b1;
													end
												else
													begin
														stage1_local_col_cnt <= stage1_local_col_cnt + 1'b1;
													end
											end
									end

								STAGE2:
									begin
										if (stage2_last)
											begin
												// Final frame of the final Stage-2 filter: reset both
												// counters (STAGE3 is entered next via next-state logic).
												stage2_frame_idx <= '0;
												conv2_filter     <= '0;
											end
										else if (stage2_frame_idx == stage2_last_frame_idx)
											begin
												// Final frame of the current filter, but more filters
												// remain: wrap the frame index and advance the filter.
												stage2_frame_idx <= '0;
												conv2_filter     <= conv2_filter + 1'b1;
											end
										else
											begin
												// More frames remain for the current filter.
												stage2_frame_idx <= stage2_frame_idx + 1'b1;
											end
									end

								STAGE3:
									begin
										if (stage3_last)
											begin
												conv3_filter <= '0; // wrap the Stage-3 filter index

												if (!run_complete)
													begin
														// More fragments and/or temporal frames remain:
														// advance to the next fragment (row-major order),
														// or wrap to the next temporal frame once every
														// fragment has been processed.
														if (fragment_last)
															begin
																fragment_counter <= '0;
																frag_row         <= '0;
																frag_col         <= '0;
																temporal_counter <= temporal_counter + 1'b1;
															end
														else
															begin
																fragment_counter <= fragment_counter + 1'b1;
																if (frag_col == FRAGMENT_COLS - 1)
																	begin
																		frag_col <= '0;
																		frag_row <= frag_row + 1'b1;
																	end
																else
																	begin
																		frag_col <= frag_col + 1'b1;
																	end
															end
													end
												// else: run_complete -- all counters hold, DONE is entered
												// via next-state logic and no further advance is needed.
											end
										else
											begin
												// More Stage-3 filters remain for this fragment.
												conv3_filter <= conv3_filter + 1'b1;
											end
									end

								default:
									begin
										// IDLE / CLEAR_STAGE2_WORD / CLEAR_STAGE3_WORD / DONE:
										// no counter updates needed, hold current values.
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

endmodule : fsm_sequencer
