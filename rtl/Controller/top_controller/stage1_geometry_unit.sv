//==============================================================================
// Module      : stage1_geometry_unit
// Description :
//    Combinational Stage-1 geometry block for one fragment.
//      1) Computes how many of the fragment's 10x10 positions are actually
//         valid (border fragments lose their outermost 3 rows and/or
//         columns) -- exposed as stage1_valid_positions, which the FSM uses
//         to know when the Stage-1 sweep of this fragment is complete.
//      2) Builds the one-hot-per-channel-group write mask (stage1_mask) for
//         whichever position the FSM is currently pointing at
//         (stage1_local_row_cnt / stage1_local_col_cnt), for use as
//         mem_enable while in the STAGE1 state.
//
//    NOTE ON ARITHMETIC: row/col position within the fragment is tracked via
//    the running stage1_local_row_cnt/stage1_local_col_cnt counters supplied
//    by the FSM, rather than being derived combinationally here via
//    divide/modulo of a linear position by stage1_col_count (a variable,
//    non-power-of-2 divisor).
//==============================================================================
module stage1_geometry_unit #(
	parameter int FRAGMENT_ROWS   = 32, // fragment rows spanning the source image
	parameter int FRAGMENT_COLS   = 32, // fragment columns spanning the source image
	parameter int FRAGMENT_SIDE   = 10, // Stage-1 fragment side length (10x10 = 100 positions per full fragment)
	parameter int SPECIAL_SIDE    = 8 , // reduced pitch used for edge fragments that carry padding (8x8 / 8x10 / 10x8)
	parameter int STAGE1_CHANNELS = 32  // number of Stage-1 filters (Shaaban units)
)
(
	input  wire logic [7:0] frag_row            , // fragment row index within the FRAGMENT_ROWS x FRAGMENT_COLS grid
	input  wire logic [7:0] frag_col            , // fragment column index within the FRAGMENT_ROWS x FRAGMENT_COLS grid
	input  wire logic [3:0] stage1_local_row_cnt, // running Stage-1 row counter within the current fragment (from fsm_sequencer)
	input  wire logic [3:0] stage1_local_col_cnt, // running Stage-1 col counter within the current fragment (from fsm_sequencer)

	output logic [7:0]      stage1_valid_positions, // total valid Stage-1 positions for this fragment = row_count * col_count (max 100)
	output logic [3:0]      stage1_col_count      , // valid col count for this fragment (also needed by fsm_sequencer, to know when to wrap the local column counter)
	output logic [3199:0]   stage1_mask             // one-hot-per-channel-group write mask for the current Stage-1 position
);

	//==========================================================================
	// Stage-1 Valid-Position Count (per current fragment)
	//==========================================================================
	// A fragment on the top/bottom border of the image loses its outermost
	// 3 rows (they belong to a neighboring fragment / are outside the image),
	// and likewise for left/right border fragments and columns. This block
	// computes how many rows/columns of the 10x10 fragment are actually valid
	// for Stage-1, and the resulting position count.
	//--------------------------------------------------------------------------
	logic [3:0] stage1_row_count; // valid row count for this fragment (FRAGMENT_SIDE, or FRAGMENT_SIDE-3 on a top/bottom border)
	// stage1_col_count (valid col count for this fragment) is a module output declared above.

	always_comb
		begin
			stage1_row_count = ((frag_row == 0) || (frag_row == FRAGMENT_ROWS - 1)) ? (FRAGMENT_SIDE - 3) : FRAGMENT_SIDE; // clip rows on top/bottom border fragments
			stage1_col_count = ((frag_col == 0) || (frag_col == FRAGMENT_COLS - 1)) ? (FRAGMENT_SIDE - 3) : FRAGMENT_SIDE; // clip cols on left/right border fragments

			stage1_valid_positions = stage1_row_count * stage1_col_count; // valid position count for this fragment
		end

	//==========================================================================
	// Stage-1 Write Mask
	//==========================================================================
	// Builds the one-hot-per-channel-group mask driven into mem_enable while
	// in the STAGE1 state: for the current fragment position, the
	// STAGE1_CHANNELS (32) contiguous bits corresponding to that position's
	// address are set, all others are 0.
	//
	// stage1_local_row / stage1_local_col below give this position's row/col
	// *within the physical fragment buffer* (they include the row/col_start
	// offset so that border fragments' valid data lines up with its true
	// position rather than starting at 0). They are derived from the running
	// stage1_local_row_cnt / stage1_local_col_cnt counters rather than by
	// dividing/moduloing the linear position by stage1_col_count (a variable,
	// non-power-of-2 divisor).
	//--------------------------------------------------------------------------
	logic       stage1_row_start ; // 1 if this fragment's valid data starts at physical row 1 (top-border fragment), else 0
	logic       stage1_col_start ; // 1 if this fragment's valid data starts at physical col 1 (left-border fragment), else 0
	logic [7:0] stage1_local_row ; // physical row of the current position within the fragment buffer
	logic [4:0] stage1_local_col ; // physical col of the current position within the fragment buffer
	logic [40:0] stage1_base      ; // bit address (into the 3200-bit mem_enable mask) of the first of this position's 32 channel bits
	logic [17:0] stage1_row_x_side; // stage1_local_row * (SPECIAL_SIDE or FRAGMENT_SIDE) -- row contribution to the address, width-matched to stage1_base[17:0]

	always_comb
		begin
			stage1_row_start = (frag_row == 0) ? 1 : 0;
			stage1_col_start = (frag_col == 0) ? 1 : 0;
			stage1_local_row = {7'd0, stage1_row_start} + {4'd0, stage1_local_row_cnt}; // shift the running row counter into its true physical row
			stage1_local_col = {4'd0, stage1_col_start} + {1'd0, stage1_local_col_cnt}; // shift the running col counter into its true physical col

			// Row stride (pitch) of the physical fragment buffer: fragments
			// whose column count is clipped to 7 (left/right border, see
			// stage1_col_count above) use the reduced SPECIAL_SIDE(8) pitch;
			// all other fragments use the full FRAGMENT_SIDE(10) pitch.
			if (stage1_col_count == 7)
				begin
					stage1_row_x_side = 18'(18'(stage1_local_row) * 18'(SPECIAL_SIDE));
				end
			else
				begin
					stage1_row_x_side = 18'(18'(stage1_local_row) * 18'(FRAGMENT_SIDE));
				end

			// Bit address = (row * pitch + col) * STAGE1_CHANNELS -- each
			// (row, col) position owns one contiguous 32-bit channel group.
			stage1_base[17:0] = 18'((stage1_row_x_side + 18'(stage1_local_col)) * 18'(STAGE1_CHANNELS));

			stage1_base[40:18] = 0; // upper address bits unused (18 bits are sufficient), forced to 0

			stage1_mask = '0;
			stage1_mask[stage1_base +: STAGE1_CHANNELS] = {STAGE1_CHANNELS{1'b1}}; // set this position's 32-channel group
		end

endmodule : stage1_geometry_unit
