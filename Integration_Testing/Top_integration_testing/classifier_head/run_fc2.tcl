# ============================================================================
# Vivado 2018.3 Tcl script - Run FC2 testbench
# Usage: Open Vivado -> Tools -> Run Tcl Script -> select this file
# Or: vivado -source run_fc2.tcl
# ============================================================================

close_project -quiet

set script_dir [file dirname [info script]]
create_project fc2_test ./fc2_test -force

add_files -norecurse [list \
    $script_dir/fc1_layer.sv \
    $script_dir/fc2_layer.sv \
    $script_dir/UNIQUE_FC1_W.svh \
    $script_dir/UNIQUE_FC2_W.svh \
]
set_property used_in_synthesis false [get_files $script_dir/UNIQUE_FC1_W.svh]
set_property used_in_synthesis false [get_files $script_dir/UNIQUE_FC2_W.svh]

add_files -fileset sim_1 -norecurse [list \
    $script_dir/fc2_layer_tb.sv \
    $script_dir/fc1.txt \
    $script_dir/fc2.txt \
    $script_dir/fc1_map_bram_0.mem \
    $script_dir/fc1_map_bram_1.mem \
    $script_dir/fc1_map_bram_2.mem \
    $script_dir/fc1_map_bram_3.mem \
    $script_dir/fc1_map_bram_4.mem \
    $script_dir/fc1_map_bram_5.mem \
    $script_dir/fc1_map_bram_6.mem \
    $script_dir/fc1_map_bram_7.mem \
    $script_dir/fc2_map_bram_0.mem \
    $script_dir/fc2_map_bram_1.mem \
    $script_dir/fc2_map_bram_2.mem \
    $script_dir/fc2_map_bram_3.mem \
]

set_property top fc2_layer_tb [get_filesets sim_1]

set_property file_type SystemVerilog [get_files $script_dir/fc1_layer.sv]
set_property file_type SystemVerilog [get_files $script_dir/fc2_layer.sv]
set_property file_type SystemVerilog [get_files $script_dir/fc2_layer_tb.sv]

set_property -name {xsim.elaborate.xelab.more_options} -value "-sv_root $script_dir" -objects [get_filesets sim_1]

puts "\n============================================"
puts "  Launching FC2 simulation..."
puts "============================================\n"
launch_simulation
run all

puts "\n============================================"
puts "  Simulation finished."
puts "  Check Tcl Console above for PASS/FAIL result."
puts "============================================\n"
