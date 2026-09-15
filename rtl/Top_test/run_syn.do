# 0. Start transcript logging FIRST
transcript file simulation.log 

# 1. Delete the existing 'work' library to ensure a clean build
if {[file exists work]} {
    vdel -lib work -all
}

# 2. Make the new 'work' library
vlib work
vmap work work

# 3. Compile Xilinx Verilog primitives directly into work (avoids
#    VHDL/Verilog library-precedence issues entirely)
vlog -work work +incdir+C:/Xilinx/Vivado/2018.2/data/verilog/src C:/Xilinx/Vivado/2018.2/data/verilog/src/unisims/*.v
vlog -work work C:/Xilinx/Vivado/2018.2/data/verilog/src/glbl.v

# 4. Compile design + testbench
vlog -work work CNN_ourboard.v
vlog -work work stage1_only_tb.sv

# 5. Elaborate + load -- NOTE: no -L unisim here
vsim -voptargs=+acc work.stage1_only_tb work.glbl

do wave_syn.do

run -all