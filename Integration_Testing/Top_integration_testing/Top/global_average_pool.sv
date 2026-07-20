`timescale 1ns / 1ps

module global_average_pool #(
    parameter int DATA_WIDTH   = 18,
    parameter int FRAC_BITS    = 9,
    parameter int CHANNELS     = 128,
    parameter int SAMPLE_COUNT = 169,
    parameter int ACC_WIDTH    = (SAMPLE_COUNT <= 1) ? 1 : $clog2(SAMPLE_COUNT + 1)
)(
    input  logic                         clk,
    input  logic                         rst,
    input  logic                         clear,

    input  logic                         sample_valid,
    input  logic [$clog2(CHANNELS)-1:0]  sample_channel,
    input  logic                         sample_spike,

    input  logic                         start,
    output logic signed [DATA_WIDTH-1:0] pool_out [0:CHANNELS-1],
    output logic                         done,
    output logic                         busy
);

    localparam int CHANNEL_W = (CHANNELS <= 1) ? 1 : $clog2(CHANNELS);
    localparam int CALC_W    = DATA_WIDTH + ACC_WIDTH + FRAC_BITS;

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_FINALIZE
    } state_t;

    state_t state;

    logic [CHANNEL_W-1:0] out_channel;
    logic [ACC_WIDTH-1:0] accum [0:CHANNELS-1];
    logic [CALC_W-1:0] scaled_count;
    logic [CALC_W-1:0] average_value;

    always_comb begin
        scaled_count = {{(CALC_W-ACC_WIDTH){1'b0}}, accum[out_channel]} << FRAC_BITS;
        average_value = scaled_count / SAMPLE_COUNT;
    end

    always_ff @(posedge clk) begin
        if (rst || clear) begin
            state       <= ST_IDLE;
            out_channel <= '0;
            done        <= 1'b0;
            busy        <= 1'b0;

            for (int ch = 0; ch < CHANNELS; ch++) begin
                accum[ch]    <= '0;
                pool_out[ch] <= '0;
            end
        end else begin
            done <= 1'b0;

            if (sample_valid && !busy) begin
                accum[sample_channel] <= accum[sample_channel] + {{(ACC_WIDTH-1){1'b0}}, sample_spike};
            end

            unique case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy        <= 1'b1;
                        out_channel <= '0;
                        state       <= ST_FINALIZE;
                    end
                end

                ST_FINALIZE: begin
                    pool_out[out_channel] <= $signed(average_value[DATA_WIDTH-1:0]);

                    if (out_channel == CHANNELS - 1) begin
                        busy        <= 1'b0;
                        done        <= 1'b1;
                        out_channel <= '0;
                        state       <= ST_IDLE;
                    end else begin
                        out_channel <= out_channel + 1'b1;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                    busy  <= 1'b0;
                end
            endcase
        end
    end

endmodule
