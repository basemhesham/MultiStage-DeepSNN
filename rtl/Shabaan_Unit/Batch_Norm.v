`timescale 1ns / 1ps
// =============================================================================
// Batch_Norm.v - Batch normalisation using an explicit DSP48E2 primitive
// Operation: P = (Batch_Norm_in * mult_wight) + (add_wight << 9)
// Output: Q8.9 bits [26:9] of the 48-bit MAC result
// =============================================================================

module Batch_Norm #(
    parameter DATA_WIDTH = 18,
    parameter FRAC_BITS  = 9
)(
    input  wire signed [DATA_WIDTH-1:0] Batch_Norm_in,
    input  wire signed [DATA_WIDTH-1:0] mult_wight,
    input  wire signed [DATA_WIDTH-1:0] add_wight,
    output wire signed [DATA_WIDTH-1:0] Batch_Norm_out
);

    localparam PRODUCT_WIDTH = DATA_WIDTH * 2;

    wire signed [47:0] P_full;
    wire signed [PRODUCT_WIDTH-1:0] product_full;
    wire signed [47:0] product_ext;
    wire signed [47:0] add_ext;
    wire signed [47:0] add_scaled;

    assign product_full = Batch_Norm_in * mult_wight;
    assign product_ext = {{(48-PRODUCT_WIDTH){product_full[PRODUCT_WIDTH-1]}}, product_full};
    assign add_ext = {{(48-DATA_WIDTH){add_wight[DATA_WIDTH-1]}}, add_wight};
    assign add_scaled = add_ext <<< FRAC_BITS;

`ifdef SIM
    assign P_full = product_ext + add_scaled;
`else
    DSP48E2 #(
        .ACASCREG       (0),
        .ADREG          (0),
        .ALUMODEREG     (0),
        .AREG           (0),
        .A_INPUT        ("DIRECT"),
        .BCASCREG       (0),
        .BREG           (0),
        .B_INPUT        ("DIRECT"),
        .CARRYINREG     (0),
        .CARRYINSELREG  (0),
        .CREG           (0),
        .DREG           (0),
        .INMODEREG      (0),
        .MREG           (0),
        .OPMODEREG      (0),
        .PREG           (0),
        .PREADDINSEL    ("A"),
        .USE_MULT       ("MULTIPLY"),
        .USE_SIMD       ("ONE48")
    ) dsp_inst (
        .A              ({{(30-DATA_WIDTH){Batch_Norm_in[DATA_WIDTH-1]}}, Batch_Norm_in}),
        .B              (mult_wight),
        .C              (add_scaled),
        .D              (27'b0),
        .PCIN           (48'b0),

        // OPMODE 9'b000110101: W=0, Z=C, XY=M -> P = A*B + C
        .OPMODE         (9'b000110101),
        .ALUMODE        (4'b0000),
        .INMODE         (5'b00000),
        .CARRYINSEL     (3'b000),
        .CARRYIN        (1'b0),

        .P              (P_full),
        .PCOUT          (),

        .CLK            (1'b0),
        .CEA1           (1'b1),
        .CEA2           (1'b1),
        .CEAD           (1'b1),
        .CEALUMODE      (1'b1),
        .CEB1           (1'b1),
        .CEB2           (1'b1),
        .CEC            (1'b1),
        .CECARRYIN      (1'b1),
        .CECTRL         (1'b1),
        .CED            (1'b1),
        .CEINMODE       (1'b1),
        .CEM            (1'b1),
        .CEP            (1'b1),

        .RSTA           (1'b0),
        .RSTB           (1'b0),
        .RSTC           (1'b0),
        .RSTD           (1'b0),
        .RSTM           (1'b0),
        .RSTP           (1'b0),
        .RSTALLCARRYIN  (1'b0),
        .RSTALUMODE     (1'b0),
        .RSTCTRL        (1'b0),
        .RSTINMODE      (1'b0),

        .ACIN           (30'b0),
        .BCIN           (18'b0),
        .CARRYCASCIN    (1'b0),
        .MULTSIGNIN     (1'b0),

        .ACOUT          (),
        .BCOUT          (),
        .CARRYOUT       (),
        .CARRYCASCOUT   (),
        .MULTSIGNOUT    (),
        .OVERFLOW       (),
        .UNDERFLOW      (),
        .PATTERNDETECT  (),
        .PATTERNBDETECT (),
        .XOROUT         ()
    );
`endif

    assign Batch_Norm_out = P_full[FRAC_BITS + DATA_WIDTH - 1:FRAC_BITS];

endmodule
