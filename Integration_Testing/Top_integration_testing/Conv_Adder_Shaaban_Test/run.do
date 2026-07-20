#=========================================================
# ModelSim / QuestaSim DO File
# Compiles the project using behavioral DSP model
#=========================================================

transcript on

#---------------------------------------------------------
# Create work library
#---------------------------------------------------------
vlib work
vmap work work

#---------------------------------------------------------
# Compile Design Files
#---------------------------------------------------------

#==========================================================
# Compile RTL
#==========================================================

vlog +define+SIM convDspAddMult.sv
vlog +define+SIM conv9.sv
vlog +define+SIM top_conv9_array.sv

vlog +define+SIM adder_layer1.v
vlog +define+SIM adder_layer2.v
vlog +define+SIM adder_layer3.v
vlog +define+SIM adder_layer4.v
vlog +define+SIM adder_tree_10_4_1_1.v

vlog +define+SIM Batch_Norm.v
vlog +define+SIM conv_bias_Relu.v
vlog +define+SIM Max_pooling.v
vlog +define+SIM LIF.sv
vlog +define+SIM shaban_unit_top.v



vlog +define+SIM adder_tree_shaaban_connect.sv
vlog +define+SIM top_shaaban_array.sv

vlog +define+SIM shaaban_adder_tree_top.sv

vlog +define+SIM conv_adder_shaaban_top.sv

vlog +define+SIM conv_adder_shaaban_top_test.sv

#==========================================================
# Simulate
#==========================================================

vsim -voptargs=+acc work.conv_adder_shaaban_top_test

#==========================================================
# Add Signals
#==========================================================

do wave.do

#==========================================================
# Run
#==========================================================

run -all