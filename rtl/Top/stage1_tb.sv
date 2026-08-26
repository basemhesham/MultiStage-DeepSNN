`timescale 1ns/1ns

module stage1_tb;

    localparam int DATA_WIDTH       = 18;
    localparam int INPUT_SIDE       = 260;
    localparam int OUTPUT_SIDE      = 128;
    localparam int NUM_CHANNELS     = 32;
    localparam int CLK_PERIOD       = 10;
    localparam int PIPELINE_LATENCY = 1;
    localparam int TEST_ROWS        = OUTPUT_SIDE;
    localparam int TEST_COLS        = OUTPUT_SIDE;

    logic clk;
    logic rst;
    logic arst_n;
    logic enable;

    logic                         pixel_mem_wr_en;
    logic [5:0]                   pixel_mem_wr_addr;
    logic [(384*DATA_WIDTH)-1:0]  pixel_mem_wr_data;

    logic [NUM_CHANNELS-1:0]      spike_out;
    logic [(4*DATA_WIDTH)-1:0]    class_logits;
    logic                         classifier_done;
    logic                         classifier_busy;
    logic                         snn_done;
    logic                         done;

    logic signed [INPUT_SIDE-1:0][DATA_WIDTH-1:0]
        arr_in [0:INPUT_SIDE-1];
    logic signed [4:0][DATA_WIDTH-1:0]
        arr_filter [0:(NUM_CHANNELS*5)-1];
    logic signed [DATA_WIDTH-1:0] arr_bn_weight [0:NUM_CHANNELS-1];
    logic signed [DATA_WIDTH-1:0] arr_bn_bias [0:NUM_CHANNELS-1];

    logic signed [DATA_WIDTH-1:0] actual_pool [0:NUM_CHANNELS-1];
    logic signed [(4*DATA_WIDTH)-1:0] actual_conv_bus [0:NUM_CHANNELS-1];
    logic signed [DATA_WIDTH-1:0] expected_spike;
    logic signed [DATA_WIDTH-1:0] actual_spike;
    logic signed [DATA_WIDTH-1:0] expected_pool;

    int expected_tags[$];
    int pipeline_cycles;
    int checked_counter;
    int failed_counter;
    bit test_active;
    bit drive_done;

    always #(CLK_PERIOD/2) clk = ~clk;

    task automatic load_patch(input int output_row, input int output_col);
        int patch_row;
        int patch_col;
        int input_row;
        int input_col;
        begin
            pixel_mem_wr_data = '0;
            input_row = output_row * 2;
            input_col = output_col * 2;

            for (patch_row = 0; patch_row < 6; patch_row++) begin
                for (patch_col = 0; patch_col < 6; patch_col++) begin
                    pixel_mem_wr_data[
                        ((patch_row * 6 + patch_col) * DATA_WIDTH)
                        +: DATA_WIDTH
                    ] = arr_in[input_row + patch_row][input_col + patch_col];
                end
            end
        end
    endtask

    function automatic logic signed [DATA_WIDTH-1:0] reference_conv(
        input int output_row,
        input int output_col,
        input int channel,
        input int window
    );
        longint signed chunk_acc;
        logic signed [DATA_WIDTH-1:0] chunk_result;
        logic signed [DATA_WIDTH-1:0] conv_result;
        logic signed [19:0] conv_acc;
        int padded_kernel_index;
        int kernel_index;
        int kernel_row;
        int kernel_col;
        int window_row;
        int window_col;
        begin
            conv_acc  = '0;
            window_row = window / 2;
            window_col = window % 2;

            for (int chunk = 0; chunk < 3; chunk++) begin
                chunk_acc = 0;

                for (int tap = 0; tap < 9; tap++) begin
                    padded_kernel_index = (chunk * 9) + tap;

                    if ((padded_kernel_index != 9) &&
                        (padded_kernel_index != 18)) begin
                        if (padded_kernel_index > 18)
                            kernel_index = padded_kernel_index - 2;
                        else if (padded_kernel_index > 9)
                            kernel_index = padded_kernel_index - 1;
                        else
                            kernel_index = padded_kernel_index;

                        kernel_row = kernel_index % 5;
                        kernel_col = kernel_index / 5;

                        chunk_acc +=
                            $signed(arr_in[
                                (output_row * 2) + window_row + kernel_row
                            ][
                                (output_col * 2) + window_col + kernel_col
                            ]) *
                            $signed(arr_filter[
                                (channel * 5) + kernel_row
                            ][4 - kernel_col]);
                    end
                end

                chunk_result = chunk_acc >>> 9;
                conv_acc += chunk_result;
            end

            conv_result = conv_acc[DATA_WIDTH-1:0];
            reference_conv = conv_result;
        end
    endfunction

    function automatic logic signed [DATA_WIDTH-1:0] reference_pool(
        input int output_row,
        input int output_col,
        input int channel
    );
        longint signed bn_acc;
        logic signed [DATA_WIDTH-1:0] conv_result;
        logic signed [DATA_WIDTH-1:0] relu_result;
        logic signed [DATA_WIDTH-1:0] bn_result;
        logic signed [DATA_WIDTH-1:0] max_result;
        begin
            max_result = '0;

            for (int window = 0; window < 4; window++) begin
                conv_result =
                    reference_conv(output_row, output_col, channel, window);
                relu_result = ($signed(conv_result) > 0) ? conv_result : '0;
                bn_acc = ($signed(relu_result) *
                          $signed(arr_bn_weight[channel])) +
                         ($signed(arr_bn_bias[channel]) <<< 9);
                bn_result = bn_acc >>> 9;

                if ((window == 0) || ($signed(bn_result) > $signed(max_result)))
                    max_result = bn_result;
            end

            reference_pool = max_result;
        end
    endfunction

    initial begin
        clk               = 1'b0;
        rst               = 1'b1;
        arst_n            = 1'b0;
        enable            = 1'b0;
        pixel_mem_wr_en   = 1'b0;
        pixel_mem_wr_addr = 6'd0;
        pixel_mem_wr_data = '0;
        pipeline_cycles   = 0;
        checked_counter   = 0;
        failed_counter    = 0;
        test_active       = 1'b0;
        drive_done        = 1'b0;

        $readmemb("bin_export/input/input_t0.txt", arr_in);
        $readmemb("bin_export/weights/w_conv1_weight.txt", arr_filter);
        $readmemb("bin_export/weights/w_bn1_weight.txt", arr_bn_weight);
        $readmemb("bin_export/weights/w_bn1_bias.txt", arr_bn_bias);

        repeat (2) @(posedge clk);
        arst_n = 1'b1;
        rst    = 1'b0;

        for (int output_row = 0; output_row < TEST_ROWS; output_row++) begin
            for (int output_col = 0; output_col < TEST_COLS; output_col++) begin
                @(negedge clk);
                load_patch(output_row, output_col);
                pixel_mem_wr_en = 1'b1;
                expected_tags.push_back((output_row * OUTPUT_SIDE) + output_col);
                test_active = 1'b1;
            end
        end

        @(negedge clk);
        pixel_mem_wr_en = 1'b0;
        drive_done      = 1'b1;
    end

    always @(posedge clk) begin : scoreboard
        int tag;
        int output_row;
        int output_col;

        if (!arst_n || rst) begin
            pipeline_cycles = 0;
        end else if (test_active) begin
            #1;

            if ((pipeline_cycles >= PIPELINE_LATENCY) &&
                (expected_tags.size() != 0)) begin
                tag        = expected_tags.pop_front();
                output_row = tag / OUTPUT_SIDE;
                output_col = tag % OUTPUT_SIDE;

                for (int channel = 0; channel < NUM_CHANNELS; channel++) begin
                    expected_pool  =
                        reference_pool(output_row, output_col, channel);
                    expected_spike = '0;
                    expected_spike[9] = ($signed(expected_pool) >= 18'sd512);
                    actual_spike    = '0;
                    actual_spike[9] = spike_out[channel];

                    if ((actual_spike !== expected_spike) ||
                        (actual_pool[channel] !== expected_pool)) begin
                        if (failed_counter < 20) begin
                            $display(
                                "Mismatch ch=%0d row=%0d col=%0d expected_spike=%0b actual_spike=%0b expected_pool=%0d actual_pool=%0d",
                                channel,
                                output_row,
                                output_col,
                                expected_spike,
                                actual_spike,
                                $signed(expected_pool),
                                $signed(actual_pool[channel])
                            );
                            $display(
                                "  conv expected=%0d,%0d,%0d,%0d actual=%0d,%0d,%0d,%0d",
                                $signed(reference_conv(output_row, output_col, channel, 0)),
                                $signed(reference_conv(output_row, output_col, channel, 1)),
                                $signed(reference_conv(output_row, output_col, channel, 2)),
                                $signed(reference_conv(output_row, output_col, channel, 3)),
                                $signed(actual_conv_bus[channel][0*DATA_WIDTH +: DATA_WIDTH]),
                                $signed(actual_conv_bus[channel][1*DATA_WIDTH +: DATA_WIDTH]),
                                $signed(actual_conv_bus[channel][2*DATA_WIDTH +: DATA_WIDTH]),
                                $signed(actual_conv_bus[channel][3*DATA_WIDTH +: DATA_WIDTH])
                            );
                        end
                        failed_counter++;
                    end
                end

                checked_counter++;
            end

            pipeline_cycles++;

            if (drive_done && (expected_tags.size() == 0)) begin
                $display("------------------------------------------------------------");
                $display("Checked Stage 1 output positions = %0d", checked_counter);
                $display("Checked Stage 1 spikes           = %0d",
                         checked_counter * NUM_CHANNELS);
                $display("Total mismatches                 = %0d", failed_counter);

                if (failed_counter != 0)
                    $fatal(1, "Stage 1 verification failed");

                $display("PASS: deep_snn_top Stage 1 has no pool or spike mismatches.");
                $finish;
            end
        end
    end

    deep_snn_top DUT (
        .clk               (clk),
        .rst               (rst),
        .arst_n            (arst_n),
        .enable            (enable),
        .pixel_mem_wr_en   (pixel_mem_wr_en),
        .pixel_mem_wr_addr (pixel_mem_wr_addr),
        .pixel_mem_wr_data (pixel_mem_wr_data),
        .spike_out         (spike_out),
        .class_logits      (class_logits),
        .classifier_done   (classifier_done),
        .classifier_busy   (classifier_busy),
        .snn_done          (snn_done),
        .done              (done)
    );

    // This is a focused Stage 1 test. Keep the shared datapath routed to
    // Stage 1 and hold each spatial LIF state at its t0 initial value.
    initial force DUT.src_sel = 2'b00;

    genvar channel_index;
    generate
        for (channel_index = 0;
             channel_index < NUM_CHANNELS;
             channel_index++) begin : gen_stage1_observers
            assign actual_pool[channel_index] =
                DUT.u_shaaban_array.gen_shaaban_array[channel_index]
                    .u_shb.final_pool_out;
            assign actual_conv_bus[channel_index] = DUT.shb_bus[channel_index];

            initial begin
                force DUT.u_shaaban_array.gen_shaaban_array[channel_index]
                    .u_shb.LIF_ints.mem_reg = '0;
                force DUT.u_shaaban_array.gen_shaaban_array[channel_index]
                    .u_shb.LIF_ints.spike_reg = 1'b0;
            end
        end
    endgenerate

    initial begin
        #(CLK_PERIOD * 200000);
        $fatal(1, "Timeout waiting for Stage 1 verification to finish");
    end

endmodule
