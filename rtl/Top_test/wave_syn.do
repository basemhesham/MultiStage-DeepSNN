onerror {resume}
radix define fixed#9#decimal#signed -fixed -fraction 9 -signed -base signed -precision 6
radix define fixed#18#decimal#signed -fixed -fraction 18 -signed -base signed -precision 6
quietly WaveActivateNextPane {} 0
add wave -noupdate -group Top /stage1_only_tb/PIXEL_W
add wave -noupdate -group Top /stage1_only_tb/MAP_WORD_W
add wave -noupdate -group Top /stage1_only_tb/PIXELS_PER_WORD
add wave -noupdate -group Top /stage1_only_tb/IMG_ROWS_FULL
add wave -noupdate -group Top /stage1_only_tb/IMG_COLS_FULL
add wave -noupdate -group Top /stage1_only_tb/WORDS_PER_ROW
add wave -noupdate -group Top /stage1_only_tb/MEM_DEPTH
add wave -noupdate -group Top /stage1_only_tb/MEM_ADDR_BITS
add wave -noupdate -group Top /stage1_only_tb/CLK_PERIOD
add wave -noupdate -group Top /stage1_only_tb/WORD_W
add wave -noupdate -group Top /stage1_only_tb/IMG_ROWS
add wave -noupdate -group Top /stage1_only_tb/IMG_COLS
add wave -noupdate -group Top /stage1_only_tb/BUF_SIZE
add wave -noupdate -group Top /stage1_only_tb/BANK_COLS
add wave -noupdate -group Top /stage1_only_tb/CONV_K
add wave -noupdate -group Top /stage1_only_tb/WIN_GROUP
add wave -noupdate -group Top /stage1_only_tb/NUM_H_WIN
add wave -noupdate -group Top /stage1_only_tb/NUM_SWEEPS
add wave -noupdate -group Top /stage1_only_tb/OUTMEM_WORDS
add wave -noupdate -group Top /stage1_only_tb/WINDOW_BITS
add wave -noupdate -group Top /stage1_only_tb/SLIDES_FULL
add wave -noupdate -group Top /stage1_only_tb/SLIDES_BORDER
add wave -noupdate -group Top /stage1_only_tb/PAD
add wave -noupdate -group Top /stage1_only_tb/frame_errs
add wave -noupdate -group Top /stage1_only_tb/clk
add wave -noupdate -group Top /stage1_only_tb/rst
add wave -noupdate -group Top /stage1_only_tb/arst_n
add wave -noupdate -group Top /stage1_only_tb/enable
add wave -noupdate -group Top /stage1_only_tb/pixel_mem_wr_en
add wave -noupdate -group Top /stage1_only_tb/pixel_mem_wr_addr
add wave -noupdate -group Top /stage1_only_tb/pixel_mem_wr_data
add wave -noupdate -group Top /stage1_only_tb/start_i
add wave -noupdate -group Top /stage1_only_tb/mem_data_i
add wave -noupdate -group Top /stage1_only_tb/spike_out
add wave -noupdate -group Top /stage1_only_tb/DUT/u_top_controller/stage
add wave -noupdate -group Top /stage1_only_tb/class_logits
add wave -noupdate -group Top /stage1_only_tb/classifier_done
add wave -noupdate -group Top /stage1_only_tb/classifier_busy
add wave -noupdate -group Top /stage1_only_tb/snn_done
add wave -noupdate -group Top /stage1_only_tb/done
add wave -noupdate -group Top /stage1_only_tb/mem_addr_o
add wave -noupdate -group Top /stage1_only_tb/mem_rd_o
add wave -noupdate -group Top /stage1_only_tb/map_done_o
add wave -noupdate -group Top /stage1_only_tb/f_mapping
add wave -noupdate -group Top /stage1_only_tb/f_pixel_mapper
add wave -noupdate -group Top /stage1_only_tb/f_conv9
add wave -noupdate -group Top /stage1_only_tb/f_adder_tree
add wave -noupdate -group Top /stage1_only_tb/f_shaaban
add wave -noupdate -group Top /stage1_only_tb/f_spike_writeback
add wave -noupdate -group Top /stage1_only_tb/f_controller
add wave -noupdate -group Top /stage1_only_tb/image_mem
add wave -noupdate -group Top /stage1_only_tb/full_image
add wave -noupdate -group Top /stage1_only_tb/word_mem
add wave -noupdate -group Top /stage1_only_tb/mem_data_r
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/clk
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/rst_n
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/start_i
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/next_i
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/fetch_en_i
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/mem_data_i
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/mem_addr_o
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/mem_rd_o
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/conv_pixels_o
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/valid_mask_o
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/conv_valid_o
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/conv_done_o
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/new_data_o
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/frame_counter_o
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/done_o
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/frame_done_o
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/done_load_o
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/state_o
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/frame_start_o
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/frame_start_stg2_3_o
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/win_idx
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/sweep_idx
add wave -noupdate -group Mapping_controller /stage1_only_tb/DUT/u_mapping_controller/active_cols
TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {3535100 ps} 0}
quietly wave cursor active 1
configure wave -namecolwidth 150
configure wave -valuecolwidth 100
configure wave -justifyvalue left
configure wave -signalnamewidth 1
configure wave -snapdistance 10
configure wave -datasetprefix 0
configure wave -rowmargin 4
configure wave -childrowmargin 2
configure wave -gridoffset 0
configure wave -gridperiod 1
configure wave -griddelta 40
configure wave -timeline 0
configure wave -timelineunits ps
update
WaveRestoreZoom {3449775 ps} {3620425 ps}
