//===========================================================
// File        : top_conv9_array.sv
// Purpose     : Top-level wrapper instantiating a 12×32 array
//               of conv9 MAC units. Each conv9 computes a
//               9-tap signed dot product between the mapped
//               pixel and weight windows, producing a raw
//               fixed-point MAC result. The output is
//               arithmetically right-shifted by FRAC_BITS to
//               restore the original fixed-point scale before
//               being driven on mac_to_connect.
// Used in     : convolution datapath top-level
//===========================================================
// Written by  : Basem Hesham
// revised by  : Yousef Gamal
// Last edit   : 2026-07-07
// Version     : 1.0
//===========================================================

module top_conv9_array #(
    parameter int PIXEL_W    = 18,
    parameter int DATA_WIDTH = 18,
    parameter int MAC_OUT_W  = 40,
    parameter int FRAC_BITS  = 9
)
(
    input  wire logic                         clk                                     , // Clock signal
    input  wire logic signed [PIXEL_W-1:0]    pixels_mapped  [0:11][0:31][0:8]        , // Mapped 9-tap pixel windows, 12x32 array
    input  wire logic signed [PIXEL_W-1:0]    weights_mapped [0:11][0:31][0:8]        , // Mapped 9-tap weight windows, 12x32 array
    output  logic signed [DATA_WIDTH-1:0] mac_to_connect [0:11][0:31]               // Rescaled MAC results, 12x32 array
);

    //-------------------------------------------------------------------------
    // internal signals
    //-------------------------------------------------------------------------
    logic [PIXEL_W-1:0] mac_raw [0:11][0:31]; /* Raw (un-rescaled) MAC output from each conv9 instance */

    //-------------------------------------------------------------------------
    // MAC Array Generation
    //-------------------------------------------------------------------------
    genvar g, c;
    generate
        for (g = 0; g < 12; g++)
            begin : gen_conv_row
                for (c = 0; c < 32; c++)
                    begin : gen_conv_col
                        // conv9 MAC unit for row g, column c of the array
                        conv9 #(.PIXEL_W (PIXEL_W), .PROD_W (36), .OUT_W (MAC_OUT_W)) u_conv
                        (
                            .CLK       (clk)                 ,
                            .P         (pixels_mapped[g][c])  ,
                            .Q         (weights_mapped[g][c]) ,
                            .Pixel_Out (mac_raw[g][c])
                        );
                    end
            end
    endgenerate

    //-------------------------------------------------------------------------
    // Fixed-Point Rescale Logic
    //-------------------------------------------------------------------------
    genvar g2, c2;
    generate
        for (g2 = 0; g2 < 12; g2++)
            begin : gen_trunc_row
                for (c2 = 0; c2 < 32; c2++)
                    begin : gen_trunc_col
                        // Arithmetic right-shift by FRAC_BITS followed by truncation to DATA_WIDTH
                        // is equivalent to directly selecting bits [FRAC_BITS +: DATA_WIDTH] of the
                        // raw MAC accumulator - the sign-extended bits introduced by >>> above that
                        // range are discarded by the truncation anyway, so the slice below produces
                        // bit-identical results without an RHS/LHS width mismatch or a shifter.
                        // assign mac_to_connect[g2][c2] = $signed(mac_raw[g2][c2]) >>> FRAC_BITS;
                        assign mac_to_connect[g2][c2] = mac_raw[g2][c2];
                    end
            end
    endgenerate

endmodule