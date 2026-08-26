//===========================================================
// File        : pulse_generator.sv
// Purpose     : Converts a level-type input signal (e.g. frame_start,
//               which stays high for many clock cycles) into a single
//               clock-cycle-wide pulse aligned to its rising edge.
//               Implemented with a 1-cycle delay flip-flop plus an
//               AND/NOT gate combination: pulse = current & ~delayed.
//               This fires only on the cycle immediately after the
//               input transitions 0->1, and stays low on the falling
//               edge (1->0) and while the input is steady-state.
// Used in     : top-level control/timing path, to generate a one-shot
//               start pulse from a level-held frame/enable signal
//===========================================================
// Written by  : Abdelrahman Khaled
// Editor      : 
// Last edit   : 9-8-2026
//===========================================================
module pulse_gen (
    input  wire clk,
    input  wire rst_n,
    input  wire frame_start,   // level signal, high for many cycles
    output wire pulse          // single-cycle pulse
);

    // Holds a 1-clock-cycle-delayed copy of frame_start
    reg frame_start_d;

    // Delay register: samples frame_start every rising clk edge,
    // asynchronously reset to 0 on rst_n low
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            frame_start_d <= 1'b0;
        else
            frame_start_d <= frame_start;
    end

    // Edge detector: high only when frame_start is currently 1 but
    // its delayed version hasn't caught up yet (i.e. the cycle right
    // after the rising edge) -> produces the single-cycle pulse
    assign pulse = frame_start & ~frame_start_d;  // rising-edge only

endmodule