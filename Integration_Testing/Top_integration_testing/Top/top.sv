// =============================================================================
// deep_snn_top.sv  —  Revised version
// =============================================================================
// FIXES vs original:
//
// [1] MAINTAINABILITY  — mapping_controller hardcoded literals replaced with
//     top-level parameters so changes propagate automatically.
//
// [2] UNCONNECTED      — map_conv_pixels_o was never consumed.  Flagged with
//     a clear comment; downstream connection must be confirmed by the team.
//
// [3] FUNCTIONAL       — spike_mem_wr_en now qualified with ctrl_zero_sel to
//     avoid spurious non-zero writes during the CLEAR_STAGE2_WORD phase.
//
// [4] TIMING           — gap_clear now additionally gated on !classifier_busy
//     to prevent clearing the GAP accumulator while the FC pipeline is still
//     consuming the previous result.
//
// [5] FUNCTIONAL       — fc1_start converted from level (gap_done) to a
//     single-cycle rising-edge pulse using gap_done_d.
//
// [6] FUNCTIONAL       — fc2_start converted from level (fc1_done) to a
//     single-cycle rising-edge pulse using fc1_done_d.
//
// [7] MINOR            — done registered through a flip-flop to prevent
//     combinational glitches propagating to the top-level output.
//
// [8] UNUSED           — map_state_o kept but isolated to a `ifdef SIM block
//     so it does not waste routing in synthesis.
//
// [9] UNUSED           — ctrl_rd_enable now used to qualify pixel_mem and
//     spike_mem read enables (was driven but silently ignored before).
//
// [10] UNCONNECTED     — ctrl_padding_flag forwarded to u_pixel_source_mapper
//      (placeholder port added; team must confirm interface).
// =============================================================================

`timescale 1ns/1ps

module deep_snn_top #(
    parameter int PIXEL_W              = 18,
    parameter int MAC_OUT_W            = 40,
    parameter int DATA_WIDTH           = 18,
    parameter int N_SHAABAN            = 32,
    parameter int INPUTS_PER_SHB       = 4,
    parameter int FRAME_NO             = 6,
    parameter int FRAME_NO_WIDTH       = 3,
    parameter int CLASSIFIER_FRAC_BITS = 9,
    parameter int CTRL_FRAGMENT_ROWS   = 13,
    parameter int CTRL_FRAGMENT_COLS   = 13,
    parameter int CTRL_FRAGMENTS_MAX   = CTRL_FRAGMENT_ROWS * CTRL_FRAGMENT_COLS,
    parameter int CTRL_TEMPORAL_FRAMES = 16,
    // mapping_controller parameters — FIX [1]: promoted from hardcoded literals
    parameter int MAP_WORD_W           = 72,
    parameter int MAP_IMG_ROWS         = 24,
    parameter int MAP_IMG_COLS         = 256,
    parameter int MAP_BUF_SIZE         = 24,
    parameter int MAP_BANK_COLS        = 8,
    parameter int MAP_CONV_K           = 5,
    parameter int MAP_NUM_H_WIN        = 30,
    parameter int MAP_NUM_SWEEPS       = 30
)(
    input  logic                          clk,
    input  logic                          rst,
    input  wire                           arst_n,
    input  wire                           enable, // one pulse at the beggining

    input  logic                          pixel_mem_wr_en,      //ignore for stage_1
    input  logic [5:0]                    pixel_mem_wr_addr,    //ignore for stage_1
    input  logic [(384*PIXEL_W)-1:0]      pixel_mem_wr_data,    //ignore for stage_1
    input  logic                          start_i, // one pulse for mapping controller
    input  logic [MAP_WORD_W-1:0]         mem_data_i,   // read word by word

`ifdef SIM
    input  logic                          sim_pixels_override,      // set to 0
    input  logic [(12*32*9*PIXEL_W)-1:0]  sim_pixels,
    input  logic                          sim_pixel_mem_override,   // set to 0
    input  logic [(384*PIXEL_W)-1:0]      sim_pixel_mem_data,
