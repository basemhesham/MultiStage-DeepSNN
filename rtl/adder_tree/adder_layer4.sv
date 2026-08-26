`timescale 1ns / 1ps

/*
Description:
    Implements a signed 2-input combinational adder using a single Xilinx
    DSP48E2 primitive. The module computes the arithmetic sum:

        adder_out = add_1 + add_2

    During simulation (SIM defined), the functionality is modeled using
    behavioral Verilog arithmetic. During synthesis, the design explicitly
    instantiates a DSP48E2 primitive configured as a 48-bit arithmetic logic
    unit (ALU). The first operand (add_1) is sign-extended to 48 bits and
    mapped across the DSP A and B input ports, while the second operand
    (add_2) is sign-extended and applied to the C input. The DSP ALU then
    performs the addition:

        P = A:B + C

    This implementation avoids LUT-based arithmetic and efficiently utilizes
    a single DSP48E2 slice.

Inputs:
    add_1
        First signed input operand (24 bits).

    add_2
        Second signed input operand (22 bits).

Output:
    adder_out
        Signed sum of add_1 and add_2 (25 bits).

Notes:
    - Both operands are sign-extended to the DSP48E2 internal 48-bit datapath.
    - add_1 is mapped across the concatenated A:B datapath of the DSP48E2.
    - add_2 is applied through the 48-bit C input.
    - The implementation is purely combinational (no pipeline registers).
    - The 25-bit output width is sufficient to represent the sum of a
      24-bit signed value and a 22-bit signed value without overflow.
------------------------------------------------------------------------------
*/

module adder_layer4 #(
    parameter IN1_WIDTH = 24,
    parameter IN2_WIDTH = 22,
    parameter OUT_WIDTH = 25 // Output width = max(IN1_WIDTH, IN2_WIDTH) + 1 to prevent overflow
)(
    input  logic signed [IN1_WIDTH-1:0] add_1,     // First 24-bit signed input operand (Layer 3 partial sum)
    input  logic signed [IN2_WIDTH-1:0] add_2,     // Second 22-bit signed input operand (Layer 2 partial sum)
    output logic signed [OUT_WIDTH-1:0] adder_out  // 25-bit signed sum: add_1 + add_2
);

    logic signed [47:0] add_1_ext;   // Sign-extended version of add_1 to match the DSP48E2 48-bit datapath
    logic signed [47:0] add_2_ext;   // Sign-extended version of add_2 to match the DSP48E2 48-bit datapath
    logic signed [47:0] P_full;      // Full 48-bit output from the DSP48E2

    // Sign-extend each input operand to the DSP48E2's internal 48-bit datapath
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
        .USE_MULT       ("NONE"), // No multiplication needed for 2-input addition
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

    assign adder_out = P_full[OUT_WIDTH-1:0]; // Output the lower OUT_WIDTH bits of the DSP48E2 output

endmodule
