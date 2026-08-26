// =====================================================================================
// Module name : LIF
// Purpose     : Leaky Integrate-and-Fire spiking neuron — final stage of each Shaaban
//               unit. Modified for Time-Multiplexed Frame processing.
//               Instead of storing the membrane potential internally, it accepts 
//               a pre-calculated history term from an external BRAM, adds the 
//               current frame's input, evaluates the spike, and outputs the newly 
//               calculated history term to be stored for the next frame.
// Math Eq     : U[t] = (Beta * U[t-1] - S[t-1]*Vth) + X[t]
//               Stored History = Beta * U[t] - S[t]*Vth
// Last edit   : August 8, 2026
// =====================================================================================

module LIF #(
    parameter DATA_WIDTH       = 18,
    parameter signed THRESHOLD = 18'd512,
    parameter signed ZERO      = 18'd0
) (
    input  wire logic clk,
    input  wire logic arst_n,
    
    input  wire logic in_valid,    // <-- NEW: Valid/New Data enable
    input  wire logic first_frame, // High during Frame 0 to save BRAM read power
    
    // Inputs from current frame
    input  wire logic signed [DATA_WIDTH-1:0] in_pool,  // X[t]: Current frame input
    input  wire logic signed [DATA_WIDTH-1:0] hist_in,  // H[t-1]: Read from external BRAM
    
    // Outputs for current frame
    output logic                              spike_out, // S[t]: Goes to next layer
    output logic signed [DATA_WIDTH-1:0]      hist_out   // H[t]: Goes to external BRAM write port
);

    // --------------------------------------------------------------
    //  Internal Signals
    // --------------------------------------------------------------
    logic signed [DATA_WIDTH:0]   u_t_ext;          // 19-bit intermediate to prevent overflow
    logic signed [DATA_WIDTH-1:0] u_t;              // U[t]: Membrane potential for current frame
    logic                         spike_int;        // Internal combinational spike
    
    logic signed [DATA_WIDTH-1:0] u_t_leak;         // Beta * U[t]
    logic signed [DATA_WIDTH-1:0] reset_penalty;    // S[t] * Vth
    // logic signed [DATA_WIDTH-1:0] next_hist;        // Value to store for next frame

    // --------------------------------------------------------------
    //  1. Calculate Current Membrane Potential U[t]
    //     U[t] = H[t-1] + X[t]
    //     (Operand Isolation: Force H[t-1] to 0 if first_frame)
    // --------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0] actual_hist;
    assign actual_hist = first_frame ? ZERO : hist_in;
    
    assign u_t_ext = actual_hist + in_pool;
    assign u_t     = u_t_ext[DATA_WIDTH-1:0]; // Truncate back to 18 bits

    // --------------------------------------------------------------
    //  2. THRESHOLD Comparison / Spike Generation S[t]
    // --------------------------------------------------------------
    always_comb begin
        // Only allow a spike if the data is valid/new
        if (/*in_valid && */(u_t >= THRESHOLD)) begin
            spike_int = 1'b1;
        end else begin
            spike_int = 1'b0;
        end
    end

    // --------------------------------------------------------------
    //  3. Calculate History Term to Store for Next Frame H[t]
    //     H[t] = (U[t] * Beta) - (S[t] * Vth)
    // --------------------------------------------------------------
    assign u_t_leak      = u_t >>> 1; // Beta = 0.5 (Arithmetic shift right)
    assign reset_penalty = spike_int ? THRESHOLD : ZERO;
    
    assign hist_out      = u_t_leak - reset_penalty;
    assign spike_out     = spike_int;
    // --------------------------------------------------------------
    //  4. Sequential Pipeline Registers (1 Cycle Delay)
    // --------------------------------------------------------------
    //always_ff @(posedge clk or negedge arst_n) begin
    //    if (!arst_n) begin
    //        spike_out <= 1'b0;
    //        // hist_out  <= 'd0;
    //    end else begin
    //        spike_out <= spike_int;
    //        // hist_out  <= next_hist;
    //    end
    //end

endmodule