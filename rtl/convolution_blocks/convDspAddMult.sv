//===========================================================
// File        : convDspAddMult.sv
// Purpose     : Vivado/XCVU11P DSP48E2 wrapper used in the
//               conv9 MAC implementation. Computes
//               PCOUT = (A × B) + PCIN.
//               Instantiates the UltraScale+ DSP48E2 primitive
//               during synthesis and provides a behavioral
//               model under `SIM` for simulation.
// Used in     : conv9 (cascaded 9 times per MAC unit)
//===========================================================
// Written by  : --
// revised by  : Yousef Gamal
// Last edit   : 2026-07-07
// Version     : 1.0
//===========================================================

module xbip_dsp48_macro_cascade #( parameter int PIXEL_W = 18)
(
    //--------------------------------------------------------------------
    // Port Declarations
    //--------------------------------------------------------------------
    input  logic                      CLK  , // Main clock
    input  logic signed [PIXEL_W-1:0] A    , // Operand A (signed)
    input  logic signed [PIXEL_W-1:0] B    , // Operand B (signed)
    input  logic signed [47:0]        PCIN , // Cascade input from upstream DSP
    output logic signed [47:0]        PCOUT, // Cascade output to downstream DSP
    output logic signed [47:0]        P_fab  // Fabric-visible copy of P
);

    //--------------------------------------------------------------------
    // Internal Signals
    //--------------------------------------------------------------------
    wire signed [29:0]            A_ext       ; /* A sign-extended to DSP48E2's 30-bit A port */
    wire signed [(2*PIXEL_W)-1:0] product_full; /* Raw A*B product at full precision */
    wire signed [47:0]            product_ext ; /* product_full sign-extended to 48-bit P width */

    //--------------------------------------------------------------------
    // Combinational Logic
    //--------------------------------------------------------------------
    assign A_ext        = {{(30-PIXEL_W){A[PIXEL_W-1]}}, A};                               /* Sign-extend A to 30 bits */
    assign product_full = A * B;                                                           /* Signed multiply */
    assign product_ext  = {{(48-(2*PIXEL_W)){product_full[(2*PIXEL_W)-1]}}, product_full}; /* Sign-extend to 48 bits */

    //--------------------------------------------------------------------
    // DSP48E2 Hard Macro Instantiation / Simulation Model
    //--------------------------------------------------------------------
`ifdef SIM
    /* The top-level controller supplies one complete window per clock. Keep
       the simulation cascade combinational so all nine products belong to
       that same window. */
    assign PCOUT  = product_ext + PCIN;
    assign P_fab  = product_ext + PCIN;
`else
    (* keep = "true" *)
    DSP48E2 #(
        .ACASCREG      (0)         ,
        .ADREG         (0)         ,
        .ALUMODEREG    (0)         ,
        .AREG          (0)         ,
        .A_INPUT       ("DIRECT")  ,
        .BCASCREG      (0)         ,
        .BREG          (0)         ,
        .B_INPUT       ("DIRECT")  ,
        .CARRYINREG    (0)         ,
        .CARRYINSELREG (0)         ,
        .CREG          (0)         ,
        .DREG          (0)         ,
        .INMODEREG     (0)         ,
        .MREG          (0)         ,
        .OPMODEREG     (0)         ,
        .PREG          (1)         , /* Register P/PCOUT to keep the cascade clocked */
        .PREADDINSEL   ("A")       ,
        .USE_MULT      ("MULTIPLY"),
        .USE_SIMD      ("ONE48")
    ) dsp_inst (
        // Data ports
        .A              (A_ext), /* 30-bit */
        .B              (B),     /* 18-bit */
        .C              (48'b0),
        .D              (27'b0), /* 27-bit in DSP48E2 */
        .PCIN           (PCIN),

        /* OPMODE 9'b000010101:
             W mux  = 00   -> 0
             Z mux  = 001  -> PCIN
             XY mux = 0101 -> M (A*B)
           Result: P = A*B + PCIN */
        .OPMODE         (9'b000010101),
        .ALUMODE        (4'b0000),
        .INMODE         (5'b00000),
        .CARRYINSEL     (3'b000),
        .CARRYIN        (1'b0),

        .PCOUT          (PCOUT),
        .P              (P_fab),

        .CLK            (CLK),
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

endmodule