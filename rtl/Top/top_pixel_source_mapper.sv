//===========================================================
// File        : top_pixel_source_mapper.sv
// Purpose     : Selects among three staged pixel-mapping
//               pipelines and routes the selected 12×32×9
//               pixel window array to the output based on
//               src_sel. Supports raw patch extraction,
//               convolution-window mapping, and spike-binned
//               window mapping for the convolution datapath.
// Used in     : ASA convolution datapath top-level
//               (feeds top_conv9_array)
//===========================================================
// Written by  : --
// revised by  : Yousef Gamal
// Last edit   : 2026-07-07
// Version     : 1.0
//===========================================================

module top_pixel_source_mapper #(
	parameter int PIXEL_W        = 18,
	parameter int FRAC_BITS      = 9,
	parameter int FRAME_NO       = 6,
	parameter int FRAME_NO_WIDTH = 3
)
(
	input  logic                      clk           , // Clock signal
	input  logic                      rst_n         , // Async active-low reset
	input  logic [1:0]                src_sel       , // Pixel source select (00/01/10)
	input  logic [FRAME_NO_WIDTH-1:0] frame         , // Active frame index
	input  logic [(384*PIXEL_W)-1:0]  pixel_mem_data, // Packed stage-1 pixel memory
	input  logic [3199:0]             spike_mem_data, // Packed spike memory bits
	output logic signed [PIXEL_W-1:0] pixels_mapped [0:11][0:31][0:8] // Selected mapped pixels
);

	//-----------------------------------------------------------------------------
	// internal signals
	//-----------------------------------------------------------------------------
	logic signed [PIXEL_W-1:0] in_mem         [0:383]          ; // Unpacked stage-1 raw pixel memory
	logic signed [PIXEL_W-1:0] pixels_s1      [0:11][0:31][0:8]; // Stage-1 mapped pixel patches
	logic                      fil_in         [31:0][39:0]     ; // Filtered spike input bins
	logic                      conv_windows   [31:0][11:0][8:0]; // Stage-2 convolution windows
	logic signed [PIXEL_W-1:0] pixels_s2      [0:11][0:31][0:8]; // Stage-2 mapped pixel patches
	logic                      stage3_mem     [0:1023]         ; // Unpacked stage-3 spike memory
	logic                      stage3_windows [0:8][0:3][0:63] ; // Stage-3 binned windows
	logic signed [PIXEL_W-1:0] pixels_s3      [0:11][0:31][0:8]; // Stage-3 mapped pixel patches

	//-----------------------------------------------------------------------------
	// Stage 1 - Unpack raw pixel memory into signed samples
	//-----------------------------------------------------------------------------
	genvar m;
	generate
		for (m = 0; m < 384; m++)
			begin : gen_inmem
				assign in_mem[m] = $signed(pixel_mem_data[m*PIXEL_W +: PIXEL_W]);
			end
	endgenerate

	// Maps (block, lane) -> flattened stream index, with a per-block-group
	// lane rotation so adjacent output blocks read overlapping patch columns.
	function automatic int stage1_stream_index(
		input int block,
		input int lane
	);
		begin
			case (block % 3)
				0: stage1_stream_index = (block * 32) + lane;
				1: stage1_stream_index = (block * 32) +
										 ((lane < 30) ? lane + 1 :
										  (lane == 30) ? 0 : 31);
				default:
				   stage1_stream_index = (block * 32) +
										 ((lane < 30) ? lane + 2 : lane - 30);
			endcase
		end
	endfunction

	// Maps (stream_index, tap) -> index into a flattened 6x6 patch buffer.
	function automatic int stage1_patch_index(
		input int stream_index,
		input int tap
	);
		int conv_output;
		int chunk;
		int padded_kernel_index;
		int kernel_index;
		int kernel_row;
		int kernel_col;
		int window;
		int window_row;
		int window_col;
		begin
			conv_output         = stream_index / 3;
			chunk               = stream_index % 3;
			padded_kernel_index = (chunk * 9) + tap;

			if (padded_kernel_index == 9 || padded_kernel_index == 18)
				begin
					kernel_index = 0;
				end
			else if (padded_kernel_index > 18)
				begin
					kernel_index = padded_kernel_index - 2;
				end
			else if (padded_kernel_index > 9)
				begin
					kernel_index = padded_kernel_index - 1;
				end
			else
				begin
					kernel_index = padded_kernel_index;
				end

			// CONV1 weights are column-major. Four adjacent outputs share
			// one row-major 6x6 patch stored in pixel_mem_data[0:35].
			kernel_row = kernel_index % 5;
			kernel_col = kernel_index / 5;
			window     = conv_output % 4;
			window_row = window / 2;
			window_col = window % 2;

			stage1_patch_index =
				((kernel_row + window_row) * 6) + kernel_col + window_col;
		end
	endfunction

	//-----------------------------------------------------------------------------
	// Stage 1 - Map stage-1 patches to the [12][32][9] pixel layout
	//-----------------------------------------------------------------------------
	genvar gp1, cp1, tp1;
	generate
		for (gp1 = 0; gp1 < 12; gp1++)
			begin : gen_ps1_row
				for (cp1 = 0; cp1 < 32; cp1++)
					begin : gen_ps1_col
						for (tp1 = 0; tp1 < 9; tp1++)
							begin : gen_ps1_tap
								localparam int STREAM_INDEX = stage1_stream_index(gp1, cp1);
								localparam int PATCH_INDEX  = stage1_patch_index(STREAM_INDEX, tp1);

								assign pixels_s1[gp1][cp1][tp1] = in_mem[PATCH_INDEX];
							end
					end
			end
	endgenerate

	//-----------------------------------------------------------------------------
	// Stage 2 - Map spike memory through frame filtering into fixed-point windows
	//-----------------------------------------------------------------------------
	// Spike-memory frame mapping - selects and filters the active frame's bins
	mem_mapping #(.FRAME_NO (FRAME_NO), .FRAME_NO_WIDTH (FRAME_NO_WIDTH), .MEM_WORD (3200)) u_mem_mapping
	(
		.clk    (clk)           ,
		.arst_n (rst_n)         ,
		.frame  (frame)         ,
		.mem    (spike_mem_data),
		.fil_in (fil_in)
	);

	genvar fi;
	generate
		for (fi = 0; fi < 32; fi++)
			begin : gen_frame_mapping
				// Per-bin convolution-window extraction for this frame slice
				frame_input_mapping u_frame_map
				(
					.frame (frame[2:0]),
					.in    (fil_in[fi]),
					.conv  (conv_windows[fi])
				);
			end
	endgenerate

	//-----------------------------------------------------------------------------
	// Stage 2 - Zero-pad convolution windows into the [12][32][9] pixel layout
	//-----------------------------------------------------------------------------
	genvar gp2, cp2, tp2;
	generate
		for (gp2 = 0; gp2 < 12; gp2++)
			begin : gen_ps2_row
				for (cp2 = 0; cp2 < 32; cp2++)
					begin : gen_ps2_col
						for (tp2 = 0; tp2 < 9; tp2++)
							begin : gen_ps2_tap
								assign pixels_s2[gp2][cp2][tp2] = {{(PIXEL_W-FRAC_BITS-1){1'b0}}, conv_windows[cp2][gp2][tp2], {FRAC_BITS{1'b0}}};
							end
					end
			end
	endgenerate

	//-----------------------------------------------------------------------------
	// Stage 3 - Unpack spike memory and re-bin through the mux stage
	//-----------------------------------------------------------------------------
	genvar sm;
	generate
		for (sm = 0; sm < 1024; sm++)
			begin : gen_stage3_mem_unpack
				assign stage3_mem[sm] = spike_mem_data[sm];
			end
	endgenerate

	// Stage-3 binning mux - re-slices stage3_mem into windowed form
	bin_muxing_stage2 u_stage3_bin_mux
	(
		.din  (stage3_mem)   ,
		.dout (stage3_windows)
	);

	//-----------------------------------------------------------------------------
	// Stage 3 - Map binned windows to the [12][32][9] pixel layout
	//-----------------------------------------------------------------------------
	genvar win3, ch3, tap3;
	generate
		for (win3 = 0; win3 < 4; win3++)
			begin : gen_ps3_window
				for (ch3 = 0; ch3 < 32; ch3++)
					begin : gen_ps3_channel
						for (tap3 = 0; tap3 < 9; tap3++)
							begin : gen_ps3_tap
								assign pixels_s3[(win3 * 2)    ][ch3][tap3] =
									{{(PIXEL_W-FRAC_BITS-1){1'b0}}, stage3_windows[tap3][win3][ch3]     , {FRAC_BITS{1'b0}}};

								assign pixels_s3[(win3 * 2) + 1][ch3][tap3] =
									{{(PIXEL_W-FRAC_BITS-1){1'b0}}, stage3_windows[tap3][win3][ch3 + 32], {FRAC_BITS{1'b0}}};
							end
					end
			end
	endgenerate

	// Rows 8-11 have no stage-3 source data; tie them to zero
	genvar zrow3, zch3, ztap3;
	generate
		for (zrow3 = 8; zrow3 < 12; zrow3++)
			begin : gen_ps3_zero_row
				for (zch3 = 0; zch3 < 32; zch3++)
					begin : gen_ps3_zero_channel
						for (ztap3 = 0; ztap3 < 9; ztap3++)
							begin : gen_ps3_zero_tap
								assign pixels_s3[zrow3][zch3][ztap3] = '0;
							end
					end
			end
	endgenerate

	//-----------------------------------------------------------------------------
	// Output Mux - select final pixel source per src_sel
	//-----------------------------------------------------------------------------
	genvar gm, cm, tm;
	generate
		for (gm = 0; gm < 12; gm++)
			begin : gen_pmux_row
				for (cm = 0; cm < 32; cm++)
					begin : gen_pmux_col
						for (tm = 0; tm < 9; tm++)
							begin : gen_pmux_tap
								always_comb
									begin
										case (src_sel)
											2'b00:   pixels_mapped[gm][cm][tm] = pixels_s1[gm][cm][tm];
											2'b01:   pixels_mapped[gm][cm][tm] = pixels_s2[gm][cm][tm];
											2'b10:   pixels_mapped[gm][cm][tm] = pixels_s3[gm][cm][tm];
											default: pixels_mapped[gm][cm][tm] = pixels_s1[gm][cm][tm];
										endcase
									end
							end
					end
			end
	endgenerate

endmodule
