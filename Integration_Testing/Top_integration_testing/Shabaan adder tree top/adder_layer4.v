`timescale 1ns / 1ps
// =============================================================================
// adder_layer4.v - 2-input adder using an explicit DSP48E2 primitive
// Operation: P = add_1 + add_2
// Input:  add_1=24-bit, add_2=22-bit signed
// Output: 25-bit signed
// =============================================================================

module adder_layer4 #(
    parameter IN1_WIDTH = 24,
    parameter IN2_WIDTH = 22,
    parameter OUT_WIDTH = 25
)(
    input  wire signed [IN1_WIDTH-1:0] add_1,
    input  wire signed [IN2_WIDTH-1:0] add_2,
    output wire signed [OUT_WIDTH-1:0] adder_out
);

    wire signed [47:0] add_1_ext;
    wire signed [47:0] add_2_ext;
    wire signed [47:0] P_full;

    assign add_1_ext = {{(48-IN1_WIDTH){add_1[IN1_WIDTH-1]}}, add_1};
    assign add_2_ext = {{(48-IN2_WIDTH){add_2[IN2_WIDTH-1]}}, add_2};

`ifdef SIM
    assign P_full = add_1_ext + add_2_ext;
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
        .USE_MULT       ("NONE"),
        .USE_SIMD       ("ONE48")
    ) dsp_inst (
        .A              (add_1_ext[47:18]),
        .C              (add_2_ext),
        .D              (27'b0),
        .B              (add_1_ext[17:0]),
        .PCIN           (48'b0),

        // A:B carries the 48-bit sign-extended add_1 value.
        // OPMODE 9'b000110011: W=0, Z=C, Y=0, X=A:B -> P = C + add_1
        .OPMODE         (9'b000110011),
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

    assign adder_out = P_full[OUT_WIDTH-1:0];

endmodule
