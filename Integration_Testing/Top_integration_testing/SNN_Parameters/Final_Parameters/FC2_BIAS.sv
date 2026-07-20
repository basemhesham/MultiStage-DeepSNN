localparam int NUM_OF_BITS             = 18;
localparam int NUM_OF_FILTERS          = 4;

localparam logic signed [NUM_OF_BITS-1:0] FC2_BIAS [NUM_OF_FILTERS] = '{ 
    18'b000000000000010001,
    18'b111111111111011101,
    18'b111111111101101001,
    18'b000000000010011010
};