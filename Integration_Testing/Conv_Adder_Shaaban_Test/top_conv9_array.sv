`timescale 1ns / 1ps

module top_conv9_array #(
    parameter int PIXEL_W    = 18,
    parameter int MAC_OUT_W  = 40,
    parameter int DATA_WIDTH = 18,
    parameter int FRAC_BITS  = 9
)(
    input  logic                         clk,
    input  logic signed [PIXEL_W-1:0]    pixels_mapped  [0:11][0:31][0:8],
    input  logic signed [PIXEL_W-1:0]    weights_mapped [0:11][0:31][0:8],
    output logic signed [DATA_WIDTH-1:0] mac_to_connect [0:11][0:31]
);

    logic [MAC_OUT_W-1:0] mac_raw [0:11][0:31];

    genvar g, c;
    generate
        for (g = 0; g < 12; g++) begin : gen_conv_row
            for (c = 0; c < 32; c++) begin : gen_conv_col
                conv9 #(
                    .PIXEL_W (PIXEL_W),
                    .PROD_W  (36),
                    .OUT_W   (MAC_OUT_W)
                ) u_conv (
                    .CLK       (clk),
                    .P         (pixels_mapped[g][c]),
                    .Q         (weights_mapped[g][c]),
                    .Pixel_Out (mac_raw[g][c])
                );
            end
        end
    endgenerate

    genvar g2, c2;
    generate
        for (g2 = 0; g2 < 12; g2++) begin : gen_trunc_row
            for (c2 = 0; c2 < 32; c2++) begin : gen_trunc_col
                assign mac_to_connect[g2][c2] =
                    $signed(mac_raw[g2][c2]) >>> FRAC_BITS;
            end
        end
    endgenerate

endmodule
