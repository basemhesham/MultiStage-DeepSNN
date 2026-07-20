`timescale 1ns/1ns

module stage2_top_tb;

    localparam int DATA_WIDTH   = 18;
    localparam int NUM_INPUTS   = 9;
    localparam int NUM_CHANNELS = 32;
    localparam int INPUT_SIDE   = 130;
    localparam int OUTPUT_SIDE  = 64;
    localparam int CLK_PERIOD   = 10;

    logic clk;
    logic rst;
    logic arst_n;
    logic enable;

    logic                         pixel_mem_wr_en;
    logic [5:0]                   pixel_mem_wr_addr;
    logic [(384*DATA_WIDTH)-1:0]  pixel_mem_wr_data;
    logic [(12*NUM_CHANNELS*NUM_INPUTS*DATA_WIDTH)-1:0] sim_pixels;

    logic [NUM_CHANNELS-1:0]      spike_out;
    logic [(4*DATA_WIDTH)-1:0]    class_logits;
    logic                         classifier_done;
    logic                         classifier_busy;
    logic                         snn_done;
    logic                         done;

    logic signed [INPUT_SIDE-1:0][DATA_WIDTH-1:0]
        arr_in [0:(NUM_CHANNELS*INPUT_SIDE)-1];

    logic signed [DATA_WIDTH-1:0] actual_pool;
    logic signed [DATA_WIDTH-1:0] expected_pool;
    logic signed [DATA_WIDTH-1:0] actual_spike;
    logic signed [DATA_WIDTH-1:0] expected_spike;
    logic signed [DATA_WIDTH-1:0] actual_conv [0:3];
    logic signed [DATA_WIDTH-1:0] expected_conv [0:3];
    logic                         position_mismatch;

    int checked_counter;
    int failed_counter;
    always #(CLK_PERIOD/2) clk = ~clk;

    task automatic load_windows(input int output_row, input int output_col);
        int input_row;
        int input_col;
        int window_row;
        int window_col;
        int tap_row;
        int tap_col;
        begin
            sim_pixels = '{default:'0};
            input_row = output_row * 2;
            input_col = output_col * 2;

            for (int window = 0; window < 4; window++) begin
                window_row = window % 2;
                window_col = window / 2;

                for (int channel = 0;
                     channel < NUM_CHANNELS;
                     channel++) begin
                    for (int tap = 0; tap < NUM_INPUTS; tap++) begin
                        tap_row = tap / 3;
                        tap_col = tap % 3;
                        sim_pixels[
                            ((((window * NUM_CHANNELS) + channel) *
                              NUM_INPUTS) + tap) * DATA_WIDTH
                            +: DATA_WIDTH
                        ] =
                            arr_in[
                                (channel * INPUT_SIDE) +
                                input_row + window_row + tap_row
                            ][
                                input_col + window_col + tap_col
                            ];
                    end
                end
            end
        end
    endtask

    function automatic logic signed [DATA_WIDTH-1:0] reference_conv(
        input int window
    );
        longint signed channel_acc;
        longint signed conv_acc;
        logic signed [DATA_WIDTH-1:0] pixel_value;
        logic signed [DATA_WIDTH-1:0] weight_value;
        logic signed [DATA_WIDTH-1:0] channel_result;
        begin
            conv_acc = 0;

            for (int channel = 0;
                 channel < NUM_CHANNELS;
                 channel++) begin
                channel_acc = 0;

                for (int tap = 0; tap < NUM_INPUTS; tap++) begin
                    pixel_value = $signed(sim_pixels[
                        ((((window * NUM_CHANNELS) + channel) *
                          NUM_INPUTS) + tap) * DATA_WIDTH
                        +: DATA_WIDTH
                    ]);
                    weight_value =
                        $signed(DUT.weights_mapped[window][channel][tap]);
                    channel_acc += pixel_value * weight_value;
                end

                channel_result = channel_acc >>> 9;
                conv_acc += channel_result;
            end

            reference_conv = conv_acc[DATA_WIDTH-1:0];
        end
    endfunction

    function automatic logic signed [DATA_WIDTH-1:0] reference_pool(
        input int output_row,
        input int output_col
    );
        longint signed bn_acc;
        logic signed [DATA_WIDTH-1:0] conv_result;
        logic signed [DATA_WIDTH-1:0] relu_result;
        logic signed [DATA_WIDTH-1:0] bn_result;
        logic signed [DATA_WIDTH-1:0] max_result;
        begin
            max_result = '0;

            for (int window = 0; window < 4; window++) begin
                conv_result = reference_conv(window);
                relu_result =
                    ($signed(conv_result) > 0) ? conv_result : '0;
                bn_acc = ($signed(relu_result) * 18'sd376) +
                         (-18'sd402 <<< 9);
                bn_result = bn_acc >>> 9;

                if ((window == 0) ||
                    ($signed(bn_result) > $signed(max_result)))
                    max_result = bn_result;
            end

            reference_pool = max_result;
        end
    endfunction

    initial begin
        clk                 = 1'b0;
        rst                 = 1'b1;
        arst_n              = 1'b0;
        enable              = 1'b0;
        pixel_mem_wr_en     = 1'b0;
        pixel_mem_wr_addr   = '0;
        pixel_mem_wr_data   = '0;
        sim_pixels          = '{default:'0};
        checked_counter     = 0;
        failed_counter      = 0;

        $readmemb("bin_export/input/lif1_out_padded.txt", arr_in);

        repeat (2) @(posedge clk);
        arst_n = 1'b1;
        rst    = 1'b0;

        for (int output_row = 0;
             output_row < OUTPUT_SIDE;
             output_row++) begin
            for (int output_col = 0;
                 output_col < OUTPUT_SIDE;
                 output_col++) begin
                @(negedge clk);
                load_windows(output_row, output_col);
                #1;

                expected_pool  =
                    reference_pool(output_row, output_col);
                expected_spike = '0;
                expected_spike[9] =
                    ($signed(expected_pool) >= 18'sd512);
                actual_pool    =
                    DUT.u_shaaban_array.gen_shaaban_array[0]
                        .u_shb.final_pool_out;
                actual_spike   = '0;
                actual_spike[9] = spike_out[0];

                position_mismatch =
                    (actual_pool !== expected_pool) ||
                    (actual_spike !== expected_spike);

                for (int window = 0; window < 4; window++) begin
                    expected_conv[window] = reference_conv(window);
                    actual_conv[window] =
                        $signed(DUT.shb_bus[0][
                            window*DATA_WIDTH +: DATA_WIDTH
                        ]);
                    if (actual_conv[window] !== expected_conv[window])
                        position_mismatch = 1'b1;
                end

                if (position_mismatch) begin
                    if (failed_counter < 20) begin
                        $display(
                            "Mismatch row=%0d col=%0d expected_pool=%0d actual_pool=%0d expected_spike=%0b actual_spike=%0b",
                            output_row,
                            output_col,
                            $signed(expected_pool),
                            $signed(actual_pool),
                            expected_spike,
                            actual_spike
                        );
                        $display(
                            "  conv expected=%0d,%0d,%0d,%0d actual=%0d,%0d,%0d,%0d",
                            $signed(expected_conv[0]),
                            $signed(expected_conv[1]),
                            $signed(expected_conv[2]),
                            $signed(expected_conv[3]),
                            $signed(actual_conv[0]),
                            $signed(actual_conv[1]),
                            $signed(actual_conv[2]),
                            $signed(actual_conv[3])
                        );
                    end
                    failed_counter++;
                end

                checked_counter++;
            end
        end

        $display("------------------------------------------------------------");
        $display("Checked Stage 2 output positions = %0d", checked_counter);
        $display("Total mismatches                 = %0d", failed_counter);

        if (failed_counter != 0)
            $fatal(1, "Stage 2 verification failed");

        $display(
            "PASS: deep_snn_top Stage 2 has no convolution, pool, or spike mismatches."
        );
        $finish;
    end

    deep_snn_top DUT (
        .clk                 (clk),
        .rst                 (rst),
        .arst_n              (arst_n),
        .enable              (enable),
        .pixel_mem_wr_en     (pixel_mem_wr_en),
        .pixel_mem_wr_addr   (pixel_mem_wr_addr),
        .pixel_mem_wr_data   (pixel_mem_wr_data),
        .sim_pixels_override (1'b1),
        .sim_pixels          (sim_pixels),
        .spike_out           (spike_out),
        .class_logits        (class_logits),
        .classifier_done     (classifier_done),
        .classifier_busy     (classifier_busy),
        .snn_done            (snn_done),
        .done                (done)
    );

    initial begin
        force DUT.src_sel      = 2'b01;
        force DUT.conv2_filter = 6'd0;
        force DUT.mult_weight_param[0] = 18'sd376;
        force DUT.add_weight_param[0]  = -18'sd402;

        force DUT.u_shaaban_array.gen_shaaban_array[0]
            .u_shb.LIF_ints.mem_reg = '0;
        force DUT.u_shaaban_array.gen_shaaban_array[0]
            .u_shb.LIF_ints.spike_reg = 1'b0;
    end

    initial begin
        #(CLK_PERIOD * 10000);
        $fatal(1, "Timeout waiting for Stage 2 verification to finish");
    end

endmodule
