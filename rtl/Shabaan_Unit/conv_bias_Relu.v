module conv_bias_Relu #(parameter DATA_WIDTH = 18 , /*parameter signed conv_bias = 18'd1 ,*/ 
parameter signed zero = 18'd0)(

input wire signed  [DATA_WIDTH-1:0] conv_in ,
input wire signed  [DATA_WIDTH-1:0] conv_bias ,
output wire signed  [DATA_WIDTH-1:0] conv_out
);
 
wire signed [DATA_WIDTH:0] conv_out_bias ; // 19 bits  

// adding Constant Bias:
assign conv_out_bias = conv_in + conv_bias;

// applying RElu activation function : o/p = max(conv_out_bias,0) 
//always @(*)
// begin
// // if( ( conv_out_bias[DATA_WIDTH] == 1'b0 ) && ( conv_out_bias[DATA_WIDTH-1:0] != 18'd0 )  )
//   if ($signed(conv_out_bias) > 0)
  assign conv_out = conv_out_bias[DATA_WIDTH-1:0];
  //else
 //  conv_out = zero ;
 //end
endmodule