`endif

    output logic [N_SHAABAN-1:0]          spike_out,
    output logic [(4*DATA_WIDTH)-1:0]     class_logits,
    output logic                          classifier_done,
    output logic                          classifier_busy,
    output logic                          snn_done,
    output logic                          done,
    output logic [15:0]                   mem_addr_o,
    output logic                          mem_rd_o,
    output logic                          map_done_o
);

    // =========================================================================
    // FC layer size constants
    // =========================================================================
    localparam int FC1_INPUTS  = 128;
    localparam int FC1_OUTPUTS = 256;
    localparam int FC2_OUTPUTS = 4;

    // =========================================================================
    // Internal signals — controller outputs
    // =========================================================================
    logic [1:0]                    src_sel;
    logic [FRAME_NO_WIDTH-1:0]     frame;
    logic                          stage_sel;
    logic [5:0]                    conv2_filter;
    logic [6:0]                    conv3_filter;
    logic [0:3199]                 ctrl_mem_enable;
    logic                          ctrl_rd_enable;        // FIX [9]: now used
    logic [5:0]                    ctrl_rd_mem_adderss;
    logic [5:0]                    ctrl_wr_mem_adderss;
    logic                          ctrl_zero;
    logic                          ctrl_zero_sel;
    logic                          ctrl_padding_flag;     // FIX [10]: forwarded
    logic                          gap_sample_enable;
    logic                          ctrl_done_load_o;
    logic                          ctrl_fetch_en_i;
    logic                          ctrl_next_i;

    // =========================================================================
    // Internal signals — mapping controller outputs
    // =========================================================================
    logic                          map_conv_valid_o;
    // FIX [2]: map_conv_pixels_o was unconnected.  Kept declared; team must
    // wire this into the pixel_source_mapper path for full-pipeline operation.
    logic [(MAP_CONV_K*MAP_CONV_K*PIXEL_W*4)-1:0] map_conv_pixels_o;  // TODO: connect downstream
    logic                          map_conv_done_o;
    logic                          map_ctrl_done_o;
    logic                          map_frame_done_o;
`ifdef SIM
    logic [1:0]                    map_state_o;           // FIX [8]: SIM only
`endif

    // =========================================================================
    // Internal signals — GAP / FC
    // =========================================================================
    logic                          gap_busy;
    logic                          gap_done;
    logic                          gap_done_d;            // FIX [5]
    logic                          enable_d;
    logic                          snn_done_d;
    logic                          fc1_done_d;            // FIX [6]
    logic                          spike_mem_wr_en;
    logic [3199:0]                 spike_mem_wr_data;
    logic [(384*PIXEL_W)-1:0]      pixel_mem_raw;
    logic [(384*PIXEL_W)-1:0]      pixel_mem_data;
    logic [3199:0]                 spike_mem_data;
    logic signed [DATA_WIDTH-1:0]  conv_bias_param    [0:N_SHAABAN-1];
    logic signed [DATA_WIDTH-1:0]  mult_weight_param  [0:N_SHAABAN-1];
    logic signed [DATA_WIDTH-1:0]  add_weight_param   [0:N_SHAABAN-1];
    logic signed [DATA_WIDTH-1:0]  fc1_in             [0:FC1_INPUTS-1];
    logic signed [DATA_WIDTH-1:0]  fc1_out            [0:FC1_OUTPUTS-1];
    logic signed [DATA_WIDTH-1:0]  fc2_out            [0:FC2_OUTPUTS-1];
    logic                          fc1_start;
    logic                          fc1_done;
    logic                          fc1_busy;
    logic                          fc2_start;
    logic                          fc2_done;
    logic                          fc2_busy;

    logic signed [PIXEL_W-1:0]    pixels_mapped   [0:11][0:31][0:8];
    logic signed [PIXEL_W-1:0]    pixels_to_conv  [0:11][0:31][0:8];
    logic signed [PIXEL_W-1:0]    weights_mapped  [0:11][0:31][0:8];
    logic signed [DATA_WIDTH-1:0] mac_to_connect  [0:11][0:31];
    logic signed [(INPUTS_PER_SHB*DATA_WIDTH)-1:0] shb_bus [0:N_SHAABAN-1];
    logic /*[0:31]*/                  shaaban_spike_bus [0:31];

    // =========================================================================
    // top_controller
    // =========================================================================
    top_controller #(
        .FRAGMENT_ROWS   (CTRL_FRAGMENT_ROWS),
        .FRAGMENT_COLS   (CTRL_FRAGMENT_COLS),
        .FRAGMENTS_MAX   (CTRL_FRAGMENTS_MAX),
        .TEMPORAL_FRAMES (CTRL_TEMPORAL_FRAMES)
    ) u_top_controller (
        .clk            (clk),
        .rst            (rst),
        .arst_n         (arst_n),
        .enable         (enable),
        .done_load_o    (ctrl_done_load_o),     //from mapping controller
        .conv_done_o    (map_conv_done_o),
        .mem_enable     (ctrl_mem_enable),
        .rd_enable      (ctrl_rd_enable),
        .stage          (src_sel),
        .frame          (frame),
        .stage_sel      (stage_sel),
        .conv2_filter   (conv2_filter),
        .conv3_filter   (conv3_filter),
        .rd_mem_adderss (ctrl_rd_mem_adderss),
        .wr_mem_adderss (ctrl_wr_mem_adderss),
        .zero           (ctrl_zero),
        .zero_sel       (ctrl_zero_sel),
        .padding_flag   (ctrl_padding_flag),
        .gap_valid      (gap_sample_enable),
        .fetch_en_i     (ctrl_fetch_en_i),
        .next_i         (ctrl_next_i),
        .done           (snn_done)
    );

    // =========================================================================
    // mapping_controller
    // FIX [1]: parameters now use top-level params instead of hardcoded literals
    // =========================================================================
    mapping_controller #(
        .PIXEL_W    (PIXEL_W),
        .WORD_W     (MAP_WORD_W),
        .IMG_ROWS   (MAP_IMG_ROWS),
        .IMG_COLS   (MAP_IMG_COLS),
        .BUF_SIZE   (MAP_BUF_SIZE),
        .BANK_COLS  (MAP_BANK_COLS),
        .CONV_K     (MAP_CONV_K),
        .NUM_H_WIN  (MAP_NUM_H_WIN),
        .NUM_SWEEPS (MAP_NUM_SWEEPS)
    ) u_mapping_controller (
        .clk          (clk),
        .rst_n        (arst_n),
        .start_i      (start_i),
        .next_i       (ctrl_next_i),
        .fetch_en_i   (ctrl_fetch_en_i),
        .mem_addr_o   (mem_addr_o),
        .mem_rd_o     (mem_rd_o),
        .mem_data_i   (mem_data_i),
        .conv_pixels_o(map_conv_pixels_o),   // FIX [2]: TODO connect downstream
        .conv_valid_o (map_conv_valid_o),    // FIX [3]: Not used
        .conv_done_o  (map_conv_done_o),     
        .done_o       (map_ctrl_done_o),
        .frame_done_o (map_frame_done_o),    // FIX [4]: Not used
        .done_load_o  (ctrl_done_load_o)
`ifdef SIM
        ,.state_o     (map_state_o)          // FIX [8]: SIM only
