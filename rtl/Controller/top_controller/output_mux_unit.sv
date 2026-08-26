//==============================================================================
// Module      : output_mux_unit
// Description :
//    Combinational output logic. Drives every state-dependent output signal
//    from the current FSM state and the write masks / "last position" flags
//    supplied by the other submodules. Default values are established first,
//    then overridden per-state in the case statement below. next_i and done
//    are computed directly from state_q and are therefore not overridden by
//    any case branch below.
//==============================================================================
module output_mux_unit
	import top_controller_pkg::*;
(
	input  wire state_t                     state_q         , // current FSM state (from fsm_sequencer)
	input  wire logic [3199:0]              stage1_mask     , // Stage-1 write mask (from stage1_geometry_unit)
	input  wire logic [3199:0]              stage2_mask     , // Stage-2 write mask (from stage2_geometry_unit)
	input  wire logic [2:0]                 stage2_frame_idx, // current Stage-2 frame index (from fsm_sequencer)
	input  wire logic [11:0]                conv3_filter    , // current Stage-3 filter index (from fsm_sequencer)
	input  wire logic                       stage2_last     , // final Stage-2 frame of the final Stage-2 filter (from fsm_sequencer)
	input  wire logic                       temporal_last   , // final temporal frame of the run (from fsm_sequencer)

	output logic [3199:0] mem_enable    , // shaaban unit output into spike memory stage1 (32 shaaban x 10 x 10)
	output logic [1:0]    stage         , // signal that defines which stage we are in
	output logic [2:0]    frame         , // signal that defines which frame we are in (16 frames)
	output logic          stage_sel     , // asserted when we are in a stage2,3
	output logic [5:0]    rd_mem_adderss, // read address from pixel + spike memory
	output logic [5:0]    wr_mem_adderss, // write address to spike memory
	output logic          zero_sel      , // clears a stage before it is used (stage2 before use, etc.)
	output logic          zero          , // not used
	output logic          rd_enable     , // not used in top module
	output logic          padding_flag  , // not used
	output logic          gap_valid     , // asserted once all frames are finished
	output logic          next_i        , // control signal for state transition in mapping controller
	output logic          done            // done signal for global average pooling
);

	always_comb
		begin
			mem_enable     = '0;
			rd_enable      = 1'b0;
			stage          = 2'b11;
			frame          = 3'd1;
			stage_sel      = 1'b0;
			rd_mem_adderss = 6'd0;
			wr_mem_adderss = 6'd0;
			zero           = 1'b0;
			zero_sel       = 1'b0;
			padding_flag   = 1'b0;
			gap_valid      = 1'b0;
			next_i         = (state_q == STAGE2 || state_q == STAGE3); // requests the mapping controller to advance while running Stage2/3
			done           = (state_q == DONE);

			unique case (state_q)
				CLEAR_STAGE2_WORD:
					begin
						// Zero the entire Stage-2 memory word ahead of the first Stage1 pass.
						mem_enable     = '1;
						wr_mem_adderss = 6'd0;
						zero_sel       = 1'b1;
						padding_flag   = 1'b1;
					end

				STAGE1:
					begin
						stage          = 2'b00;
						mem_enable     = stage1_mask; // 32-channel group for the current fragment position
						wr_mem_adderss = 6'd0;
					end

				CLEAR_STAGE3_WORD:
					begin
						// Zero the entire Stage-3 memory word ahead of the first Stage2 pass.
						mem_enable     = '1;
						wr_mem_adderss = 6'd1;
						zero_sel       = 1'b1;
						padding_flag   = 1'b1;
					end

				STAGE2:
					begin
						stage          = 2'b01;
						frame          = stage2_frame_idx + 3'd1; // 1-based frame number for external reporting
						stage_sel      = 1'b1;
						rd_enable      = 1'b1;
						rd_mem_adderss = stage2_last ? 6'd1 : 6'd0; // read from Stage-1's memory, except the last cycle which reads back Stage-2's own word
						wr_mem_adderss = 6'd1;
						mem_enable     = stage2_mask; // up to 3 valid-position bits for the current frame/filter
					end

				STAGE3:
					begin
						stage                    = 2'b10;
						stage_sel                = 1'b1;
						rd_enable                = 1'b1;
						rd_mem_adderss           = 6'd1;
						wr_mem_adderss           = 6'd2;
						mem_enable[conv3_filter] = 1'b1; // single bit for the current Stage-3 filter
						gap_valid                = temporal_last; // signal global-average-pooling validity once all temporal frames are done
					end

				default:
					begin
						// IDLE / DONE: identical to the defaults established above;
						// re-asserted here for an exhaustive, tool-friendly case statement.
						mem_enable     = '0;
						rd_enable      = 1'b0;
						stage          = 2'b11;
						frame          = 3'd1;
						stage_sel      = 1'b0;
						rd_mem_adderss = 6'd0;
						wr_mem_adderss = 6'd0;
						zero           = 1'b0;
						zero_sel       = 1'b0;
						padding_flag   = 1'b0;
						gap_valid      = 1'b0;
						next_i         = (state_q == STAGE2 || state_q == STAGE3);
						done           = (state_q == DONE);
					end
			endcase
		end

endmodule : output_mux_unit
