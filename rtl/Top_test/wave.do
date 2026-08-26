onerror {resume}
radix define fixed#9#decimal#signed -fixed -fraction 9 -signed -base signed -precision 6
radix define fixed#18#decimal#signed -fixed -fraction 18 -signed -base signed -precision 6
quietly WaveActivateNextPane {} 0
add wave -noupdate -divider -height 20 <NULL>
add wave -noupdate /stage1_only_tb/DUT/u_mapping_controller/clk
add wave -noupdate /stage1_only_tb/DUT/u_mapping_controller/rst_n
add wave -noupdate /stage1_only_tb/DUT/u_mapping_controller/start_i
add wave -noupdate /stage1_only_tb/DUT/u_mapping_controller/next_i
add wave -noupdate /stage1_only_tb/DUT/u_mapping_controller/fetch_en_i
add wave -noupdate -divider <NULL>
add wave -noupdate -height 20 -group {Memory Interface} /stage1_only_tb/DUT/u_mapping_controller/mem_data_i
add wave -noupdate -height 20 -group {Memory Interface} /stage1_only_tb/DUT/u_mapping_controller/mem_addr_o
add wave -noupdate -height 20 -group {Memory Interface} /stage1_only_tb/DUT/u_mapping_controller/mem_rd_o
add wave -noupdate -divider <NULL>
add wave -noupdate -height 20 -group {Conv Output} -color Orange /stage1_only_tb/DUT/u_mapping_controller/conv_pixels_o
add wave -noupdate -height 20 -group {Conv Output} /stage1_only_tb/DUT/u_mapping_controller/valid_mask_o
add wave -noupdate -height 20 -group {Conv Output} -color Cyan /stage1_only_tb/DUT/u_mapping_controller/conv_valid_o
add wave -noupdate -height 20 -group {Conv Output} -color Cyan /stage1_only_tb/DUT/u_mapping_controller/conv_done_o
add wave -noupdate -divider <NULL>
add wave -noupdate -height 20 -group {Status Outputs} -color Magenta /stage1_only_tb/DUT/u_mapping_controller/done_o
add wave -noupdate -height 20 -group {Status Outputs} -color Magenta /stage1_only_tb/DUT/u_mapping_controller/frame_done_o
add wave -noupdate -height 20 -group {Status Outputs} -color Magenta /stage1_only_tb/DUT/u_mapping_controller/done_load_o
add wave -noupdate -height 20 -group {Status Outputs} /stage1_only_tb/DUT/u_mapping_controller/state_o
add wave -noupdate -divider <NULL>
add wave -noupdate -expand -group FSM_States /stage1_only_tb/DUT/u_mapping_controller/state
add wave -noupdate -expand -group FSM_States /stage1_only_tb/DUT/u_mapping_controller/next_state
add wave -noupdate -expand -group FSM_States /stage1_only_tb/DUT/u_mapping_controller/buff
add wave -noupdate -divider <NULL>
add wave -noupdate -group {Window & Sweep} /stage1_only_tb/DUT/u_mapping_controller/win_idx
add wave -noupdate -group {Window & Sweep} /stage1_only_tb/DUT/u_mapping_controller/sweep_idx
add wave -noupdate -group {Window & Sweep} /stage1_only_tb/DUT/u_mapping_controller/word_col_offset
add wave -noupdate -group {Window & Sweep} /stage1_only_tb/DUT/u_mapping_controller/row_origin
add wave -noupdate -divider <NULL>
add wave -noupdate -group {Load Control} /stage1_only_tb/DUT/u_mapping_controller/load_cnt
add wave -noupdate -group {Load Control} /stage1_only_tb/DUT/u_mapping_controller/load_cnt_d
add wave -noupdate -group {Load Control} -color Orange /stage1_only_tb/DUT/u_mapping_controller/load_max_comb
add wave -noupdate -group {Load Control} /stage1_only_tb/DUT/u_mapping_controller/full_load
add wave -noupdate -group {Load Control} -color Cyan /stage1_only_tb/DUT/u_mapping_controller/load_data_valid
add wave -noupdate -group {Load Control} -divider <NULL>
add wave -noupdate -group {Load Control} /stage1_only_tb/DUT/u_mapping_controller/write_bank
add wave -noupdate -group {Load Control} /stage1_only_tb/DUT/u_mapping_controller/fetch_order
add wave -noupdate -divider <NULL>
add wave -noupdate -group {Conv Position} /stage1_only_tb/DUT/u_mapping_controller/conv_row
add wave -noupdate -group {Conv Position} /stage1_only_tb/DUT/u_mapping_controller/conv_col
add wave -noupdate -group {Conv Position} /stage1_only_tb/DUT/u_mapping_controller/conv_slides_row
add wave -noupdate -group {Conv Position} /stage1_only_tb/DUT/u_mapping_controller/conv_slides_col
add wave -noupdate -divider <NULL>
add wave -noupdate -group {Mode & Padding} /stage1_only_tb/DUT/u_mapping_controller/mode_r
add wave -noupdate -group {Mode & Padding} /stage1_only_tb/DUT/u_mapping_controller/pad_top
add wave -noupdate -group {Mode & Padding} /stage1_only_tb/DUT/u_mapping_controller/pad_bot
add wave -noupdate -group {Mode & Padding} /stage1_only_tb/DUT/u_mapping_controller/pad_left
add wave -noupdate -group {Mode & Padding} /stage1_only_tb/DUT/u_mapping_controller/pad_right
add wave -noupdate -group {Mode & Padding} -divider <NULL>
add wave -noupdate -group {Mode & Padding} /stage1_only_tb/DUT/u_mapping_controller/active_rows
add wave -noupdate -group {Mode & Padding} /stage1_only_tb/DUT/u_mapping_controller/active_cols
add wave -noupdate -divider <NULL>
add wave -noupdate -group {Buffer Addressing} /stage1_only_tb/DUT/u_mapping_controller/real_buf_row_start
add wave -noupdate -group {Buffer Addressing} /stage1_only_tb/DUT/u_mapping_controller/real_buf_col_start
add wave -noupdate -divider <NULL>
add wave -noupdate -group {Row & Word Counters} /stage1_only_tb/DUT/u_mapping_controller/row_cnt
add wave -noupdate -group {Row & Word Counters} /stage1_only_tb/DUT/u_mapping_controller/row_cnt_d
add wave -noupdate -group {Row & Word Counters} /stage1_only_tb/DUT/u_mapping_controller/word_cnt
add wave -noupdate -group {Row & Word Counters} /stage1_only_tb/DUT/u_mapping_controller/word_cnt_d
add wave -noupdate -group {Row & Word Counters} -divider <NULL>
add wave -noupdate -group {Row & Word Counters} /stage1_only_tb/DUT/u_mapping_controller/physical_row_c
add wave -noupdate -group {Row & Word Counters} /stage1_only_tb/DUT/u_mapping_controller/tgt_bank_c
add wave -noupdate -divider <NULL>
add wave -noupdate -group {Column Index Decode} /stage1_only_tb/DUT/u_mapping_controller/col_base_c
add wave -noupdate -group {Column Index Decode} /stage1_only_tb/DUT/u_mapping_controller/col_idx0_c
add wave -noupdate -group {Column Index Decode} /stage1_only_tb/DUT/u_mapping_controller/col_idx1_c
add wave -noupdate -group {Column Index Decode} /stage1_only_tb/DUT/u_mapping_controller/col_idx2_c
add wave -noupdate -group {Column Index Decode} /stage1_only_tb/DUT/u_mapping_controller/col_idx3_c
add wave -noupdate -divider <NULL>
add wave -noupdate -group {Current Position} /stage1_only_tb/DUT/u_mapping_controller/cur_logical_row
add wave -noupdate -group {Current Position} /stage1_only_tb/DUT/u_mapping_controller/cur_physical_row
add wave -noupdate -group {Current Position} /stage1_only_tb/DUT/u_mapping_controller/cur_word_in_row
add wave -noupdate -group {Current Position} /stage1_only_tb/DUT/u_mapping_controller/cur_row_word_offset
add wave -noupdate -divider <NULL>
add wave -noupdate -group {Gather Lane} -color Orange /stage1_only_tb/DUT/u_mapping_controller/g_out_row_lane
add wave -noupdate -group {Gather Lane} -color Orange /stage1_only_tb/DUT/u_mapping_controller/g_out_col_lane
add wave -noupdate -group {Gather Lane} -color Cyan /stage1_only_tb/DUT/u_mapping_controller/g_lane_valid
add wave -noupdate -divider <NULL>
add wave -noupdate -group {Row Mapping} /stage1_only_tb/DUT/u_mapping_controller/row_out
add wave -noupdate -group {Row Mapping} /stage1_only_tb/DUT/u_mapping_controller/row_in_pad
add wave -noupdate -group {Row Mapping} /stage1_only_tb/DUT/u_mapping_controller/row_phys
add wave -noupdate -divider <NULL>
add wave -noupdate -group {Column Mapping} /stage1_only_tb/DUT/u_mapping_controller/col_out
add wave -noupdate -group {Column Mapping} /stage1_only_tb/DUT/u_mapping_controller/col_in_pad
add wave -noupdate -group {Column Mapping} /stage1_only_tb/DUT/u_mapping_controller/col_buf_idx
add wave -noupdate -group {Column Mapping} /stage1_only_tb/DUT/u_mapping_controller/col_bank_sel
add wave -noupdate -group {Column Mapping} /stage1_only_tb/DUT/u_mapping_controller/col_in_bank
add wave -noupdate -divider <NULL>
add wave -noupdate -group {Done Registers} -color Magenta /stage1_only_tb/DUT/u_mapping_controller/done_r
add wave -noupdate -group {Done Registers} -color Magenta /stage1_only_tb/DUT/u_mapping_controller/frame_done_r
add wave -noupdate -divider <NULL>
add wave -noupdate -divider -height 25 DUT
add wave -noupdate -color Cyan -radix binary /stage1_only_tb/DUT/spike_out
add wave -noupdate -color Cyan /stage1_only_tb/DUT/shb_mem_en
add wave -noupdate /stage1_only_tb/DUT/u_top_controller/stage
add wave -noupdate -divider <NULL>
add wave -noupdate -group {Sub-Module Buses} /stage1_only_tb/DUT/u_conv9_array/mac_to_connect
add wave -noupdate -group {Sub-Module Buses} /stage1_only_tb/DUT/u_connect/shb_conv_bus
add wave -noupdate /stage1_only_tb/DUT/spike_mem_data
add wave -noupdate /stage1_only_tb/DUT/pixels_mapped
add wave -noupdate /stage1_only_tb/DUT/shb_bus
add wave -noupdate {/stage1_only_tb/DUT/u_shaaban_array/gen_shaaban_array[0]/u_shb/batch_norm_out}
add wave -noupdate {/stage1_only_tb/DUT/u_shaaban_array/gen_shaaban_array[0]/u_shb/final_pool_out}

add wave -position insertpoint  \
sim:/stage1_only_tb/DUT/stage2_last_frame_idx_o
add wave -position insertpoint  \
sim:/stage1_only_tb/DUT/special_row_col_ind

add wave -position insertpoint  \
{sim:/stage1_only_tb/DUT/u_pixel_source_mapper/gen_frame_mapping[0]/u_frame_map/conv_test}

add wave -position insertpoint  \
sim:/stage1_only_tb/DUT/u_spike_mem/bit_enable

add wave -position insertpoint  \
sim:/stage1_only_tb/DUT/u_pixel_source_mapper/u_mem_mapping/fil_in

add wave -position insertpoint  \
sim:/stage1_only_tb/DUT/u_pixel_source_mapper/pixels_s3

add wave -position insertpoint  \
sim:/stage1_only_tb/DUT/u_top_controller/conv3_filter

add wave -position insertpoint  \
sim:/stage1_only_tb/DUT/u_top_controller/frame

TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {4853416 ps} 0}
quietly wave cursor active 1
configure wave -namecolwidth 185
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
WaveRestoreZoom {4931492 ps} {5309260 ps}
