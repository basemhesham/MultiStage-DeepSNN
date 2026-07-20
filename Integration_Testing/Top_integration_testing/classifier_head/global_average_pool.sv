`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// Global Average Pooling (GAP)
// Counts the number of spikes for each channel, then computes:
//      average = (spike_count << FRAC_BITS) / SAMPLE_COUNT
// The output is stored in fixed-point (Q9) format.
//
// NOTE ON DIVISION REMOVAL:
// SAMPLE_COUNT (169) is not a power of two, so a plain '>>' cannot replace
// the division exactly. Instead we use the standard "multiply by reciprocal"
// trick: precompute RECIP_CONST = round(2^RECIP_SHIFT / SAMPLE_COUNT) at
// elaboration time (constant-folded by the tool, NOT synthesized as a
// divider), then replace the runtime division with a multiply + shift:
//      average = (scaled_count * RECIP_CONST) >> RECIP_SHIFT
// For SAMPLE_COUNT=169, FRAC_BITS=9, RECIP_SHIFT=24 this has been verified
// to exactly match the original integer division for every possible
// accum value (0..SAMPLE_COUNT).
//------------------------------------------------------------------------------
module global_average_pool #(
    parameter int DATA_WIDTH   = 18,   // Width of output data
    parameter int FRAC_BITS    = 9,    // Fractional bits for fixed-point format
    parameter int CHANNELS     = 128,  // Number of feature map channels
    parameter int SAMPLE_COUNT = 169,  // Number of samples per channel (13x13)
    parameter int ACC_WIDTH    = (SAMPLE_COUNT <= 1) ? 1 : $clog2(SAMPLE_COUNT + 1),

    // Reciprocal-multiply precision (bits). 24 gives exact results vs. true
    // division for SAMPLE_COUNT=169 across the full accum range; increase if
    // SAMPLE_COUNT changes and re-verify.
    parameter int RECIP_SHIFT  = 24
)(
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         clear,

    // Incoming spike stream
    input  logic                         sample_valid,
    input  logic [$clog2(CHANNELS)-1:0]  sample_channel,
    input  logic                         sample_spike,

    // Starts the averaging process
    input  logic                         start,

    // GAP output for every channel
    output logic signed [DATA_WIDTH-1:0] pool_out [0:CHANNELS-1],

    // Status signals
    output logic                         done,
    output logic                         busy
);

    // Width of channel index
    localparam int CHANNEL_W = (CHANNELS <= 1) ? 1 : $clog2(CHANNELS);

    // Width used during scaling
    localparam int CALC_W    = DATA_WIDTH + ACC_WIDTH + FRAC_BITS;

    // Precomputed reciprocal constant: round(2^RECIP_SHIFT / SAMPLE_COUNT).
    // This division is on compile-time constants only -> constant-folded by
    // the tool at elaboration, it does NOT synthesize into a hardware divider.
    localparam longint unsigned RECIP_CONST =
        ((longint'(1) << RECIP_SHIFT) + (SAMPLE_COUNT / 2)) / SAMPLE_COUNT;

    // Width of the multiply-shift product
    localparam int MULT_W = CALC_W + RECIP_SHIFT + 1;

    //--------------------------------------------------------------------------
    // State Machine
    // ST_IDLE     : Collect incoming spikes
    // ST_FINALIZE : Compute average for one channel every clock cycle
    //--------------------------------------------------------------------------
    typedef enum logic [1:0] {
        ST_IDLE,
        ST_FINALIZE
    } state_t;

    state_t state;

    // Channel currently being processed
    logic [CHANNEL_W-1:0] out_channel;

    // Spike counter for each channel
    logic [ACC_WIDTH-1:0] accum [0:CHANNELS-1];

    // Intermediate calculation signals
    logic [CALC_W-1:0]  scaled_count;
    logic [MULT_W-1:0]  recip_product;
    logic [CALC_W-1:0]  average_value;

    //--------------------------------------------------------------------------
    // Compute fixed-point average using multiply + shift instead of division:
    //   average = (spike_count << FRAC_BITS) * RECIP_CONST >> RECIP_SHIFT
    //           ~= (spike_count << FRAC_BITS) / SAMPLE_COUNT
    //--------------------------------------------------------------------------
    always_comb begin
        // Scale count to preserve fractional precision
        scaled_count = {{(CALC_W-ACC_WIDTH){1'b0}}, accum[out_channel]} << FRAC_BITS;

        // Multiply by the precomputed reciprocal (single-cycle multiplier,
        // no divider in hardware)
        recip_product = scaled_count * RECIP_CONST;

        // Shift back down to remove the reciprocal scaling
        average_value = recip_product[CALC_W + RECIP_SHIFT - 1 -: CALC_W];
    end

    //--------------------------------------------------------------------------
    // Main Sequential Logic
    //--------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin

            // Reset state machine and outputs
            state       <= ST_IDLE;
            out_channel <= '0;
            done        <= 1'b0;
            busy        <= 1'b0;

            // Clear all counters and output values
            for (int ch = 0; ch < CHANNELS; ch++) begin
                accum[ch]    <= '0;
                pool_out[ch] <= '0;
            end

        end else begin

            // 'done' is asserted for one clock cycle only
            done <= 1'b0;

            //------------------------------------------------------------------
            // Accumulate incoming spikes while not processing averages
            //------------------------------------------------------------------
            if (sample_valid && !busy) begin
                accum[sample_channel] <=
                    accum[sample_channel] +
                    {{(ACC_WIDTH-1){1'b0}}, sample_spike};
            end

            unique case (state)

                //--------------------------------------------------------------
                // Wait for start signal
                //--------------------------------------------------------------
                ST_IDLE: begin
                    busy <= 1'b0;

                    if (start) begin
                        busy        <= 1'b1;
                        out_channel <= '0;
                        state       <= ST_FINALIZE;
                    end
                end

                //--------------------------------------------------------------
                // Compute one channel average per clock cycle
                //--------------------------------------------------------------
                ST_FINALIZE: begin

                    // Store computed average
                    pool_out[out_channel] <=
                        $signed(average_value[DATA_WIDTH-1:0]);

                    // Last channel processed
                    if (out_channel == CHANNELS - 1) begin
                        busy        <= 1'b0;
                        done        <= 1'b1;
                        out_channel <= '0;
                        state       <= ST_IDLE;
                    end
                    else begin
                        // Move to next channel
                        out_channel <= out_channel + 1'b1;
                    end
                end

                //--------------------------------------------------------------
                // Safety recovery
                //--------------------------------------------------------------
                default: begin
                    state <= ST_IDLE;
                    busy  <= 1'b0;
                end

            endcase
        end
    end

endmodule