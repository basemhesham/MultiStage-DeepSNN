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

`timescale 1ns/1ps

import bn_parameters_pkg::*;

module conv_adder_shaaban_top_test;

    parameter DATA_WIDTH     = 18;
    parameter N_SHAABAN      = 32;
    parameter MAC_OUT_W      = 40;
    parameter INPUTS_PER_SHB = 4;
    parameter N_TREES        = 12;

    integer fd_shb; 

    // Massive array for 100 cycles of 3456 pixels (345,600 values total)
    logic signed [DATA_WIDTH-1:0] flat_pixels  [0:345599];
    // Weights stay fixed for all 100 cycles (only 3456 values)
    logic signed [DATA_WIDTH-1:0] flat_weights [0:3455];

    logic clk;
    logic rst;
    logic [1:0] src_sel;

    logic signed [DATA_WIDTH-1:0] conv_bias_param   [0:N_SHAABAN-1];
    logic signed [DATA_WIDTH-1:0] mult_weight_param [0:N_SHAABAN-1];
    logic signed [DATA_WIDTH-1:0] add_weight_param  [0:N_SHAABAN-1];

    logic signed [DATA_WIDTH-1:0] pixels_mapped  [0:N_TREES-1][0:N_SHAABAN-1][0:8];
    logic signed [DATA_WIDTH-1:0] weights_mapped [0:N_TREES-1][0:N_SHAABAN-1][0:8];

    logic [N_SHAABAN-1:0] spike_out;
    logic [0:N_SHAABAN-1] shaaban_spike_bus [0:N_SHAABAN-1];

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

    initial clk = 0;
    always #5 clk = ~clk;

    integer tree, neuron, tap;

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

    task map_weights_once();
        integer idx;
        begin
            idx = 0;
            for(tree=0;tree<N_TREES;tree++)
                for(neuron=0;neuron<N_SHAABAN;neuron++)
                    for(tap=0;tap<9;tap++) begin
                        weights_mapped[tree][neuron][tap] = flat_weights[idx];
                        idx = idx + 1;
                    end
        end
    endtask

    task load_pixels_for_cycle(input int cycle_offset);
        integer idx;
        begin
            idx = cycle_offset;
            for(tree=0;tree<N_TREES;tree++)
                for(neuron=0;neuron<N_SHAABAN;neuron++)
                    for(tap=0;tap<9;tap++) begin
                        pixels_mapped[tree][neuron][tap] = flat_pixels[idx];
                        idx = idx + 1;
                    end
        end
    endtask

    initial begin
        fd_shb = $fopen("shb_bus_output.txt","w");

        // Load files generated by the python script
        $readmemh("mapped_pixels_100_cycles.hex", flat_pixels);
        $readmemh("mapped_weights.hex", flat_weights);
        
        if(fd_shb==0) begin
            $display("ERROR opening shb_bus_output.txt");
            $finish;
        end

        rst = 0;
        src_sel = 0;
        load_bn_parameters();
        
        // Weights stay fixed for all 100 cycles
        map_weights_once();

        // Reset Sequence
        repeat(5) @(negedge clk);
        rst = 1;
        @(negedge clk);

        // Run 100 Cycles
        $fwrite(fd_shb, "--- RTL MODEL OUTPUT (100 Cycles) ---\n\n");
        begin
            int offset = 0;
            for(int cycle = 0; cycle < 100; cycle++) begin
                
                // Load the exact 3456 pixels for THIS clock cycle
                load_pixels_for_cycle(offset);
                offset = offset + 3456;
                
                // Wait for the combinational logic to propagate
                @(negedge clk);
                
                // Log the output
                $fwrite(fd_shb, "--- Cycle %03d ---\n", cycle);
                for(int s = 0; s < N_SHAABAN; s++) begin
                    logic signed [DATA_WIDTH-1:0] val3, val2, val1, val0;
                    val0 = dut.u_shaaban_adder_tree.u_connect.shb_conv_bus[s][0*DATA_WIDTH +: DATA_WIDTH];
                    val1 = dut.u_shaaban_adder_tree.u_connect.shb_conv_bus[s][1*DATA_WIDTH +: DATA_WIDTH];
                    val2 = dut.u_shaaban_adder_tree.u_connect.shb_conv_bus[s][2*DATA_WIDTH +: DATA_WIDTH];
                    val3 = dut.u_shaaban_adder_tree.u_connect.shb_conv_bus[s][3*DATA_WIDTH +: DATA_WIDTH];
                    
                    $fwrite(fd_shb, "Shaaban[%02d] | In3:%0d In2:%0d In1:%0d In0:%0d\n", s, val3, val2, val1, val0);
                end
                $fwrite(fd_shb, "\n");
            end
        end

        repeat(5) @(negedge clk);
        $fclose(fd_shb);
        $finish;
    end
endmodule