`timescale 1ns / 1ps

/*
Description:
    Implements a signed 3-input combinational adder using a single Xilinx
    DSP48E2 primitive. The module computes the arithmetic sum:

        adder_out = add_1 + add_2 + add_3

    The implementation utilizes the DSP48E2 pre-adder to first add add_1 and
    add_3, then adds add_2 through the C input, allowing all three operands to
    be summed using a single DSP slice. During simulation (SIM defined), the
    functionality is modeled using behavioral Verilog for portability, while
    synthesis instantiates the DSP48E2 primitive explicitly for optimal FPGA
    resource utilization.

Inputs:
    add_1      - First signed input operand (IN_WIDTH bits).
    add_2      - Second signed input operand (IN_WIDTH bits).
    add_3      - Third signed input operand (IN_WIDTH bits).

Output:
    adder_out  - Signed sum of the three input operands
                 (OUT_WIDTH bits).

Notes:
    - Inputs are sign-extended to the DSP48E2 internal 48-bit datapath.
    - The implementation is purely combinational (no pipeline registers).
    - Default configuration supports three 22-bit signed inputs and produces
      a 24-bit signed output without overflow.
------------------------------------------------------------------------------
*/

module adder_layer3 #(
    parameter IN_WIDTH  = 22,
    parameter OUT_WIDTH = 24 // Output width = IN_WIDTH + ceil(log2(3)) to prevent overflow
)(
    input  logic signed [IN_WIDTH-1:0]  add_1,      // First 22-bit signed input operand (Layer 2 partial sum)
    input  logic signed [IN_WIDTH-1:0]  add_2,      // Second 22-bit signed input operand (Layer 2 partial sum)
    input  logic signed [IN_WIDTH-1:0]  add_3,      // Third 22-bit signed input operand (Layer 2 partial sum)
    output logic signed [OUT_WIDTH-1:0] adder_out   // 24-bit signed sum: add_1 + add_2 + add_3
);

    logic signed [47:0] P_full;      // Full 48-bit output from the DSP48E2
    logic signed [47:0] add_1_ext;   // Sign-extended version of add_1 to match the DSP48E2 48-bit datapath
    logic signed [47:0] add_2_ext;   // Sign-extended version of add_2 to match the DSP48E2 48-bit datapath
    logic signed [47:0] add_3_ext;   // Sign-extended version of add_3 to match the DSP48E2 48-bit datapath

    // Sign-extend each 22-bit operand to the DSP48E2's internal 48-bit datapath
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
        .USE_MULT       ("MULTIPLY"), // To use it for the pre-adder, we need to set USE_MULT to MULTIPLY
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
        .INMODE         (5'b00100), // Use the pre-adder
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
