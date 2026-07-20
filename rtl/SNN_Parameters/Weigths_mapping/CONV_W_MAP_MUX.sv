module CONV_W_MAP_MUX (
  input  logic [1:0]  stage,
  input  logic [5:0]  filter2,
  input  logic [6:0]  filter3,
  output logic [17:0] conv9_in [3456]
);

  logic [17:0] conv1_out [3456];
  logic [17:0] conv2_out [3456];
  logic [17:0] conv3_out [3456];

  CONV1_W_MAP_OPT u_conv1 (
    .conv9_in (conv1_out)
  );

  CONV2_W_MAP_OPT u_conv2 (
    .filter   (filter2),
    .conv9_in (conv2_out)
  );

  CONV3_W_MAP_OPT u_conv3 (
    .filter   (filter3),
    .conv9_in (conv3_out)
  );



  //Start counting stages from zero !!!!!!!!!!
  always_comb begin
    for (int i = 0; i < 3456; i++) begin
      case (stage)
        2'b00:   conv9_in[i] = conv1_out[i];
        2'b01:   conv9_in[i] = conv2_out[i];
        2'b10:   conv9_in[i] = conv3_out[i];
        default: conv9_in[i] = 18'b0;
      endcase
    end
  end

endmodule
