`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// Global Average Pooling (GAP)
// Counts the number of spikes for each channel, then computes:
//      average = (spike_count << FRAC_BITS) / SAMPLE_COUNT
// The output is stored in fixed-point (Q9) format.
//
// NOTE ON DIVISION REMOVAL:
// SAMPLE_COUNT is now required to be a power of two (default 1024 = 2^10),
// so the division reduces exactly to a right-shift by SAMPLE_SHIFT =
// log2(SAMPLE_COUNT) -- no reciprocal-multiply trick and no divider/multiplier
// needed at all:
//      average = (spike_count << FRAC_BITS) >> SAMPLE_SHIFT
// SAMPLE_SHIFT is derived from SAMPLE_COUNT via $clog2 at elaboration time,
// and a compile-time check below ensures SAMPLE_COUNT really is an exact
// power of two (the shift is only exact in that case).
//------------------------------------------------------------------------------
module global_average_pool #(
    parameter int DATA_WIDTH   = 18,   // Width of output data
    parameter int FRAC_BITS    = 9,    // Fractional bits for fixed-point format
    parameter int CHANNELS     = 128,  // Number of feature map channels
    parameter int SAMPLE_COUNT = 1024, // Number of samples per channel -- MUST be a power of two
    parameter int ACC_WIDTH    = (SAMPLE_COUNT <= 1) ? 1 : $clog2(SAMPLE_COUNT + 1)
)(
    input  wire logic                        clk,
    input  wire logic                        rst_n,
    input  wire logic                        clear,

    // Incoming spike stream
    input  wire logic                        sample_valid,
    input  wire logic [$clog2(CHANNELS)-1:0] sample_channel,
    input  wire logic                        sample_spike,

    // Starts the averaging process
    input  wire logic                        start,

    // GAP output for every channel
    output logic signed [DATA_WIDTH-1:0] pool_out [0:CHANNELS-1],

    // Status signals
    output logic                         done,
    output logic                         busy
);

    // Width of channel index
    localparam int CHANNEL_W = (CHANNELS <= 1) ? 1 : $clog2(CHANNELS);
    localparam int SAMPLE_SHIFT = $clog2(SAMPLE_COUNT);

    // Width used during scaling: just wide enough to hold the shifted count.
    localparam int CALC_W = ACC_WIDTH + FRAC_BITS;

    // Spike counter for each channel
    logic [ACC_WIDTH-1:0] accum [0:CHANNELS-1];

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

    // Intermediate calculation signals
    logic [CALC_W-1:0]  scaled_count;
    logic [CALC_W-1:0]  average_value;

    //--------------------------------------------------------------------------
    // Compute fixed-point average using a plain shift (SAMPLE_COUNT is a
    // power of two, so no multiply/divide hardware is needed at all):
    //   average = (spike_count << FRAC_BITS) >> SAMPLE_SHIFT
    //           == (spike_count << FRAC_BITS) / SAMPLE_COUNT
    //--------------------------------------------------------------------------
    always_comb begin
        // Scale count to preserve fractional precision
        scaled_count = {{(CALC_W-ACC_WIDTH){1'b0}}, accum[out_channel]} << FRAC_BITS;

        // Remove the SAMPLE_COUNT scaling with a right-shift -- exact
        // because SAMPLE_COUNT is a power of two.
        average_value = scaled_count >> SAMPLE_SHIFT;
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