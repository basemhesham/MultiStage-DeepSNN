`timescale 1ns/1ps
package bn_parameters_pkg;

    localparam int NUM_OF_BITS    = 18;
    localparam int NUM_OF_FILTERS = 32;

    localparam logic signed [NUM_OF_BITS-1:0] BN1_BIAS [NUM_OF_FILTERS] = '{
        18'b000000000000110000,
        18'b000000000001001011,
        18'b000000000010001111,
        18'b111111111110001011,
        18'b000000000001011000,
        18'b000000000000111010,
        18'b000000000001100011,
        18'b111111111100100001,
        18'b000000000001000010,
        18'b111111111111011010,
        18'b111111111101000101,
        18'b000000000000001111,
        18'b000000000010011101,
        18'b000000000000110101,
        18'b111111111011011100,
        18'b111111111110010111,
        18'b000000000000100011,
        18'b111111111101101000,
        18'b000000000010101000,
        18'b000000000000010010,
        18'b111111111101000100,
        18'b111111111110001110,
        18'b000000000000100110,
        18'b111111111110101011,
        18'b111111111101000000,
        18'b111111111111111000,
        18'b000000000000110011,
        18'b111111111100110101,
        18'b111111111101001010,
        18'b111111111101110010,
        18'b111111111111111111,
        18'b111111111101101101
    };


    localparam logic signed [NUM_OF_BITS-1:0] BN1_WEIGHTS [NUM_OF_FILTERS] = '{
        18'b000000001001011001,
        18'b000000001000001010,
        18'b000000001001100000,
        18'b000000000110101111,
        18'b000000001000101001,
        18'b000000001101000001,
        18'b000000001101000100,
        18'b000000000110100111,
        18'b000000010000001011,
        18'b000000001000001100,
        18'b000000001000111010,
        18'b000000000101110110,
        18'b000000001111101001,
        18'b000000001011010110,
        18'b000000000111000010,
        18'b000000001100000111,
        18'b000000001000010100,
        18'b000000001001010011,
        18'b000000000110111010,
        18'b000000000101001101,
        18'b000000000110001001,
        18'b000000001000101101,
        18'b000000001100011010,
        18'b000000000111011011,
        18'b000000000110011110,
        18'b000000001110101000,
        18'b000000001100110111,
        18'b000000000111010001,
        18'b000000000110110011,
        18'b000000000101000011,
        18'b000000001000010000,
        18'b000000001000001101
    };

endpackage

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
    integer fd_shb; // Added for shb_bus logging

    // Arrays to hold the python mapped hex files directly (flattened)
    logic signed [DATA_WIDTH-1:0] flat_pixels  [0:3455];
    logic signed [DATA_WIDTH-1:0] flat_weights [0:3455];

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

    // We no longer manually calculate shb_out from mac_to_connect.
    // Instead, we will log the actual shb_conv_bus coming out of the
    // adder_tree_shaaban_connect module via hierarchical reference.

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

    task map_flat_arrays();
        integer idx;
        begin
            idx = 0;
            for(tree=0;tree<N_TREES;tree++)
                for(neuron=0;neuron<N_SHAABAN;neuron++)
                    for(tap=0;tap<9;tap++) begin
                        pixels_mapped [tree][neuron][tap] = flat_pixels[idx];
                        weights_mapped[tree][neuron][tap] = flat_weights[idx];
                        idx = idx + 1;
                    end
        end
    endtask

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
        fd_shb = $fopen("shb_bus_output.txt","w"); // Open new output file

        // Load the python-generated mapped arrays directly
        $readmemh("mapped_pixels.hex", flat_pixels);
        $readmemh("mapped_weights.hex", flat_weights);

        if(fin==0) begin
            $display("ERROR opening inputs.txt");
            $finish;
        end

        if(fout==0) begin
            $display("ERROR opening rtl_output.txt");
            $finish;
        end
        
        if(fd_shb==0) begin
            $display("ERROR opening shb_bus_output.txt");
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
        // Targeted Datapath Test
        //--------------------------------------------------
        @(negedge clk);

        src_sel = 0;

        begin
            clear_inputs();
            
            // Map the arrays generated by python directly into the DUT
            map_flat_arrays();
            
            // Wait for combinational logic and 1 clock cycle for any pipelining
            @(negedge clk);
            
            $fwrite(fd_shb, "--- SHB BUS OUTPUT (4 inputs per Shaaban Unit) ---\n");
            // Log the output of the adder tree router for all 32 Shaaban units.
            // Using hierarchical reference to read the output of u_shaaban_adder_tree.u_connect
            for(int s = 0; s < N_SHAABAN; s++) begin
                // The bus is packed: [(INPUTS_PER_SHB*DATA_WIDTH)-1:0]
                // We unpack it here for easy reading
                logic signed [DATA_WIDTH-1:0] val3, val2, val1, val0;
                
                val0 = dut.u_shaaban_adder_tree.u_connect.shb_conv_bus[s][0*DATA_WIDTH +: DATA_WIDTH];
                val1 = dut.u_shaaban_adder_tree.u_connect.shb_conv_bus[s][1*DATA_WIDTH +: DATA_WIDTH];
                val2 = dut.u_shaaban_adder_tree.u_connect.shb_conv_bus[s][2*DATA_WIDTH +: DATA_WIDTH];
                val3 = dut.u_shaaban_adder_tree.u_connect.shb_conv_bus[s][3*DATA_WIDTH +: DATA_WIDTH];
                
                $fwrite(fd_shb, "Shaaban[%02d] | In3:%0d In2:%0d In1:%0d In0:%0d\n", 
                        s, val3, val2, val1, val0);
            end
        end

        // Wait for pipeline to flush
        repeat(5) @(negedge clk);

        display_results();
        
        $fclose(fin);
        $fclose(fout);
        $fclose(fd_shb); // Close the log file

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