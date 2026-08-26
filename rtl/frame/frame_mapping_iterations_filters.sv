//===========================================================
// File        : mem_mapping.sv
// Purpose     : Maps flat memory buffer (mem[]) to per-filter,
//               per-window input slices (fil_in) based on the
//               current frame offset, supporting normal mode 
//               and 3 special grid mapping modes.
// Written by  : Hany Mohamed
// Editor      : Manar Abdo
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
        for ( idx=0; idx<MAX_IDX; ++idx) begin
            localparam int col_tap = idx/COL_NO;
            localparam int row_tap = idx%COL_NO;
            always_comb begin
                fil_in[fil][idx] = 0;
                if (last_frame_idx[2] == 0) begin
                    if (last_frame_idx[0] == 0) begin
                        if (idx < 32) begin
                            case (frame)
                                1: fil_in[fil][idx] = mem[FRAME1_SPECIAL_BASE_START+SPECIAL_ROW_SHIFT*row_tap+col_tap*FILTRS_NO+fil];
                                2: fil_in[fil][idx] = mem[FRAME2_SPECIAL_BASE_START+SPECIAL_ROW_SHIFT*row_tap+col_tap*FILTRS_NO+fil];
                                3: fil_in[fil][idx] = mem[FRAME3_SPECIAL_BASE_START+SPECIAL_ROW_SHIFT*row_tap+col_tap*FILTRS_NO+fil];
                                default: fil_in[fil][idx] =0;
                            endcase
                        end
                    end else begin
                        if (special_special_row_col_ind == 1) begin
                            if (idx < 32) begin
                                case (frame)
                                    1: fil_in[fil][idx] = mem[FRAME1_SPECIAL_BASE_START+SPECIAL_ROW_SHIFT*row_tap+col_tap*FILTRS_NO+fil];
                                    2: fil_in[fil][idx] = mem[FRAME2_SPECIAL_BASE_START+SPECIAL_ROW_SHIFT*row_tap+col_tap*FILTRS_NO+fil];
                                    3: fil_in[fil][idx] = mem[FRAME3_SPECIAL_BASE_START+SPECIAL_ROW_SHIFT*row_tap+col_tap*FILTRS_NO+fil];
                                    4: fil_in[fil][idx] = mem[FRAME4_SPECIAL_BASE_START+SPECIAL_ROW_SHIFT*row_tap+col_tap*FILTRS_NO+fil];
                                    default: fil_in[fil][idx] =0;
                                endcase
                            end
                        end else begin
                            case (frame)
                            1: fil_in[fil][idx] = (idx<32)?     mem[FRAME1_NORMAL_BASE_START+NORMAL_ROW_SHIFT*row_tap+col_tap*FILTRS_NO+fil] : 0;
                            2: fil_in[fil][idx] = (col_tap <4)? mem[FRAME2_OVERLAP_BASE_START+NORMAL_ROW_SHIFT*row_tap+col_tap*FILTRS_NO+fil] : mem[FRAME2_NORMAL_BASE_START+NORMAL_ROW_SHIFT*row_tap+(col_tap-4)*FILTRS_NO+fil];
                            3: fil_in[fil][idx] = (col_tap <6)? mem[FRAME3_OVERLAP_BASE_START+NORMAL_ROW_SHIFT*row_tap+col_tap*FILTRS_NO+fil] : mem[FRAME3_NORMAL_BASE_START+NORMAL_ROW_SHIFT*row_tap+(col_tap-6)*FILTRS_NO+fil];
                            4: fil_in[fil][idx] = (idx<32)?     mem[FRAME4_NORMAL_BASE_START+NORMAL_ROW_SHIFT*row_tap+col_tap*FILTRS_NO+fil] : 0;
                            default: fil_in[fil][idx] =0;
                        endcase
                        end
                    end
                end else begin
                    case (frame)
                            1: fil_in[fil][idx] = (idx<32)?     mem[FRAME1_NORMAL_BASE_START+NORMAL_ROW_SHIFT*row_tap+col_tap*FILTRS_NO+fil] : 0;
                            2: fil_in[fil][idx] = (col_tap <4)? mem[FRAME2_OVERLAP_BASE_START+NORMAL_ROW_SHIFT*row_tap+col_tap*FILTRS_NO+fil] : mem[FRAME2_NORMAL_BASE_START+NORMAL_ROW_SHIFT*row_tap+(col_tap-4)*FILTRS_NO+fil];
                            3: fil_in[fil][idx] = (col_tap <6)? mem[FRAME3_OVERLAP_BASE_START+NORMAL_ROW_SHIFT*row_tap+col_tap*FILTRS_NO+fil] : mem[FRAME3_NORMAL_BASE_START+NORMAL_ROW_SHIFT*row_tap+(col_tap-6)*FILTRS_NO+fil];
                            4: fil_in[fil][idx] = (idx<32)?     mem[FRAME4_NORMAL_BASE_START+NORMAL_ROW_SHIFT*row_tap+col_tap*FILTRS_NO+fil] : 0;
                            5: fil_in[fil][idx] = (idx<32)?     mem[FRAME5_NORMAL_BASE_START+NORMAL_ROW_SHIFT*row_tap+col_tap*FILTRS_NO+fil] : 0;
                            6: fil_in[fil][idx] = (idx<16)?     mem[(idx<16)? FRAME6_NORMAL_BASE_START+NORMAL_ROW_SHIFT*row_tap+col_tap*FILTRS_NO+fil : 0] : 0;
                            default: fil_in[fil][idx] =0;
                        endcase
                    end
            end
        end
    end

endgenerate

endmodule
