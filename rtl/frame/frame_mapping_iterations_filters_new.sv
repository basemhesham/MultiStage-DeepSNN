//===========================================================
// File        : mem_mapping.sv
// Purpose     : Maps flat memory buffer (mem[]) to per-filter,
//               per-window input slices (fil_in) based on the
//               current frame offset, supporting normal mode 
//               and 3 special grid mapping modes.
// Written by  : Hany Moahemd
// Editor      : Abdelrahman Khaled 
// Last edit   : 2026-09-15
//===========================================================
module mem_mapping #(
  parameter FRAME_NO          = 6,
  parameter FRAME_NO_WIDTH    = $clog2(FRAME_NO),
  parameter MEM_WORD          = 3200
) (
  //======================================================
  // Controls
  //======================================================
  input wire logic                       clk,
  input wire logic                       arst_n,
  //======================================================
  // Inputs
  //======================================================
  input wire logic [2:0]                 last_frame_idx,
  input wire logic                       special_special_row_col_ind,
  input wire logic [FRAME_NO_WIDTH-1:0]  frame,
  input wire logic [MEM_WORD-1:0]        mem,
  //======================================================
  // Outputs
  //======================================================
  output logic                           fil_in [0:31][0:39] // Adjust bit-width as per your design
);
localparam int MAX_IDX                   = 40;
localparam int COL_NO                    = 4;
localparam int FILTRS_NO                 = 32;
localparam int SPECIAL_ROW_SHIFT         = 256;
localparam int FRAME1_SPECIAL_BASE_START = 0;
localparam int FRAME2_SPECIAL_BASE_START = 512;
localparam int FRAME3_SPECIAL_BASE_START = 1024;
localparam int FRAME4_SPECIAL_BASE_START = 1536;

localparam int NORMAL_ROW_SHIFT          = 320;
localparam int FRAME1_NORMAL_BASE_START  = 0;
localparam int FRAME2_NORMAL_BASE_START  = 640;
localparam int FRAME2_OVERLAP_BASE_START = 192;
localparam int FRAME3_NORMAL_BASE_START  = 1280;
localparam int FRAME3_OVERLAP_BASE_START = 768;
localparam int FRAME4_NORMAL_BASE_START  = 1344;
localparam int FRAME5_NORMAL_BASE_START  = 1920;
localparam int FRAME6_NORMAL_BASE_START  = 2112;

//======================================================
// Mode-select signals: these depend only on last_frame_idx /
// special_special_row_col_ind, NOT on fil or idx, so they are
// computed once here instead of being replicated 32*40 times
// inside the generate loop below.
//======================================================
// my_wire_1 : "top" special-grid mode  -> frames 1-3 special mapping
wire logic my_wire_1 = (last_frame_idx[2] == 1'b0) && (last_frame_idx[0] == 1'b0);
// my_wire_2 : "special-special" mode    -> frames 1-4 special mapping
wire logic my_wire_2 = (last_frame_idx[2] == 1'b0) && (last_frame_idx[0] != 1'b0) && (special_special_row_col_ind == 1'b1);
// my_wire_3 : normal mode, no special row/col indication -> frames 1-4 normal mapping
wire logic my_wire_3 = (last_frame_idx[2] == 1'b0) && (last_frame_idx[0] != 1'b0) && (special_special_row_col_ind != 1'b1);
// my_wire_5 : last_frame_idx[2] set -> frames 1-6 normal mapping
wire logic my_wire_5 = (last_frame_idx[2] != 1'b0);

// special_en : frames 1-3 special mapping enable (frame 4 special uses my_wire_2 alone)
// normal_en  : frames 1-4 normal mapping enable
wire logic special_en = my_wire_1 || my_wire_2;
wire logic normal_en  = my_wire_3 || my_wire_5;

genvar fil,idx;

/*wire logic [17:0]        mem [MEM_WORD-1:0];
genvar i;
generate
    for (i = 0; i < MEM_WORD; i++) begin
        assign mem[i] = i;
    end
endgenerate*/

generate
    for  ( fil=0; fil < FILTRS_NO; fil++ ) begin
        for ( idx=0; idx< MAX_IDX; ++idx) begin
            localparam int col_tap = idx/COL_NO;
            localparam int row_tap = idx%COL_NO;
            localparam int my_special_row = SPECIAL_ROW_SHIFT*row_tap+col_tap*FILTRS_NO+fil;
            localparam int my_normal_row  = NORMAL_ROW_SHIFT*row_tap+col_tap*FILTRS_NO+fil;
            // Frame-2 mapping: overlap region for col_tap<4, else the non-overlapping normal region
            localparam int my_idx_4 = (col_tap < 4) ? (FRAME2_OVERLAP_BASE_START+my_normal_row)
                                                     : (FRAME2_NORMAL_BASE_START+NORMAL_ROW_SHIFT*row_tap+(col_tap-4)*FILTRS_NO+fil);
            // Frame-3 mapping: overlap region for col_tap<6, else the non-overlapping normal region
            localparam int my_idx_6 = (col_tap < 6) ? (FRAME3_OVERLAP_BASE_START+my_normal_row)
                                                     : (FRAME3_NORMAL_BASE_START+NORMAL_ROW_SHIFT*row_tap+(col_tap-6)*FILTRS_NO+fil);
            // Frame-6 mapping (only ever read when idx<16)
            localparam int my_idx_16 = FRAME6_NORMAL_BASE_START+my_normal_row;

            //===================================================================
            // Every decision below is a plain 2:1 mux (ternary), chained.
            // No if/else, no case.
            //===================================================================
            wire logic frame1_val = (special_en && idx < 32) ? mem[FRAME1_SPECIAL_BASE_START+my_special_row]
                                   : (normal_en  && idx < 32) ? mem[FRAME1_NORMAL_BASE_START+my_normal_row]
                                   : 1'b0;

            wire logic frame2_val = (special_en && idx < 32) ? mem[FRAME2_SPECIAL_BASE_START+my_special_row]
                                   : (normal_en)              ? mem[my_idx_4]
                                   : 1'b0;

            wire logic frame3_val = (special_en && idx < 32) ? mem[FRAME3_SPECIAL_BASE_START+my_special_row]
                                   : (normal_en)              ? mem[my_idx_6]
                                   : 1'b0;

            wire logic frame4_val = (my_wire_2  && idx < 32) ? mem[FRAME4_SPECIAL_BASE_START+my_special_row]
                                   : (normal_en  && idx < 32) ? mem[FRAME4_NORMAL_BASE_START+my_normal_row]
                                   : 1'b0;

            wire logic frame5_val = (my_wire_5 && idx < 32) ? mem[FRAME5_NORMAL_BASE_START+my_normal_row]
                                   : 1'b0;

            wire logic frame6_val = (my_wire_5 && idx < 16) ? mem[my_idx_16]                                    // mux_in__11
                                   : 1'b0;

            // Final frame select: a chain of 2:1 muxes on `frame`.
            assign fil_in[fil][idx] = (frame == 3'd6) ? frame6_val
                                     : (frame == 3'd5) ? frame5_val
                                     : (frame == 3'd4) ? frame4_val
                                     : (frame == 3'd3) ? frame3_val
                                     : (frame == 3'd2) ? frame2_val
                                     : (frame == 3'd1) ? frame1_val
                                     : 1'b0;
        end
    end

endgenerate

endmodule
