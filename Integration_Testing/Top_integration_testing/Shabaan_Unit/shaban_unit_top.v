module shaban_unit_top #(parameter DATA_WIDTH = 18 , conv_bias_relu_num = 4 
, batch_norm_num = 4 , pool_num =2 ) (
input wire clk,
input wire rst,
input wire signed [(conv_bias_relu_num*DATA_WIDTH)-1:0] conv_in ,
input wire signed [DATA_WIDTH-1:0] conv_bias ,
input wire signed [DATA_WIDTH-1:0] mult_wight ,
input wire signed [DATA_WIDTH-1:0] add_wight ,
output wire                    spike   // spike output
);
// internal signals :
wire signed [DATA_WIDTH-1:0] conv_bias_relu_out [0:conv_bias_relu_num-1] ;
wire signed [DATA_WIDTH-1:0] batch_norm_out [0:batch_norm_num-1] ;
wire signed[DATA_WIDTH-1:0] max_pool_out [0:pool_num-1] ;
wire signed [DATA_WIDTH-1:0] final_pool_out ;

genvar i;

generate 
    for (i = 0 ; i < conv_bias_relu_num ; i = i+1)
    begin
    conv_bias_Relu conv_bias_Relu_inst(
    .conv_in(conv_in[i*DATA_WIDTH +: DATA_WIDTH]),
    .conv_bias(conv_bias),
    .conv_out(conv_bias_relu_out[i]) );
    end
endgenerate

generate 
    for (i = 0 ; i < batch_norm_num ; i = i+1)
    begin
    Batch_Norm Batch_Norm_inst (
    .Batch_Norm_in(conv_bias_relu_out[i]),
    .mult_wight(mult_wight),
    .add_wight(add_wight),
    .Batch_Norm_out(batch_norm_out[i]) );
    end
endgenerate


 Max_pooling Max_pooling_inst0 (
    .pool_in1(batch_norm_out[0]),
    .pool_in2(batch_norm_out[1]),
    .pool_out(max_pool_out[0]) );
    
  Max_pooling Max_pooling_inst1 (
       .pool_in1(batch_norm_out[2]),
       .pool_in2(batch_norm_out[3]),
       .pool_out(max_pool_out[1]) );   
       
    Max_pooling Max_pooling_inst2 (
            .pool_in1(max_pool_out[0]),
            .pool_in2(max_pool_out[1]),
            .pool_out(final_pool_out) );       


LIF LIF_ints (
.clk(clk),
.arst_n(rst),
.in_pool(final_pool_out),
.spike(spike) );




endmodule





