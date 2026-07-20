module Max_pooling #(parameter DATA_WIDTH = 18) (

input wire signed  [DATA_WIDTH-1:0] pool_in1 ,
input wire signed  [DATA_WIDTH-1:0] pool_in2 ,
output reg signed  [DATA_WIDTH-1:0] pool_out 
);

always @(*)
 begin
  if( pool_in1 >= pool_in2  )
   pool_out = pool_in1 ;
   else
   pool_out = pool_in2 ;
 end
 
 endmodule