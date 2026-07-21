# 1. Delete the existing 'work' library to ensure a clean build
if {[file exists work]} {
    vdel -lib work -all
}

# 2. Make the new 'work' library
vlib work

# 3. Map the logical library name 'work' to the physical directory
vmap work work

# 4. Compile all Verilog/SystemVerilog files listed in your files.f
vlog -f files.f  +define+SIM


vsim -voptargs=+acc work.stage1_only_tb

 do wave.do

 run -all