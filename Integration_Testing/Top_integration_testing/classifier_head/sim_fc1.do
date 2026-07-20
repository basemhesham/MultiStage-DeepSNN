# ============================================================================
# QuestaSim / ModelSim DO file for FC1 testbench
# Usage: vsim -do sim_fc1.do
# ============================================================================

# Change to the directory containing this DO file and all source/data files
cd [file dirname [info script]]

# Suppress common warnings
quietly set NumericStdNoWarnings 1

# Create work library
if {[file exists work]} { vdel -lib work -all }
vlib work
vmap work work

# Compile design sources (SystemVerilog)
vlog -sv -work work +incdir+. \
    fc1_layer.sv \
    fc2_layer.sv

# Compile testbench
vlog -sv -work work +incdir+. \
    fc1_layer_tb.sv

# Load design
vsim -novopt work.fc1_layer_tb

# Add waves to see progress
add wave -divider "Control"
add wave clk rst start done busy
add wave -divider "State"
add wave fc1_layer_inst/state
add wave fc1_layer_inst/batch_idx
add wave fc1_layer_inst/input_idx
add wave -divider "Output"
add wave fc_out

# Run the simulation
run -all

# Show final result
echo "============================================"
echo "Simulation finished."
echo "Check Tcl Console above for PASS/FAIL result."
echo "============================================"
