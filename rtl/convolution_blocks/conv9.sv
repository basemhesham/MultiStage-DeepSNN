`timescale 1ns / 1ps
// =============================================================================
// conv9.sv - 9-tap dot product using explicit cascaded DSP48E2 primitives
//
// DSP cascade routing rules:
//   PCOUT → PCIN of next DSP only  (cascade wire, cannot drive fabric)
//   P     → fabric (LUTs, FFs, ports)
//
// DSP 0   : PCIN=0,        PCOUT→chain[0],    P_fab=unused
// DSP 1-7 : PCIN=chain[i-1], PCOUT→chain[i],  P_fab=unused
// DSP 8   : PCIN=chain[7],   PCOUT=unused,     P_fab→Pixel_Out 
// =============================================================================

module conv9 #(
    parameter int PIXEL_W = 18,
    parameter int PROD_W  = 36,
    parameter int OUT_W   = 40
)(
    input wire  logic                       CLK,
    input wire logic signed [PIXEL_W-1:0]  P [0:8],
    input wire logic signed [PIXEL_W-1:0]  Q [0:8],
    output wire logic signed [OUT_W-1:0]    Pixel_Out
);

    logic signed [47:0] chain [0:7];
    logic signed [47:0] P_final;

    // DSP 0 - first
    xbip_dsp48_macro_cascade #(.PIXEL_W(PIXEL_W)) dsp0 (
        .CLK(CLK), .A(P[0]), .B(Q[0]),
        .PCIN(48'sb0), .PCOUT(chain[0]), .P_fab()
    );

    // DSPs 1-7 - middle
    genvar i;
    generate
        for (i = 1; i < 8; i++) begin : gen_cascade
            xbip_dsp48_macro_cascade #(.PIXEL_W(PIXEL_W)) dsp_i (
                .CLK(CLK), .A(P[i]), .B(Q[i]),
                .PCIN(chain[i-1]), .PCOUT(chain[i]), .P_fab()
            );
        end
    endgenerate

    // DSP 8 - last: use P_fab to drive fabric, not PCOUT
    xbip_dsp48_macro_cascade #(.PIXEL_W(PIXEL_W)) dsp8 (
        .CLK(CLK), .A(P[8]), .B(Q[8]),
        .PCIN(chain[7]), .PCOUT(), .P_fab(P_final)
    );

    assign Pixel_Out = P_final[OUT_W-1:0];

endmodule
