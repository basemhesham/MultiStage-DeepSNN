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
module shaaban_adder_tree_top_test;

    // Parameters
    localparam DATA_WIDTH     = 18;
    localparam N_SHAABAN      = 32;
    localparam INPUTS_PER_SHB = 4;
    localparam N_TREES        = 12;

    
    // Clock / Reset
    logic clk;
    logic rst;

    
    // DUT Inputs
    logic [1:0] src_sel;

    logic signed [DATA_WIDTH-1:0] mac_in
        [0:N_TREES-1][0:31];

    logic signed [DATA_WIDTH-1:0] conv_bias_param
        [0:N_SHAABAN-1];

    logic signed [DATA_WIDTH-1:0] mult_weight_param
        [0:N_SHAABAN-1];

    logic signed [DATA_WIDTH-1:0] add_weight_param
        [0:N_SHAABAN-1];

    
    // DUT Outputs
    logic [31:0] spike_out;

    logic [0:31] shaaban_spike_bus
        [0:N_SHAABAN-1];

    
    // DUT
    shabaan_adder_tree_top #(
        .DATA_WIDTH(DATA_WIDTH),
        .N_SHAABAN(N_SHAABAN),
        .INPUTS_PER_SHB(INPUTS_PER_SHB),
        .N_TREES(N_TREES)
    ) dut (

        .clk(clk),
        .rst(rst),

        .src_sel(src_sel),

        .mac_in(mac_in),

        .conv_bias_param(conv_bias_param),
        .mult_weight_param(mult_weight_param),
        .add_weight_param(add_weight_param),

        .spike_out(spike_out),
        .shaaban_spike_bus(shaaban_spike_bus)

    );

    
    // Clock Generation
    initial clk = 0;

    always #5 clk = ~clk;

    
    // Stimulus
    integer i,j;

    initial begin

        
        // Initialize everything
        
        rst     = 1'b0;
        src_sel = 2'd0;

        foreach(mac_in[i,j])
            mac_in[i][j] = '0;

        foreach(conv_bias_param[i])
            conv_bias_param[i] = '0;

        foreach(mult_weight_param[i])
            mult_weight_param[i] = BN1_WEIGHTS[i];

        foreach(add_weight_param[i])
            add_weight_param[i] = BN1_BIAS[i];



        
        // Hold reset
        repeat(5) @(negedge clk);

        rst = 1'b1;

        
        // Test Stage 0
        @(negedge clk);

        src_sel = 2'd0;

        foreach(mac_in[i,j])
            mac_in[i][j] = i*32 + j;

        repeat(10) @(negedge clk);

        $display("--------------------------------");
        $display("Stage 0");
        $display("Spike Out = %h", spike_out);

        // Test Stage 1
        @(negedge clk);

        src_sel = 2'd1;

        foreach(mac_in[i,j])
            mac_in[i][j] = (i*32+j)+100;

        repeat(10) @(negedge clk);

        $display("--------------------------------");
        $display("Stage 1");
        $display("Spike Out = %h", spike_out);

        
        // Test Stage 2
        @(negedge clk);

        src_sel = 2'd2;

        foreach(mac_in[i,j])
            mac_in[i][j] = (i*32+j)+200;

        repeat(10) @(negedge clk);

        $display("--------------------------------");
        $display("Stage 2");
        $display("Spike Out = %h", spike_out);

        
        // Test Stage 3
        @(negedge clk);

        src_sel = 2'd3;

        foreach(mac_in[i,j])
            mac_in[i][j] = (i*32+j)+300;

        repeat(10) @(negedge clk);

        $display("--------------------------------");
        $display("Stage 3");
        $display("Spike Out = %h", spike_out);

        
        // Random Testing
        repeat(20) begin

            @(negedge clk);

            src_sel = $urandom_range(0,3);

            foreach(mac_in[i,j])
                mac_in[i][j] = $random;

        end

        repeat(10) @(negedge clk);

        $finish;

    end

    
    // Monitor
    initial begin
        $monitor("[%0t] src_sel=%0d spike_out=%h",
                 $time, src_sel, spike_out);
    end

endmodule