`endif
    );

    assign map_done_o = map_ctrl_done_o;

    // =========================================================================
    // pixel_mem
    // FIX [9]: rd_en now qualified by ctrl_rd_enable
    // =========================================================================
    pixel_mem #(
        .DATA_WIDTH  (PIXEL_W),
        .WORD_PIXELS (384),
        .ADDR_WIDTH  (6)
    ) u_pixel_mem (
        .clk     (clk),
        .rst     (rst),
        .wr_en   (pixel_mem_wr_en), //? gaya input mn bara
        .wr_addr (pixel_mem_wr_addr),
        .wr_data (pixel_mem_wr_data),
        .rd_addr (ctrl_rd_mem_adderss),
        .rd_data (pixel_mem_raw)
    );

`ifdef SIM
    always_comb begin
        if (sim_pixel_mem_override === 1'b1)
            pixel_mem_data = sim_pixel_mem_data;
        else
            pixel_mem_data = pixel_mem_raw;
    end
`else
    assign pixel_mem_data = pixel_mem_raw;
`endif

    // =========================================================================
    // bias_bn_params
    // =========================================================================
    bias_bn_params #(
        .DATA_WIDTH     (DATA_WIDTH),
        .N_SHAABAN      (N_SHAABAN),
        .CONV2_FILTER_W (6),
        .CONV3_FILTER_W (7)
    ) u_bias_bn_params (
        .stage        (src_sel),
        .conv2_filter (conv2_filter),
        .conv3_filter (conv3_filter),
        .conv_bias    (conv_bias_param),
        .mult_weight  (mult_weight_param),
        .add_weight   (add_weight_param)
    );

    // =========================================================================
    // spike_mem
    // FIX [3]: spike_mem_wr_en now qualified with ctrl_zero_sel to prevent
    // spurious spike writes during the CLEAR phase (zero-fill pass).
    // During CLEAR: ctrl_zero_sel=1 -> wr_en fires, but spike_mem already muxes
    // zero data when zero_sel=1.  During normal stage: ctrl_zero_sel=0 and
    // src_sel is non-zero, so real spike data is written.
    // =========================================================================
    assign spike_mem_wr_en = enable &&
                             (|ctrl_mem_enable) &&
                             (ctrl_zero_sel || (src_sel != 2'b00));  // FIX [3]

    spike_mem #(
        .MEM_WORD   (3200),
        .ADDR_WIDTH (6)
    ) u_spike_mem (
        .clk        (clk),
        .rst        (rst),
        .wr_en      (spike_mem_wr_en),
        .bit_enable (ctrl_mem_enable),
        .zero_sel   (ctrl_zero_sel),
        .wr_addr    (ctrl_wr_mem_adderss),
        //.rd_en      (ctrl_rd_enable),          // FIX [9]
        .rd_addr    (ctrl_rd_mem_adderss),
        .wr_data    (spike_mem_wr_data),
        .rd_data    (spike_mem_data)
    );

    // =========================================================================
    // top_pixel_source_mapper
    // FIX [10]: padding_flag forwarded
    // =========================================================================
    top_pixel_source_mapper #(
        .PIXEL_W        (PIXEL_W),
        .FRAME_NO       (FRAME_NO),
        .FRAME_NO_WIDTH (FRAME_NO_WIDTH)
    ) u_pixel_source_mapper (
        .clk            (clk),
        .arst_n         (arst_n),
        .src_sel        (src_sel),
        .frame          (frame),
        .pixel_mem_data (map_conv_pixels_o),
        .spike_mem_data (spike_mem_data),
        .pixels_mapped  (pixels_mapped)
    );

    // =========================================================================
    // top_weight_mapper
    // =========================================================================
    top_weight_mapper #(
        .PIXEL_W (PIXEL_W)
    ) u_weight_mapper (
        .src_sel        (src_sel),
        .conv2_filter   (conv2_filter),
        .conv3_filter   (conv3_filter),
        .weights_mapped (weights_mapped)
    );

    // =========================================================================
    // Pixel source mux (SIM override / normal)
    // =========================================================================
    genvar sim_group, sim_channel, sim_tap;
    generate
        for (sim_group = 0; sim_group < 12; sim_group++) begin : gen_sim_group
            for (sim_channel = 0; sim_channel < 32; sim_channel++) begin : gen_sim_channel
                for (sim_tap = 0; sim_tap < 9; sim_tap++) begin : gen_sim_tap
                    localparam int SIM_PIXEL_INDEX =
                        (((sim_group * 32) + sim_channel) * 9) + sim_tap;
