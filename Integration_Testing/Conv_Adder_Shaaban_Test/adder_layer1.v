`timescale 1ns / 1ps
// =============================================================================
// adder_layer1.v - 3-input adder using an explicit DSP48E2 primitive
// Operation: P = add_1 + add_2 + add_3
// Input:  3 x 18-bit signed
// Output: 20-bit signed
// =============================================================================

module adder_layer1 #(
    parameter IN_WIDTH  = 18,
    parameter OUT_WIDTH = 20
)(
    input  wire signed [IN_WIDTH-1:0]  add_1,
    input  wire signed [IN_WIDTH-1:0]  add_2,
    input  wire signed [IN_WIDTH-1:0]  add_3,
    output wire signed [OUT_WIDTH-1:0] adder_out
);

    wire signed [47:0] P_full;
    wire signed [47:0] add_1_ext;
    wire signed [47:0] add_2_ext;
    wire signed [47:0] add_3_ext;

    assign add_1_ext = {{(48-IN_WIDTH){add_1[IN_WIDTH-1]}}, add_1};
    assign add_2_ext = {{(48-IN_WIDTH){add_2[IN_WIDTH-1]}}, add_2};
    assign add_3_ext = {{(48-IN_WIDTH){add_3[IN_WIDTH-1]}}, add_3};

`ifdef SIM
    assign P_full = add_1_ext + add_2_ext + add_3_ext;
`else
    DSP48E2 #(
        .ACASCREG       (0),
        .ADREG          (0),
        .ALUMODEREG     (0),
        .AMULTSEL       ("AD"),
        .AREG           (0),
        .A_INPUT        ("DIRECT"),
        .BCASCREG       (0),
        .BMULTSEL       ("B"),
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
        .A              ({{(30-IN_WIDTH){add_1[IN_WIDTH-1]}}, add_1}),
        .D              ({{(27-IN_WIDTH){add_3[IN_WIDTH-1]}}, add_3}),
        .C              ({{(48-IN_WIDTH){add_2[IN_WIDTH-1]}}, add_2}),
        .B              (18'sd1),
        .PCIN           (48'b0),

        // INMODE enables D + A in the pre-adder; B=1 sends that sum through M.
        // OPMODE 9'b000110101: W=0, Z=C, XY=M -> P = C + ((A+D)*1)
        .OPMODE         (9'b000110101),
        .ALUMODE        (4'b0000),
        .INMODE         (5'b00100),
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

    assign adder_out = P_full[OUT_WIDTH-1:0];

endmodule
