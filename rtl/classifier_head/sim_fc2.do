# ============================================================================
# QuestaSim / ModelSim DO file for FC2 testbench
# Usage: vsim -do sim_fc2.do
# ============================================================================

cd [file dirname [info script]]

quietly set NumericStdNoWarnings 1

if {[file exists work]} { vdel -lib work -all }
vlib work
vmap work work

vlog -sv -work work +incdir+. \
    fc1_layer.sv \
    fc2_layer.sv

vlog -sv -work work +incdir+. \
    fc2_layer_tb.sv

vsim -novopt work.fc2_layer_tb

add wave -divider "Control"
add wave clk rst start done busy
add wave -divider "State"
add wave fc2_layer_inst/state
add wave fc2_layer_inst/input_idx
add wave -divider "Output"
add wave fc_out

run -all

echo "============================================"
echo "Simulation finished."
echo "Check Tcl Console above for PASS/FAIL result."
echo "============================================"
