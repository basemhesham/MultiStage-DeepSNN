//==============================================================================
// Module      : stage2_geometry_unit
// Description :
//    Combinational Stage-2 geometry block for one fragment.
//      1) Computes how many of the fragment's 4x4 positions are actually
//         valid (border fragments lose their outermost row/col), the
//         starting corner of the valid sub-grid within the full 4x4 grid,
//         and the index of the last (possibly partial) "frame" of up to 3
//         positions -- exposed as stage2_last_frame_idx, which the FSM uses
//         (together with conv2_filter) to know when the Stage-2 sweep of
//         this fragment is complete.
//      2) Builds the write mask (stage2_mask) for up to 3 positions produced
//         in parallel this cycle (one per "slot"), for use as mem_enable
//         while in the STAGE2 state.
//
//    MEMORY LAYOUT: filter-major -- each conv2_filter owns one contiguous
//    16-slot (4x4) block, back to back:
//      addr = conv2_filter * STAGE2_POSITIONS    (16 slots per filter)
//           + local_row    * STAGE2_SIDE
//           + local_col
//
//    NOTE ON ARITHMETIC: several quantities here that would naturally
//    involve a division/modulo by a non-power-of-2, run-time-variable
//    divisor (stage2_col_count) are instead computed via explicit
//    shift-and-subtract (restoring division) sequences rather than the '/'
//    and '%' operators, to avoid inferring a variable-divisor hardware
//    divider.
//==============================================================================
module stage2_geometry_unit #(
	parameter int FRAGMENT_ROWS    = 32, // fragment rows spanning the source image
	parameter int FRAGMENT_COLS    = 32, // fragment columns spanning the source image
	parameter int STAGE2_SIDE      = 4 , // Stage-2 output grid side length (4x4 = 16 positions)
	parameter int STAGE2_POSITIONS = 16  // Stage-2 positions per fragment (STAGE2_SIDE * STAGE2_SIDE)
)
(
	input  wire logic [7:0] frag_row        , // fragment row index within the FRAGMENT_ROWS x FRAGMENT_COLS grid
	input  wire logic [7:0] frag_col        , // fragment column index within the FRAGMENT_ROWS x FRAGMENT_COLS grid
	input  wire logic [2:0] stage2_frame_idx, // current Stage-2 frame (group of up to 3 positions) within the fragment (from fsm_sequencer)
	input  wire logic [5:0] conv2_filter    , // current Stage-2 filter index (from fsm_sequencer)
	input  wire logic [1:0] stage           , // signal that defines which stage we are in

	output logic [2:0]		shb_mem_en      ,
	output logic [2:0]      stage2_last_frame_idx, // index of the last active stage2_frame_idx for this fragment
	output logic [3199:0]   stage2_mask          , // combined write mask for the current Stage-2 cycle (OR of all 3 slots)
	output logic 			special_row_col_ind    // indicates the specai case is in columns or not
);

	//==========================================================================
	// Stage-2 Valid-Position Count (per current fragment)
	//==========================================================================
	// Mirrors the Stage-1 border-clipping idea, but for the 4x4 Stage-2
	// output grid (STAGE2_SIDE), and additionally computes:
	//   - stage2_row_start/col_start : which corner of the full 4x4 grid the
	//     valid sub-grid starts at (border fragments lose their first
	//     row/col, so the valid data shifts into slots 1..3 instead of 0..2)
	//   - stage2_last_frame_idx      : index of the final (possibly partial)
	//     "frame" of up to 3 positions for this fragment
	//   - stage2_positions_in_frame  : how many of the (up to 3) positions in
	//     the *current* stage2_frame_idx are actually valid
	//--------------------------------------------------------------------------
	logic [2:0] stage2_row_count         ; // valid Stage-2 row count for this fragment (3 or 4)
	logic [2:0] stage2_col_count         ; // valid Stage-2 col count for this fragment (3 or 4)
	logic       stage2_row_start         ; // 1 if the valid sub-grid starts at row 1 (top-border fragment), else 0
	logic       stage2_col_start         ; // 1 if the valid sub-grid starts at col 1 (left-border fragment), else 0
	logic [4:0] stage2_valid_positions   ; // total valid Stage-2 positions for this fragment (9, 12, or 16)
	logic [1:0] stage2_positions_in_frame; // number of valid positions within the current stage2_frame_idx (1..3)

	// Shift-and-subtract (restoring division) helpers used to compute
	// stage2_last_frame_idx = (stage2_valid_positions - 1) / 3 without a
	// hardware '/' operator (up to 6 groups of up to 3 positions each).
	logic [4:0] stage2_lfi_dividend; // (stage2_valid_positions - 1), the value being divided by 3
	logic [2:0] stage2_lfi_rem     ; // running remainder shift-register
	logic [2:0] stage2_lfi_quot    ; // running quotient bits (result <= 5, so only bits [2:0] are ever meaningful)

	// Explicit-width helpers for stage2_positions_in_frame (avoids mixed-width
	// subtraction and arithmetic-inside-conditional lint warnings).
	logic [4:0] stage2_pif_offset; // stage2_frame_idx * 3 (first position index of the current frame), width-matched to stage2_valid_positions
	logic [4:0] stage2_pif_diff  ; // stage2_valid_positions - stage2_pif_offset (positions remaining from the current frame to the end of the fragment)

	always_comb
		begin
			// Valid sub-grid dimensions and starting corner for this fragment.
			stage2_row_count = ((frag_row == 0) || (frag_row == FRAGMENT_ROWS - 1)) ? (STAGE2_SIDE - 1) : STAGE2_SIDE;
			stage2_col_count = ((frag_col == 0) || (frag_col == FRAGMENT_COLS - 1)) ? (STAGE2_SIDE - 1) : STAGE2_SIDE;
			stage2_row_start = (frag_row == 0) ? 1'b1 : 1'b0;
			stage2_col_start = (frag_col == 0) ? 1'b1 : 1'b0;

			stage2_valid_positions = 5'(stage2_row_count * stage2_col_count);
			special_row_col_ind    = stage2_col_count[1];

			// stage2_last_frame_idx = (stage2_valid_positions - 1) / 3,
			// computed via 5-bit shift-and-subtract (restoring) division
			// instead of '/'. Each iteration shifts in one dividend bit
			// (MSB first) and subtracts the divisor (3) if it fits.
			stage2_lfi_dividend = stage2_valid_positions - 5'd1;
			stage2_lfi_rem      = '0;
			stage2_lfi_quot     = '0;

			// i = 4 (MSB): quotient bit would land above [2:0], so it is
			// intentionally not written (max quotient value is 5).
			stage2_lfi_rem = {stage2_lfi_rem[1:0], stage2_lfi_dividend[4]};
			if (stage2_lfi_rem >= 3'd3) begin
				stage2_lfi_rem = stage2_lfi_rem - 3'd3;
			end

			// i = 3: same as above, quotient bit not writable within [2:0].
			stage2_lfi_rem = {stage2_lfi_rem[1:0], stage2_lfi_dividend[3]};
			if (stage2_lfi_rem >= 3'd3) begin
				stage2_lfi_rem = stage2_lfi_rem - 3'd3;
			end

			// i = 2
			stage2_lfi_rem = {stage2_lfi_rem[1:0], stage2_lfi_dividend[2]};
			if (stage2_lfi_rem >= 3'd3) begin
				stage2_lfi_rem = stage2_lfi_rem - 3'd3;
				stage2_lfi_quot[2] = 1'b1;
			end

			// i = 1
			stage2_lfi_rem = {stage2_lfi_rem[1:0], stage2_lfi_dividend[1]};
			if (stage2_lfi_rem >= 3'd3) begin
				stage2_lfi_rem = stage2_lfi_rem - 3'd3;
				stage2_lfi_quot[1] = 1'b1;
			end

			// i = 0 (LSB)
			stage2_lfi_rem = {stage2_lfi_rem[1:0], stage2_lfi_dividend[0]};
			if (stage2_lfi_rem >= 3'd3) begin
				stage2_lfi_rem = stage2_lfi_rem - 3'd3;
				stage2_lfi_quot[0] = 1'b1;
			end
			stage2_last_frame_idx = stage2_lfi_quot;

			// Positions remaining in the current frame: 3 for every frame
			// except the final one, which may hold fewer (fragment edge).
			stage2_pif_offset = 5'(5'(stage2_frame_idx) * 5'd3);
			stage2_pif_diff   = stage2_valid_positions - stage2_pif_offset;

			stage2_positions_in_frame = (stage2_frame_idx == stage2_last_frame_idx) ? 2'(stage2_pif_diff) : 2'd3;
		end



		always_comb begin
			shb_mem_en = '0;
			if (stage == 1) begin
				//top_left_corner
				if (frag_col == 0 && frag_row == 0) begin
					if (stage2_frame_idx == 0) begin
						shb_mem_en [0] = 1;
					end
				end
				//top_right_corner
				else if (frag_col == 31 && frag_row == 0) begin
					if (stage2_frame_idx == 0) begin
						shb_mem_en  = 3'b111;
					end
				end
				//bottom_left_corner
				else if (frag_col == 0 && frag_row == 31) begin
					shb_mem_en[0]  = 1;
				end
				//bottom_right_corner
				else if (frag_col == 31 && frag_row == 31) begin
					shb_mem_en  = 3'b111;
				end
				//top_side
				else if (frag_row == 0) begin
					if (stage2_frame_idx == 0) begin
						shb_mem_en  = 3'b011;
					end
				end
				//bottom_side
				else if (frag_row == 31) begin
					if (stage2_frame_idx == 0) begin
						shb_mem_en  = 3'b011;
					end else if(stage2_frame_idx == 1) begin
						shb_mem_en  = 3'b110;
					end else if (stage2_frame_idx == 2) begin
						shb_mem_en  = 3'b100;
					end else if (stage2_frame_idx == 3) begin
						shb_mem_en  = 3'b001;
					end
				end
				//left_side
				else if (frag_col == 0) begin
					if (stage2_frame_idx == 0 || stage2_frame_idx == 1) begin
						shb_mem_en  = 3'b001;
					end
				end
				//right_side
				else if (frag_col == 31) begin
					if (stage2_frame_idx == 0 || stage2_frame_idx == 1) begin
						shb_mem_en  = 3'b111;
					end
				end
				//normal_case
				else begin
					if (stage2_frame_idx == 0) begin
						shb_mem_en  = 3'b011;
					end else if (stage2_frame_idx == 1) begin
						shb_mem_en  = 3'b110;
					end
				end
			end
			
		end

	//==========================================================================
	// Stage-2 Write Mask
	//==========================================================================
	// Only VALID positions are enumerated (no wasted cycles on border
	// rows/cols), but each valid output is still written to its true
	// position in the 4x4 grid (stage2_row_start/stage2_col_start shift the
	// valid sub-grid into the full grid, so the excluded border row/col
	// reads back as 0).
	//
	// e.g. a corner fragment (3x3 valid, top+left border) writes bits
	// {5,6,7}, {9,10,11}, {13,14,15} of its 16-slot block one cycle at a
	// time; the rest of that block stays 0. The next filter's block starts
	// 16 bits higher.
	//
	// Up to 3 positions are produced per cycle (one per "slot" 0..2, gated
	// by stage2_positions_in_frame for the final, possibly-partial frame).
	//--------------------------------------------------------------------------
	logic [3199:0] stage2_partial_mask [0:2]; // one partial mask per parallel slot (generate instance)
	logic [9:0]    stage2_base              ; // conv2_filter * STAGE2_POSITIONS -- start of this filter's 16-slot block

	always_comb
		begin
			stage2_base = conv2_filter * STAGE2_POSITIONS;
		end

	logic [9:0] stage2_slot_addr [0:2]; // per-slot bit address into the 3200-bit mem_enable mask
	generate
		for (genvar slot = 0; slot < 3; slot = slot + 1)
			begin : gen_stage2_pos
				logic [4:0] stage2_idx_g       ; // linear index over the VALID sub-grid for this slot (0 .. valid_positions-1)
				logic [2:0] stage2_sub_row_g   ; // row within the valid sub-grid
				logic [2:0] stage2_sub_col_g   ; // col within the valid sub-grid
				logic [2:0] stage2_actual_row_g; // row within the full 4x4 grid (after applying row_start offset)
				logic [2:0] stage2_actual_col_g; // col within the full 4x4 grid (after applying col_start offset)
				logic [2:0] stage2_div_quot    ; // shift-subtract quotient for stage2_idx_g / stage2_col_count (result <= 5, so only bits [2:0] are ever meaningful)
				logic [2:0] stage2_div_rem     ; // shift-subtract remainder for stage2_idx_g / stage2_col_count

				always_comb
					begin
						// Linear index of the position this slot produces this cycle:
						// each frame covers 3 positions, plus this slot's offset (0,1,2).
						stage2_idx_g = 5'(5'(stage2_frame_idx) * 5'd3) + 5'(slot);

						// stage2_sub_row_g = stage2_idx_g / stage2_col_count
						// stage2_sub_col_g = stage2_idx_g % stage2_col_count
						// computed via 5-bit shift-and-subtract (restoring) division
						// instead of '/' and '%' (small range: (0-15) / (3 or 4)).
						stage2_div_rem  = '0;
						stage2_div_quot = '0;
						for (int i = 4; i >= 0; i--)
							begin
								stage2_div_rem = {stage2_div_rem[1:0], stage2_idx_g[i]}; // shift in next dividend bit (MSB first)
								if (stage2_div_rem >= stage2_col_count)
									begin
										stage2_div_rem = stage2_div_rem - stage2_col_count; // subtract divisor when it fits
										if (i <= 2)
											stage2_div_quot[i] = 1'b1; // quotient <= 5, so bits above [2:0] are never set
									end
							end
						stage2_sub_row_g    = stage2_div_quot;
						stage2_sub_col_g    = stage2_div_rem;
						// Shift the valid sub-grid position into its true position
						// within the full 4x4 grid (border fragments start at row/col 1).
						stage2_actual_row_g = {2'd0, stage2_row_start} + stage2_sub_row_g;
						stage2_actual_col_g = {2'd0, stage2_col_start} + stage2_sub_col_g;

						// Final bit address: filter block base + (row * STAGE2_SIDE + col).
						stage2_slot_addr[slot] = stage2_base + 10'(10'(stage2_actual_row_g) * 10'(STAGE2_SIDE)) + 10'(stage2_actual_col_g);

						stage2_partial_mask[slot] = '0;
						if (slot < stage2_positions_in_frame)
							begin
								stage2_partial_mask[slot][stage2_slot_addr[slot]] = 1'b1; // only assert this slot's bit if it holds a valid position this frame
							end
					end
			end
	endgenerate

	assign stage2_mask = stage2_partial_mask[0] | stage2_partial_mask[1] | stage2_partial_mask[2]; // combine all 3 slots into one mask
	
endmodule : stage2_geometry_unit