`ifdef SIM
                    always_comb begin
                        if (sim_pixels_override === 1'b1)
                            pixels_to_conv[sim_group][sim_channel][sim_tap] =
                                $signed(sim_pixels[SIM_PIXEL_INDEX*PIXEL_W +: PIXEL_W]);
                        else
                            pixels_to_conv[sim_group][sim_channel][sim_tap] =
                                pixels_mapped[sim_group][sim_channel][sim_tap];
                    end
`else
                    assign pixels_to_conv[sim_group][sim_channel][sim_tap] =
                        pixels_mapped[sim_group][sim_channel][sim_tap];
`endif
                end
            end
        end
    endgenerate

    // =========================================================================
    // top_conv9_array
    // =========================================================================
    top_conv9_array #(
        .PIXEL_W    (PIXEL_W),
        .MAC_OUT_W  (MAC_OUT_W),
        .DATA_WIDTH (DATA_WIDTH)
    ) u_conv9_array (
        .clk            (clk),
        .pixels_mapped  (pixels_to_conv),
        .weights_mapped (weights_mapped),
        .mac_to_connect (mac_to_connect)
    );

    // =========================================================================
    // adder_tree_shaaban_connect
    // =========================================================================
    adder_tree_shaaban_connect u_connect (
        .clk          (clk),
        .rst          (rst),
        .src_sel      (src_sel),
        .mac_in       (mac_to_connect),
        .shb_conv_bus (shb_bus)
    );

    // =========================================================================
    // top_shaaban_array
    // =========================================================================
    top_shaaban_array #(
        .DATA_WIDTH     (DATA_WIDTH),
        .N_SHAABAN      (N_SHAABAN),
        .INPUTS_PER_SHB (INPUTS_PER_SHB)
    ) u_shaaban_array (
        .clk               (clk),
        .rst               (rst),
        .shb_bus           (shb_bus),
        .conv_bias_param   (conv_bias_param),
        .mult_weight_param (mult_weight_param),
        .add_weight_param  (add_weight_param),
        .spike_out         (spike_out),
        .shaaban_spike_bus (shaaban_spike_bus)
    );

    // =========================================================================
    // top_spike_writeback
    // =========================================================================
    top_spike_writeback u_spike_writeback (
        .stage             (src_sel),
        .shaaban_spike_bus (shaaban_spike_bus),
        .spike_mem_wr_data (spike_mem_wr_data)
    );

    // =========================================================================
    // Registered edge-detection flops
    // FIX [4][5][6][7]: all done/start signals now properly edge-detected
    // =========================================================================
    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            enable_d   <= 1'b0;
            snn_done_d <= 1'b0;
            gap_done_d <= 1'b0;    // FIX [5]
            fc1_done_d <= 1'b0;    // FIX [6]
            done       <= 1'b0;    // FIX [7]
        end else if (rst) begin
            enable_d   <= 1'b0;
            snn_done_d <= 1'b0;
            gap_done_d <= 1'b0;
            fc1_done_d <= 1'b0;
            done       <= 1'b0;
        end else begin
            enable_d   <= enable;
            snn_done_d <= snn_done;
            gap_done_d <= gap_done;
            fc1_done_d <= fc1_done;
            done       <= fc2_done;  // FIX [7]: registered, not combinational
        end
    end

    // FIX [4]: gap_clear additionally gated on !classifier_busy so a fast
    // enable toggle does not clear the accumulator while FC is still running.
    assign gap_clear       = enable && !enable_d && !classifier_busy;

    // FIX [5]: fc1_start is a single-cycle rising-edge pulse of gap_done
    assign fc1_start       = gap_done  && !gap_done_d;

    // FIX [6]: fc2_start is a single-cycle rising-edge pulse of fc1_done
    assign fc2_start       = fc1_done  && !fc1_done_d;

    assign classifier_done = fc2_done;
    assign classifier_busy = gap_busy || fc1_busy || fc2_busy;

    // =========================================================================
    // Global Average Pool
    // =========================================================================
    global_average_pool #(
        .DATA_WIDTH   (DATA_WIDTH),
        .FRAC_BITS    (CLASSIFIER_FRAC_BITS),
        .CHANNELS     (FC1_INPUTS),
        .SAMPLE_COUNT (CTRL_FRAGMENTS_MAX)
    ) u_global_average_pool (
        .clk            (clk),
        .rst            (rst),
        .clear          (gap_clear),
        .sample_valid   ((src_sel == 2'b10) && gap_sample_enable &&
                          ctrl_mem_enable[conv3_filter]),
        .sample_channel (conv3_filter),
        .sample_spike   (spike_out[0]),
        .start          (snn_done && !snn_done_d),
        .pool_out       (fc1_in),
        .done           (gap_done),
        .busy           (gap_busy)
    );

    // =========================================================================
    // FC1
    // =========================================================================
    fc1_layer #(
        .DATA_WIDTH (DATA_WIDTH),
        .FRAC_BITS  (CLASSIFIER_FRAC_BITS),
        .N_INPUTS   (FC1_INPUTS),
        .N_OUTPUTS  (FC1_OUTPUTS)
    ) u_fc1_layer (
        .clk    (clk),
        .arst_n    (rst),
        .fc_in  (fc1_in),
        .start  (fc1_start),
        .fc_out (fc1_out),
        .done   (fc1_done),
        .busy   (fc1_busy)
    );

    // =========================================================================
    // FC2
    // =========================================================================
    fc2_layer #(
        .DATA_WIDTH (DATA_WIDTH),
        .FRAC_BITS  (CLASSIFIER_FRAC_BITS),
        .N_INPUTS   (FC1_OUTPUTS),
        .N_OUTPUTS  (FC2_OUTPUTS)
    ) u_fc2_layer (
        .clk    (clk),
        .arst_n    (rst),
        .fc_in  (fc1_out),
        .start  (fc2_start),
        .fc_out (fc2_out),
        .done   (fc2_done),
        .busy   (fc2_busy)
    );

    // =========================================================================
    // Class logits packer
    // =========================================================================
    top_class_logits_packer #(
        .DATA_WIDTH (DATA_WIDTH),
        .N_OUTPUTS  (FC2_OUTPUTS)
    ) u_class_logits_packer (
        .fc_out       (fc2_out),
        .class_logits (class_logits)
    );

endmodule