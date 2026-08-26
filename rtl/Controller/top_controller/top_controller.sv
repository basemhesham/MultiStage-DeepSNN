//==============================================================================
// Module      : top_controller
// Description :
//    Top-level FSM controller for the SNN (Spiking Neural Network) pipeline.
//    This module is now a pure structural wrapper: it declares the
//    (unchanged) external interface and internal connecting wires, and
//    instantiates the five functional blocks that do the actual work:
//
//      stage1_geometry_unit  -- Stage-1 valid-position count + write mask
//      stage2_geometry_unit  -- Stage-2 valid-position count + write mask
//      fsm_sequencer         -- FSM state register, next-state logic, and
//                               every iteration counter
//      fetch_handshake_unit  -- single-cycle fetch_en_i pulse generation
//      output_mux_unit       -- combinational per-state output mux
//
//    See each submodule's header comment for its own detailed description.
//    top_controller_pkg holds the shared FSM state type used across all of
//    the above.
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
//                            processed
//==============================================================================
module top_controller
	import top_controller_pkg::*;
#(
	parameter int FRAGMENT_ROWS   = 32                            , // fragment rows spanning the source image
	parameter int FRAGMENT_COLS   = 32                            , // fragment columns spanning the source image
	parameter int FRAGMENTS_MAX   = FRAGMENT_ROWS * FRAGMENT_COLS , // total fragments per temporal frame (13x13 = 169)
	parameter int TEMPORAL_FRAMES = 16                              // temporal frames replayed through the pipeline
)
(
	input  wire logic          clk           , // clock of system
	input  wire logic          rst           , // reset of system (soft)
	input  wire logic          arst_n        , // asynchronous reset (hard)
	input  wire logic          enable        , // enable of the controller
	input  wire logic          done_load_o   , // input done from mapping controller
	input  wire logic          conv_done_o   , // input done from mapping controller

	output wire logic [3199:0] mem_enable    , // shaaban unit output into spike memory stage1 (32 shaaban x 10 x 10)
	output wire logic [1:0]    stage         , // signal that defines which stage we are in
	output wire logic [2:0]    frame         , // signal that defines which frame we are in (16 frames)
	output wire logic          stage_sel     , // asserted when we are in a stage2,3
	output wire logic [5:0]    conv2_filter  , // which filter in stage2 we are using
	output wire logic [11:0]   conv3_filter  , // which filter in stage3 we are using
	output wire logic [5:0]    rd_mem_adderss, // read address from pixel + spike memory
	output wire logic [5:0]    wr_mem_adderss, // write address to spike memory
	output wire logic          zero_sel      , // clears a stage before it is used (stage2 before use, etc.)
	output wire logic          zero          , // not used
	output wire logic          rd_enable     , // not used in top module
	output wire logic          padding_flag  , // not used
	output wire logic          gap_valid     , // asserted once all frames are finished
	output wire logic          fetch_en_i    , // controls the state transition in mapping controller
	output wire logic          next_i        , // control signal for state transition in mapping controller
	output wire logic          done          , // done signal for global average pooling
	output wire logic[2:0]     stage2_last_frame_idx_o,
	output wire logic[2:0]	   shb_mem_en    ,
	output wire logic 		   special_row_col_ind
);

	//==========================================================================
	// Local Parameters
	//==========================================================================

	// -- Fragment / stage geometry --------------------------------------------
	localparam int FRAGMENT_SIDE    = 10                            ; // Stage-1 fragment side length (10x10 = 100 positions per full fragment)
	localparam int SPECIAL_SIDE     = 8                             ; // reduced pitch used for edge fragments that carry padding (8x8 / 8x10 / 10x8)
	localparam int STAGE1_CHANNELS  = 32                            ; // number of Stage-1 filters (Shaaban units)
	localparam int STAGE1_POSITIONS = FRAGMENT_SIDE * FRAGMENT_SIDE ; // Stage-1 positions in a full (non-edge) fragment = 100
	localparam int STAGE2_SIDE      = 4                             ; // Stage-2 output grid side length (4x4 = 16 positions)
	localparam int STAGE2_POSITIONS = STAGE2_SIDE * STAGE2_SIDE     ; // Stage-2 positions per fragment (16)
	localparam int STAGE2_FRAMES    = 6                             ; // Stage-2 "frames" per fragment: 5 full frames of 3 positions + 1 edge frame
	localparam int STAGE2_FILTERS   = 64                            ; // number of Stage-2 filters
	localparam int STAGE3_FILTERS   = 128                           ; // number of Stage-3 filters

	//==========================================================================
	// Inter-Module Connections
	//==========================================================================
	// FSM state and every iteration counter, driven by fsm_sequencer and
	// consumed by the geometry units / output mux below.
	state_t     state_q             ;
	logic [6:0] stage1_pos          ; // width = $clog2(STAGE1_POSITIONS) = 7
	logic [3:0] stage1_local_row_cnt;
	logic [3:0] stage1_local_col_cnt;
	logic [2:0] stage2_frame_idx    ; // width = $clog2(STAGE2_FRAMES) = 3
	logic [7:0] frag_row            ;
	logic [7:0] frag_col            ;
	logic       stage2_last         ;
	logic       temporal_last       ;

	// Per-fragment geometry, driven by the Stage-1/Stage-2 geometry units and
	// consumed by fsm_sequencer (to detect the end of each stage's sweep) and
	// by output_mux_unit (the resulting write masks).
	logic [7:0]    stage1_valid_positions;
	logic [3:0]    stage1_col_count      ;
	logic [2:0]    stage2_last_frame_idx ;
	logic [3199:0] stage1_mask           ;
	logic [3199:0] stage2_mask           ;

	//==========================================================================
	// Submodule Instantiations
	//==========================================================================
	stage1_geometry_unit #(
		.FRAGMENT_ROWS   (FRAGMENT_ROWS  ),
		.FRAGMENT_COLS   (FRAGMENT_COLS  ),
		.FRAGMENT_SIDE   (FRAGMENT_SIDE  ),
		.SPECIAL_SIDE    (SPECIAL_SIDE   ),
		.STAGE1_CHANNELS (STAGE1_CHANNELS)
	) u_stage1_geometry (
		.frag_row              (frag_row             ),
		.frag_col              (frag_col             ),
		.stage1_local_row_cnt  (stage1_local_row_cnt ),
		.stage1_local_col_cnt  (stage1_local_col_cnt ),
		.stage1_valid_positions(stage1_valid_positions),
		.stage1_col_count      (stage1_col_count      ),
		.stage1_mask           (stage1_mask           )
	);

	stage2_geometry_unit #(
		.FRAGMENT_ROWS   (FRAGMENT_ROWS  ),
		.FRAGMENT_COLS   (FRAGMENT_COLS  ),
		.STAGE2_SIDE     (STAGE2_SIDE    ),
		.STAGE2_POSITIONS(STAGE2_POSITIONS)
	) u_stage2_geometry (
		.frag_row             (frag_row             ),
		.frag_col             (frag_col             ),
		.stage2_frame_idx     (stage2_frame_idx     ),
		.conv2_filter         (conv2_filter         ),
		.stage                (stage   				),
		.stage2_last_frame_idx(stage2_last_frame_idx),
		.stage2_mask          (stage2_mask          ),
		.shb_mem_en           (shb_mem_en           ),
		.special_row_col_ind  (special_row_col_ind  )
	);

	fsm_sequencer #(
		.FRAGMENT_ROWS   (FRAGMENT_ROWS   ),
		.FRAGMENT_COLS   (FRAGMENT_COLS   ),
		.FRAGMENTS_MAX   (FRAGMENTS_MAX   ),
		.TEMPORAL_FRAMES (TEMPORAL_FRAMES ),
		.STAGE1_POSITIONS(STAGE1_POSITIONS),
		.STAGE2_FRAMES   (STAGE2_FRAMES   ),
		.STAGE2_FILTERS  (STAGE2_FILTERS  ),
		.STAGE3_FILTERS  (STAGE3_FILTERS  )
	) u_fsm_sequencer (
		.clk                   (clk                   ),
		.rst                   (rst                   ),
		.arst_n                (arst_n                ),
		.enable                (enable                ),
		.done_load_o           (done_load_o           ),
		.fetch_en_i            (fetch_en_i            ),
		.conv_done_o           (conv_done_o           ),
		.stage1_valid_positions(stage1_valid_positions),
		.stage1_col_count      (stage1_col_count      ),
		.stage2_last_frame_idx (stage2_last_frame_idx ),
		.state_q               (state_q               ),
		.stage1_pos            (stage1_pos            ),
		.stage1_local_row_cnt  (stage1_local_row_cnt  ),
		.stage1_local_col_cnt  (stage1_local_col_cnt  ),
		.stage2_frame_idx      (stage2_frame_idx      ),
		.conv2_filter          (conv2_filter          ),
		.conv3_filter          (conv3_filter          ),
		.fragment_counter      (                      ), // not needed outside fsm_sequencer; left unconnected
		.frag_row              (frag_row              ),
		.frag_col              (frag_col              ),
		.temporal_counter      (                      ), // not needed outside fsm_sequencer; left unconnected
		.stage2_last           (stage2_last           ),
		.temporal_last         (temporal_last         )
	);

	fetch_handshake_unit u_fetch_handshake (
		.clk        (clk        ),
		.rst        (rst        ),
		.arst_n     (arst_n     ),
		.done_load_o(done_load_o),
		.state_q    (state_q    ),
		.fetch_en_i (fetch_en_i )
	);

	output_mux_unit u_output_mux (
		.state_q         (state_q         ),
		.stage1_mask     (stage1_mask     ),
		.stage2_mask     (stage2_mask     ),
		.stage2_frame_idx(stage2_frame_idx),
		.conv3_filter    (conv3_filter    ),
		.stage2_last     (stage2_last     ),
		.temporal_last   (temporal_last   ),
		.mem_enable      (mem_enable      ),
		.stage           (stage           ),
		.frame           (frame           ),
		.stage_sel       (stage_sel       ),
		.rd_mem_adderss  (rd_mem_adderss  ),
		.wr_mem_adderss  (wr_mem_adderss  ),
		.zero_sel        (zero_sel        ),
		.zero            (zero            ),
		.rd_enable       (rd_enable       ),
		.padding_flag    (padding_flag    ),
		.gap_valid       (gap_valid       ),
		.next_i          (next_i          ),
		.done            (done            )
	);

	assign stage2_last_frame_idx_o = stage2_last_frame_idx;
endmodule : top_controller
