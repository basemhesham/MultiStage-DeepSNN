// Generated SystemVerilog mapping logic
//===========================================================
// File        : frame_input_mapping.sv
// Purpose     : Maps flat frame input (in[]) to 12 output windows
//               (conv[12][9]), each holding a 3x3 im2col-style patch,
//               selected based on the current frame offset.
// Used in     : CNN Accelerator top-level (frame/window mapping stage)
//===========================================================
// Written by  : Hany Moahemd
// Editor      : Manar Abdo
// Last edit   : 2026-07-07
//===========================================================
module frame_input_mapping (

    //=======================================================
    // Inputs
    //=======================================================
    input wire logic [2:0] frame,
    input wire logic /*[17:0]*/    in [40],
    input wire logic [2:0] last_frame_idx,
    input wire logic       special_special_row_col_ind,
    //=======================================================
    // Outputs
    //=======================================================
    output     logic /*[17:0]*/      conv [12][9]
);
localparam int CONV_NO  = 12;
localparam int INPUT_NO = 9;
localparam int ROW_NO   = 3;
//NORMAL DISTRIBUTION ON THE 12 CONV UNIT
//FIRST SHAABAN OUT
localparam int CONV0_IDX  = 0;
localparam int CONV1_IDX  = 4;
localparam int CONV2_IDX  = 1;
localparam int CONV3_IDX  = 5;

//SECOND SHAABAN OUT
localparam int CONV4_IDX  = 8;
localparam int CONV5_IDX  = 12;
localparam int CONV6_IDX  = 9;
localparam int CONV7_IDX  = 13;

//THIRD SHAABAN OUT
localparam int CONV8_IDX  = 16;
localparam int CONV9_IDX  = 20;
localparam int CONV10_IDX = 17;
localparam int CONV11_IDX = 21;

//SPECIAL DISTRIBUTION ON THE 12 CONV UNIT (FRAME 1)
//FIRST SHAABAN OUT (AS THE NORMAL)

//SECOND SHAABAN OUT
localparam int CONV4_SPECIAL_IDX  = 16;
localparam int CONV5_SPECIAL_IDX  = 20;
localparam int CONV6_SPECIAL_IDX  = 17;
localparam int CONV7_SPECIAL_IDX  = 21;

//THIRD SHAABAN OUT
localparam int CONV8_SPECIAL_IDX  = 24;
localparam int CONV9_SPECIAL_IDX  = 28;
localparam int CONV10_SPECIAL_IDX = 25;
localparam int CONV11_SPECIAL_IDX = 29;

//SPECIAL DISTRIBUTION ON THE 12 CONV UNIT (FRAME 2)
//FIRST SHAABAN OUT (AS THE NORMAL)

//SECOND SHAABAN OUT (AS THE NORMAL)

//THIRD SHAABAN OUT (AS THE SPECIAL FRAME (1))


genvar conv_idx,in_idx;
generate;
    for (conv_idx = 0; conv_idx < CONV_NO; conv_idx++) begin
        for ( in_idx= 0; in_idx < INPUT_NO; in_idx++ ) begin
             localparam int adding = in_idx/ROW_NO;
             always_comb begin
                conv[conv_idx][in_idx] = 0;
                if (last_frame_idx == 2 || (last_frame_idx == 3 && special_special_row_col_ind == 1)) begin // FRAMES ARE ALWAYS (4*8)
                   case (conv_idx)
                      0:conv[conv_idx][in_idx] = in[CONV0_IDX + in_idx + adding];
                      1:conv[conv_idx][in_idx] = in[CONV1_IDX + in_idx + adding];
                      2:conv[conv_idx][in_idx] = in[CONV2_IDX + in_idx + adding];
                      3:conv[conv_idx][in_idx] = in[CONV3_IDX + in_idx + adding];
                      4:conv[conv_idx][in_idx] = in[CONV4_IDX + in_idx + adding];
                      5:conv[conv_idx][in_idx] = in[CONV5_IDX + in_idx + adding];
                      6:conv[conv_idx][in_idx] = in[CONV6_IDX + in_idx + adding];
                      7:conv[conv_idx][in_idx] = in[CONV7_IDX + in_idx + adding];
                      8:conv[conv_idx][in_idx] = in[CONV8_IDX + in_idx + adding];
                      9:conv[conv_idx][in_idx] = in[CONV9_IDX + in_idx + adding];
                      10:conv[conv_idx][in_idx] = in[CONV10_IDX + in_idx + adding];
                      11:conv[conv_idx][in_idx] = in[CONV11_IDX + in_idx + adding];
                      default:conv[conv_idx][in_idx] = in[CONV0_IDX + in_idx + adding];
                   endcase
                end else if ((last_frame_idx == 3 && special_special_row_col_ind == 0) || last_frame_idx == 5) begin // FRAME 1 ,FRAME 2 are SPECIAL (4*10)
                    case (conv_idx)
                       0:conv[conv_idx][in_idx] = in[CONV0_IDX + in_idx + adding];
                       1:conv[conv_idx][in_idx] = in[CONV1_IDX + in_idx + adding];
                       2:conv[conv_idx][in_idx] = in[CONV2_IDX + in_idx + adding];
                       3:conv[conv_idx][in_idx] = in[CONV3_IDX + in_idx + adding];
                       4:conv[conv_idx][in_idx] = (frame == 2)?in[CONV4_SPECIAL_IDX + in_idx + adding] : in[CONV4_IDX + in_idx + adding];
                       6:conv[conv_idx][in_idx] = (frame == 2)?in[CONV6_SPECIAL_IDX + in_idx + adding] : in[CONV6_IDX + in_idx + adding];
                       7:conv[conv_idx][in_idx] = (frame == 2)?in[CONV7_SPECIAL_IDX + in_idx + adding] : in[CONV7_IDX + in_idx + adding];
                       5:conv[conv_idx][in_idx] = (frame == 2)?in[CONV5_SPECIAL_IDX + in_idx + adding] : in[CONV5_IDX + in_idx + adding];
                       8:conv[conv_idx][in_idx] = ((frame == 2) || (frame == 3 ))? in[CONV8_SPECIAL_IDX + in_idx + adding] : in[CONV8_IDX + in_idx + adding];
                       9:conv[conv_idx][in_idx] = ((frame == 2) || (frame == 3 ))? in[CONV9_SPECIAL_IDX + in_idx + adding] : in[CONV9_IDX + in_idx + adding];
                       10:conv[conv_idx][in_idx] = ((frame == 2) || (frame == 3 ))? in[CONV10_SPECIAL_IDX + in_idx + adding] : in[CONV10_IDX + in_idx + adding];
                       11:conv[conv_idx][in_idx] = ((frame == 2) || (frame == 3 ))? in[CONV11_SPECIAL_IDX + in_idx + adding] : in[CONV11_IDX + in_idx + adding];
                       default:conv[conv_idx][in_idx] = in[CONV0_IDX + in_idx + adding];
                    endcase
                end
            end
        end
    end
endgenerate

endmodule