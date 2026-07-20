//===========================================================
// File        : frame_input_mapping.sv
// Purpose     : Extracts 4 overlapping 3x3 (im2col-style) patches from
//               a 4x4 input block, repeated independently across 64
//               channels/pixels (din indexed as i*16 + offset).
//               Each 3x3 patch is flattened to 9 elements (dout[9][...]).
//               Output layout: dout[patch_elem][window][channel]
//               - dout[*][0][*] : window at rows 0-2, cols 0-2
//               - dout[*][1][*] : window at rows 0-2, cols 1-3
//               - dout[*][2][*] : window at rows 1-3, cols 0-2
//               - dout[*][3][*] : window at rows 1-3, cols 1-3
// Used in     : CNN Accelerator top-level (frame/window mapping stage)
module bin_muxing_stage2 (
  input  wire logic  din  [1024],
  output  logic dout [9][4][64]
);

  always_comb begin
    for (int i = 0; i < 64; i++) begin
      // Window 0 assignments
      dout[0][0][i] = din[0 + i*16];
      dout[1][0][i] = din[1 + i*16];
      dout[2][0][i] = din[2 + i*16];
      dout[3][0][i] = din[4 + i*16];
      dout[4][0][i] = din[5 + i*16];
      dout[5][0][i] = din[6 + i*16];
      dout[6][0][i] = din[8 + i*16];
      dout[7][0][i] = din[9 + i*16];
      dout[8][0][i] = din[10 + i*16];

      // Window 1 assignments
      dout[0][1][i] = din[1 + i*16];
      dout[1][1][i] = din[2 + i*16];
      dout[2][1][i] = din[3 + i*16];
      dout[3][1][i] = din[5 + i*16];
      dout[4][1][i] = din[6 + i*16];
      dout[5][1][i] = din[7 + i*16];
      dout[6][1][i] = din[9 + i*16];
      dout[7][1][i] = din[10 + i*16];
      dout[8][1][i] = din[11 + i*16];

      // Window 2 assignments
      dout[0][2][i] = din[4 + i*16];
      dout[1][2][i] = din[5 + i*16];
      dout[2][2][i] = din[6 + i*16];
      dout[3][2][i] = din[8 + i*16];
      dout[4][2][i] = din[9 + i*16];
      dout[5][2][i] = din[10 + i*16];
      dout[6][2][i] = din[12 + i*16];
      dout[7][2][i] = din[13 + i*16];
      dout[8][2][i] = din[14 + i*16];

      // Window 3 assignments
      dout[0][3][i] = din[5 + i*16];
      dout[1][3][i] = din[6 + i*16];
      dout[2][3][i] = din[7 + i*16];
      dout[3][3][i] = din[9 + i*16];
      dout[4][3][i] = din[10 + i*16];
      dout[5][3][i] = din[11 + i*16];
      dout[6][3][i] = din[13 + i*16];
      dout[7][3][i] = din[14 + i*16];
      dout[8][3][i] = din[15 + i*16];
    end
  end

endmodule
