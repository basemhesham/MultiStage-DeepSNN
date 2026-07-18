//===========================================================
// File        : conv9.sv
// Purpose     : 9-tap signed dot product implemented using
//               nine cascaded DSP48E2 wrappers
//               (xbip_dsp48_macro_cascade). Each DSP computes
//               one (P,Q) multiplication and accumulates the
//               result through the PCIN/PCOUT cascade.
//               The final DSP outputs the accumulated result
//               to fabric through P_fab, which is truncated
//               to Pixel_Out.
// Used in     : top_conv9_array (one instance per array cell)
//===========================================================
// Written by  : Basem Hesham
// revised by  : Yousef Gamal
// Last edit   : 2026-07-07
// Version     : 1.0
//===========================================================

module conv9 #(
    //-------------------------------------------------------------------
    // Parameters
    //-------------------------------------------------------------------
    parameter int PIXEL_W = 18,
    parameter int PROD_W  = 36,
    parameter int OUT_W   = 40
)(
    //-------------------------------------------------------------------
    // Port Declarations
    //-------------------------------------------------------------------
    input  logic                      CLK                , // Clock signal
    input  logic signed [PIXEL_W-1:0] P         [0:8]    , // Pixel operand taps (9-wide)
    input  logic signed [PIXEL_W-1:0] Q         [0:8]    , // Coefficient taps (9-wide)
    output logic signed [OUT_W-1:0]   Pixel_Out            // Truncated convolution result
);

    //-------------------------------------------------------------------
    // Internal Signals
    //-------------------------------------------------------------------
    logic signed [47:0] chain   [0:7]; // DSP-to-DSP cascade wires (PCOUT -> PCIN only)
    logic signed [47:0] P_final;       // Final accumulator value from last DSP's P_fab

    //-------------------------------------------------------------------
    // DSP Cascade Instantiation
    //-------------------------------------------------------------------

    // DSP 0 - first tap, seeds the cascade with PCIN = 0
    xbip_dsp48_macro_cascade #(.PIXEL_W (PIXEL_W)) dsp0 
    (
        .CLK   (CLK)      ,
        .A     (P[0])     ,
        .B     (Q[0])     ,
        .PCIN  (48'sb0)   ,
        .PCOUT (chain[0]) ,
        .P_fab ()
    );

    // DSPs 1-7 - middle taps, pass the cascade through PCIN/PCOUT
    genvar i;
    generate
        for (i = 1; i < 8; i++) 
            begin : gen_cascade
                xbip_dsp48_macro_cascade #(.PIXEL_W (PIXEL_W)) dsp_i 
                (
                    .CLK   (CLK)        ,
                    .A     (P[i])       ,
                    .B     (Q[i])       ,
                    .PCIN  (chain[i-1]) ,
                    .PCOUT (chain[i])   ,
                    .P_fab ()
                );
            end
    endgenerate

    // DSP 8 - last tap, drains the cascade to fabric via P_fab (not PCOUT)
    xbip_dsp48_macro_cascade #(.PIXEL_W (PIXEL_W)) dsp8 
    (
        .CLK   (CLK)      ,
        .A     (P[8])     ,
        .B     (Q[8])     ,
        .PCIN  (chain[7]) ,
        .PCOUT ()         ,
        .P_fab (P_final)
    );

    //-------------------------------------------------------------------
    // Output Logic
    //-------------------------------------------------------------------
    assign Pixel_Out = P_final[OUT_W-1:0]; // Truncate 48-bit accumulator to output width

endmodule
