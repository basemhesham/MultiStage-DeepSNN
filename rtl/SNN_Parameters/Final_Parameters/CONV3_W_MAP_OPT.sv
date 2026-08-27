//===========================================================
// File        : CONV3_W_MAP_OPT.sv
// Purpose     : Assigns values to the 3x3 filter(128 filters)
// Used in     : top_weight_mapper.sv
//===========================================================
// Written by  : 
// Editor      : Boutros George Sabri
// Last edit   : 2026-7-7
//===========================================================


//================================
//Importing package that contains hardcoded filter values
//================================

import conv3_pkg::*;
 module CONV3_W_MAP_OPT (
  input  logic [6:0]  filter, //filter selector
  output logic signed [17:0] conv9_in [3456] //output 3x3 convolution filter
 );
 
//============================
//Always block that has a large case statement that defines the 128 filter values
//============================
generate
genvar i;
  for (i =0; i < 576; i++) begin      // 9*32*2
	logic [16:0] ARRAY_INDX;
	always_comb begin
	ARRAY_INDX= i+576*filter;
    conv9_in[i]                   =UNIQUE_CONV3_WEIGHTS[ARRAY_INDX];
    conv9_in[i+ 1*576]            =UNIQUE_CONV3_WEIGHTS[ARRAY_INDX];
    conv9_in[i+ 2*576]            =UNIQUE_CONV3_WEIGHTS[ARRAY_INDX];
    conv9_in[i+ 3*576]            =UNIQUE_CONV3_WEIGHTS[ARRAY_INDX];
    
    conv9_in[i+ 4*576]            ='0;
    conv9_in[i+ 5*576]            ='0;
  end
end
endgenerate
endmodule