//===========================================================
// File        : Max_pooling.sv
// Purpose     : choose the greatest
// Used in     : ///
//===========================================================
// Written by  : 
// Editor      : <Ahmed Essam, if reviewed / modified by someone else>
// Last edit   : <2026-07-06>
//===========================================================

module Max_pooling #(parameter DATA_WIDTH = 18) (

input wire signed  [DATA_WIDTH-1:0] pool_in1 ,
input wire signed  [DATA_WIDTH-1:0] pool_in2 ,
output wire signed  [DATA_WIDTH-1:0] pool_out 
);

// always_comb
//  begin
//   if( pool_in1 >= pool_in2  )
//    pool_out = pool_in1 ;
//    else
//    pool_out = pool_in2 ;
//  end

assign pool_out = (pool_in1 >= pool_in2)? pool_in1 : pool_in2;
 
 endmodule