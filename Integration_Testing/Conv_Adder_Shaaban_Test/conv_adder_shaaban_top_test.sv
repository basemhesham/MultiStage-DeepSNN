`timescale 1ns/1ps

import bn_parameters_pkg::*;

module conv_adder_shaaban_top_test;

    //==========================================================================
    // Parameters
    //==========================================================================
    parameter DATA_WIDTH     = 18;
    parameter N_SHAABAN      = 32;
    parameter MAC_OUT_W      = 40;
    parameter INPUTS_PER_SHB = 4;
    parameter N_TREES        = 12;

    integer fin;
    integer fout;

    //==========================================================================
    // DUT Signals
    //==========================================================================
    logic clk;
    logic rst;
    logic [1:0] src_sel;

    logic signed [DATA_WIDTH-1:0] conv_bias_param   [0:N_SHAABAN-1];
    logic signed [DATA_WIDTH-1:0] mult_weight_param [0:N_SHAABAN-1];
    logic signed [DATA_WIDTH-1:0] add_weight_param  [0:N_SHAABAN-1];

    logic signed [DATA_WIDTH-1:0] pixels_mapped
        [0:N_TREES-1][0:N_SHAABAN-1][0:8];

    logic signed [DATA_WIDTH-1:0] weights_mapped
        [0:N_TREES-1][0:N_SHAABAN-1][0:8];

    logic [N_SHAABAN-1:0] spike_out;

    logic [0:N_SHAABAN-1] shaaban_spike_bus
        [0:N_SHAABAN-1];

    //==========================================================================
    // DUT
    //==========================================================================
    conv_Adder_shaaban_top #(
        .DATA_WIDTH(DATA_WIDTH),
        .N_SHAABAN(N_SHAABAN),
        .MAC_OUT_W(MAC_OUT_W),
        .INPUTS_PER_SHB(INPUTS_PER_SHB),
        .N_TREES(N_TREES)
    ) dut (
        .clk(clk),
        .rst(rst),
        .src_sel(src_sel),

        .conv_bias_param(conv_bias_param),
        .mult_weight_param(mult_weight_param),
        .add_weight_param(add_weight_param),

        .pixels_mapped(pixels_mapped),
        .weights_mapped(weights_mapped),

        .spike_out(spike_out),
        .shaaban_spike_bus(shaaban_spike_bus)
    );

    //==========================================================================
    // Clock
    //==========================================================================
    initial clk = 0;
    always #5 clk = ~clk;

    //==========================================================================
    // Loop Variables
    //==========================================================================
    integer tree;
    integer neuron;
    integer tap;

    //==========================================================================
    // Tasks
    //==========================================================================

    task load_bn_parameters();
        integer i;
        begin
            for(i=0;i<N_SHAABAN;i++) begin
                conv_bias_param[i]   = '0;
                mult_weight_param[i] = BN1_WEIGHTS[i];
                add_weight_param[i]  = BN1_BIAS[i];
            end
        end
    endtask

    //--------------------------------------------------------

    task clear_inputs();
        begin
            for(tree=0;tree<N_TREES;tree++)
                for(neuron=0;neuron<N_SHAABAN;neuron++)
                    for(tap=0;tap<9;tap++) begin
                        pixels_mapped [tree][neuron][tap] = '0;
                        weights_mapped[tree][neuron][tap] = '0;
                    end
        end
    endtask

    //--------------------------------------------------------

    task random_pixels();
    begin
        $fwrite(fin,"PIXELS\n");

        for(tree=0;tree<N_TREES;tree++)
            for(neuron=0;neuron<N_SHAABAN;neuron++)
                for(tap=0;tap<9;tap++) begin

                    pixels_mapped[tree][neuron][tap] =
                        $urandom_range(-50,50);

                    $fwrite(fin,"%0d ",
                        pixels_mapped[tree][neuron][tap]);

                end

        $fwrite(fin,"\n");

    end
    endtask

    //--------------------------------------------------------

    task random_weights();
    begin

        $fwrite(fin,"CONV_WEIGHTS\n");

        for(tree=0;tree<N_TREES;tree++)
            for(neuron=0;neuron<N_SHAABAN;neuron++)
                for(tap=0;tap<9;tap++) begin

                    weights_mapped[tree][neuron][tap] =
                        $urandom_range(-5,5);

                    $fwrite(fin,"%0d ",
                        weights_mapped[tree][neuron][tap]);

                end

        $fwrite(fin,"\n");

    end
    endtask

    // //--------------------------------------------------------

    // task constant_pixels(input integer value);
    //     begin
    //         for(tree=0;tree<N_TREES;tree++)
    //             for(neuron=0;neuron<N_SHAABAN;neuron++)
    //                 for(tap=0;tap<9;tap++)
    //                     pixels_mapped[tree][neuron][tap] = value;
    //     end
    // endtask

    //--------------------------------------------------------

    // task constant_weights(input integer value);
    //     begin
    //         for(tree=0;tree<N_TREES;tree++)
    //             for(neuron=0;neuron<N_SHAABAN;neuron++)
    //                 for(tap=0;tap<9;tap++)
    //                     weights_mapped[tree][neuron][tap] = value;
    //     end
    // endtask

    //--------------------------------------------------------

    task display_results();
        integer i;
        begin

            $display("");
            $display("======================================================");
            $display("Time      = %0t",$time);
            $display("Stage     = %0d",src_sel);
            $display("Spike Out = %h",spike_out);

            for(i=0;i<N_SHAABAN;i++)
                $display("Neuron[%0d] = %b",i,shaaban_spike_bus[i]);

            $display("======================================================");
            $display("");

        end
    endtask

    //==========================================================================
    // Stimulus
    //==========================================================================
    initial begin

        fin  = $fopen("inputs.txt","w");
        fout = $fopen("rtl_output.txt","w");

        if(fin==0) begin
            $display("ERROR opening inputs.txt");
            $finish;
        end

        if(fout==0) begin
            $display("ERROR opening rtl_output.txt");
            $finish;
        end

        rst     = 0;
        src_sel = 0;

        clear_inputs();
        load_bn_parameters();

        $fwrite(fin,"BN_WEIGHTS\n");

        for(int i=0;i<N_SHAABAN;i++)
            $fwrite(fin,"%0d ",mult_weight_param[i]);

        $fwrite(fin,"\n");

        $fwrite(fin,"BN_BIAS\n");

        for(int i=0;i<N_SHAABAN;i++)
            $fwrite(fin,"%0d ",add_weight_param[i]);

        $fwrite(fin,"\n");

        //--------------------------------------------------
        // Reset
        //--------------------------------------------------
        repeat(5) @(negedge clk);

        rst = 1;

        //--------------------------------------------------
        // Test 1
        //--------------------------------------------------
        // @(negedge clk);

        // src_sel = 0;

        // constant_pixels(10);
        // constant_weights(2);

        // repeat(20) @(negedge clk);

        // display_results();

        //--------------------------------------------------
        // Test 2
        //--------------------------------------------------
        // @(negedge clk);

        // src_sel = 1;

        // constant_pixels(30);
        // constant_weights(5);

        // repeat(20) @(negedge clk);

        // display_results();

        //--------------------------------------------------
        // Test 3
        //--------------------------------------------------
        // @(negedge clk);

        // src_sel = 0;

        // random_pixels();
        // constant_weights(1);

        // repeat(20) @(negedge clk);

        // display_results();

        //--------------------------------------------------
        // Test 4
        //--------------------------------------------------
        @(negedge clk);

        src_sel = 0;

        repeat(1) begin
            random_pixels();
            random_weights();
            @(negedge clk);
            // $fwrite(fout,"SPIKE_OUT\n");
            // $fwrite(fout,"%032b\n",spike_out);

            $fwrite(fout,"SPIKE_BUS\n");
            for(int i=0;i<N_SHAABAN;i++)
                $fwrite(fout,"%b ",shaaban_spike_bus[i]);

            $fwrite(fout,"\n");
        end



        display_results();

        //--------------------------------------------------
        // Random Regression
        //--------------------------------------------------
        // repeat(100) begin

        //     @(negedge clk);

        //     src_sel = $urandom_range(0,1);

        //     random_pixels();
        //     random_weights();

        // end

        // repeat(20) @(negedge clk);

        // display_results();

        $finish;

    end

    //==========================================================================
    // Monitor
    //==========================================================================
    initial begin

        $monitor("[%0t] rst=%0b src_sel=%0b spike_out=%h",
                 $time,
                 rst,
                 src_sel,
                 spike_out);

    end

endmodule