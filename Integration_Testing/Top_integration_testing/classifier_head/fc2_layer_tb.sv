`timescale 1ns/1ns 

module fc2_layer_tb ();
parameter DATA_WIDTH = 18 , NUM_OF_INPUTS = 256 , NUM_OF_OUTPUTS = 4 , CLK_PERIOD = 10;

logic                           clk;
logic                           rst;
logic signed [DATA_WIDTH-1:0]   fc_in  [0:NUM_OF_INPUTS-1];
logic                           start;

logic signed [DATA_WIDTH-1:0]   fc_out [0:NUM_OF_OUTPUTS-1];
logic                           done;
logic                           busy;

always #(CLK_PERIOD/2) clk = ~clk;

logic signed [DATA_WIDTH-1:0] arr_in [0:NUM_OF_INPUTS-1];
logic signed [DATA_WIDTH-1:0] expected_arr_out [0:NUM_OF_OUTPUTS-1]; 

int success_counter = 0;
int failed_counter = 0;

initial
 begin
 $display("============================================================");
 $display("  FC2 LAYER TESTBENCH");
 $display("============================================================");
 clk= 1'b0;
 rst = 1'b1; // reset assertion 
 start = 1'b0 ;
 for(int i =0; i<NUM_OF_INPUTS ; i++)
  begin
  fc_in[i] = 18'd0;
  end
   $readmemb("fc1.txt",arr_in);
   $display("  Loaded fc1.txt : %0d values", NUM_OF_INPUTS);
   $readmemb("fc2.txt",expected_arr_out);
   $display("  Loaded fc2.txt : %0d values", NUM_OF_OUTPUTS);
 #CLK_PERIOD;
 rst = 1'b0; //reset de-assertion
 #CLK_PERIOD;
 for(int i =0; i<NUM_OF_INPUTS ; i++)
  begin
  fc_in[i] = arr_in[i];
  end 
 $display("  Starting computation...");
 start = 1'b1 ;
 #CLK_PERIOD;
 start = 1'b0 ;
 end
 
 always @(posedge done)
  begin
  $display("  Computation done.  Checking outputs...");
  for(int k=0 ; k<NUM_OF_OUTPUTS ; k++)
       begin
        fixed_point_to_float(expected_arr_out[k],fc_out[k]);
        $display("  Output [%0d]: expected= %0b.%0b  actual= %0b.%0b", k, expected_arr_out[k][17:9],expected_arr_out[k][8:0], fc_out[k][17:9],fc_out[k][8:0]);
        if( expected_arr_out[k] == fc_out[k] )
         begin
         success_counter++;
         $display("    -> PASS");
         end
        else
         begin
         failed_counter++;  
         $display("    -> FAIL");
         end
        end
        
     $display("============================================================");
     if (failed_counter == 0)
       $display("  RESULT: ALL %0d OUTPUTS MATCH  -  TEST PASSED", success_counter);
     else begin
       $display("  RESULT: %0d passed, %0d FAILED  -  TEST FAILED", success_counter, failed_counter);
     end
     $display("============================================================");
     $finish;
  end
  
  task fixed_point_to_float ( input logic signed [DATA_WIDTH-1:0] Expected_out,input logic signed [DATA_WIDTH-1:0] Actual_out );
     
     real Expected_result, Actual_result;
     
     Expected_result = (Expected_out[0]*0.001953125) + (Expected_out[1]*0.00390625) + (Expected_out[2]*0.0078125) + (Expected_out[3]*0.015625) + (Expected_out[4]*0.03125) + (Expected_out[5]*0.0625) + (Expected_out[6]*0.125) + (Expected_out[7]*0.25) + (Expected_out[8]*0.5) + (Expected_out[9]*1) + (Expected_out[10]*2) + (Expected_out[11]*4) + (Expected_out[12]*8) + (Expected_out[13]*16) + (Expected_out[14]*32) + (Expected_out[15]*64) + (Expected_out[16]*128) - (Expected_out[17]*256) ;
     Actual_result   = (Actual_out[0]*0.001953125)   + (Actual_out[1]*0.00390625)   + (Actual_out[2]*0.0078125)   + (Actual_out[3]*0.015625)   + (Actual_out[4]*0.03125)   + (Actual_out[5]*0.0625)   + (Actual_out[6]*0.125)   + (Actual_out[7]*0.25)   + (Actual_out[8]*0.5)   + (Actual_out[9]*1)   + (Actual_out[10]*2)   + (Actual_out[11]*4)   + (Actual_out[12]*8)   + (Actual_out[13]*16)   + (Actual_out[14]*32)   + (Actual_out[15]*64)   + (Actual_out[16]*128)   - (Actual_out[17]*256) ;
     $display ("    expected= %0f  actual= %0f", Expected_result, Actual_result); 
     endtask
 
 
fc2_layer fc2_layer_inst (
 .clk(clk),
 .rst(rst),
 .fc_in(fc_in),
 .start(start),
 .fc_out(fc_out),
 .done(done),
 .busy(busy)
   );
 
 endmodule