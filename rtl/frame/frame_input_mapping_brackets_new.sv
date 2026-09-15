// Generated SystemVerilog mapping logic
//===========================================================
// File        : frame_input_mapping.sv
// Purpose     : Maps flat frame input (in[]) to 12 output windows
//               (conv[12][9]), each holding a 3x3 im2col-style patch,
//               selected based on the current frame offset.
//               Built entirely from structural 2:1 muxes.
// Used in     : CNN Accelerator top-level (frame/window mapping stage)
//===========================================================
// Written by  : Hany Moahemd
// Editor      : Abdelrahman Khaled
// Last edit   : 2026-09-15
//===========================================================

//===========================================================
// Basic 2:1 multiplexer primitive - every selection in this
// design is built from instances of this module.
//===========================================================
module mux2 (
    input  wire logic d0,
    input  wire logic d1,
    input  wire logic sel,
    output wire logic y
);
    assign y = sel ? d1 : d0;
endmodule

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

//===========================================================
// Per-conv-unit base indices, gathered into elaboration-time
// lookup tables. Units 0-3 have no special mapping, so their
// special entry mirrors the normal one.
//===========================================================
localparam int NORMAL_IDX  [CONV_NO] = '{ CONV0_IDX, CONV1_IDX, CONV2_IDX,  CONV3_IDX,
                                          CONV4_IDX, CONV5_IDX, CONV6_IDX,  CONV7_IDX,
                                          CONV8_IDX, CONV9_IDX, CONV10_IDX, CONV11_IDX };

localparam int SPECIAL_IDX [CONV_NO] = '{ CONV0_IDX,         CONV1_IDX,         CONV2_IDX,          CONV3_IDX,
                                          CONV4_SPECIAL_IDX, CONV5_SPECIAL_IDX, CONV6_SPECIAL_IDX,  CONV7_SPECIAL_IDX,
                                          CONV8_SPECIAL_IDX, CONV9_SPECIAL_IDX, CONV10_SPECIAL_IDX, CONV11_SPECIAL_IDX };

//===========================================================
// Mode decode - depends only on last_frame_idx /
// special_special_row_col_ind / frame, so computed once here
// rather than replicated inside the 12x9 generate loop.
//===========================================================
// mode_a : FRAMES ARE ALWAYS (4*8) -> every conv unit uses its NORMAL index
wire logic mode_a   = (last_frame_idx == 3'd2) ||
                      (last_frame_idx == 3'd3 && special_special_row_col_ind == 1'b1);

// mode_b : FRAME 1, FRAME 2 are SPECIAL (4*10) -> units 4-11 may use SPECIAL index
wire logic mode_b   = (last_frame_idx == 3'd3 && special_special_row_col_ind == 1'b0) ||
                      (last_frame_idx == 3'd5);

// Output is driven at all only in mode_a or mode_b; otherwise it is 0.
wire logic mode_any = mode_a || mode_b;

// frame qualifiers used by the special selection inside mode_b
wire logic frame_2  = (frame == 3'd2);
wire logic frame_eq = (frame == 3'd2) || (frame == 3'd3);

genvar conv_idx, in_idx;

generate
    for (conv_idx = 0; conv_idx < CONV_NO; conv_idx++) begin : g_conv
        //===================================================
        // Which frame qualifier this conv unit uses:
        //   units 0-3  : never special
        //   units 4-7  : special when frame == 2
        //   units 8-11 : special when frame == 2 or 3
        //===================================================
        wire logic use_special;

        if (conv_idx < 4) begin : g_no_special
            assign use_special = 1'b0;
        end else if (conv_idx < 8) begin : g_special_f2
            // special only inside mode_b, and only when frame == 2
            assign use_special = mode_b && frame_2;
        end else begin : g_special_f23
            // special only inside mode_b, and only when frame == 2 or 3
            assign use_special = mode_b && frame_eq;
        end

        for (in_idx = 0; in_idx < INPUT_NO; in_idx++) begin : g_in
            localparam int adding     = in_idx / ROW_NO;
            localparam int idx_normal = NORMAL_IDX [conv_idx] + in_idx + adding;
            localparam int idx_special= SPECIAL_IDX[conv_idx] + in_idx + adding;

            //===============================================
            // MUX 1 : choose between the normal-mapped tap and
            //         the special-mapped tap.
            //===============================================
            wire logic tap_sel;

            mux2 u_mux_tap (
                .d0  ( in[idx_normal]  ),
                .d1  ( in[idx_special] ),
                .sel ( use_special     ),
                .y   ( tap_sel         )
            );

            //===============================================
            // MUX 2 : gate the result - drive 0 when neither
            //         mapping mode is active.
            //===============================================
            wire logic conv_bit;

            mux2 u_mux_gate (
                .d0  ( 1'b0     ),
                .d1  ( tap_sel  ),
                .sel ( mode_any ),
                .y   ( conv_bit )
            );

            assign conv[conv_idx][in_idx] = conv_bit;
        end
    end
endgenerate

endmodule
