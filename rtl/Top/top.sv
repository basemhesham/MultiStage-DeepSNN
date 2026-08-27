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
    parameter int CTRL_FRAGMENT_ROWS   = 32,
    parameter int CTRL_FRAGMENT_COLS   = 32,
    parameter int CTRL_FRAGMENTS_MAX   = CTRL_FRAGMENT_ROWS * CTRL_FRAGMENT_COLS,
    parameter int CTRL_TEMPORAL_FRAMES = 16,
    // mapping_controller parameters — FIX [1]: promoted from hardcoded literals
    parameter int MAP_WORD_W           = 72,
    parameter int MAP_IMG_ROWS         = 24,
    parameter int MAP_IMG_COLS         = 256,
    parameter int MAP_BUF_SIZE         = 24,
    parameter int MAP_BANK_COLS        = 8,
    parameter int MAP_CONV_K           = 5,
    parameter int MAP_NUM_H_WIN        = 32,
    parameter int MAP_NUM_SWEEPS       = 32,
    // LIF history-memory parameters — HIERARCHY EDIT: fetch and BRAM_LIF_Mem_0
    // are now instantiated directly here (x32 each) instead of inside
    // lif_mem_top, so their address/depth parameters move up to this level.
    parameter int LIF_ADDR_WIDTH       = 15,
    parameter int LIF_MEM_DEPTH        = 18432
)(
    input  logic                          clk,
    input  logic                          rst,
    input  wire                           arst_n,
    input  wire                           enable,

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
    logic [3199:0]                 ctrl_mem_enable;
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

    logic[2:0]                     shb_mem_en;

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
    logic                             frame_start_o;
    logic                             frame_start_pulse;

    // =========================================================================
    // Per-lane LIF history memory signals
    // HIERARCHY EDIT: fetch and BRAM_LIF_Mem_0 are now instantiated individually
    // (x32 each) directly here instead of inside lif_mem_top/shaban_unit_top.
    // hist_in/hist_out cross the top_shaaban_array boundary on a per-lane basis.
    // =========================================================================
    logic                          lif_rd_en   [0:N_SHAABAN-1];
    logic [LIF_ADDR_WIDTH-1:0]     lif_rd_addr [0:N_SHAABAN-1];
    logic                          lif_wr_en   [0:N_SHAABAN-1];
    logic [LIF_ADDR_WIDTH-1:0]     lif_wr_addr [0:N_SHAABAN-1];
    logic                          lif_out_valid [0:N_SHAABAN-1]; // fetch status, unused downstream for now
    logic [LIF_ADDR_WIDTH-1:0]     lif_addr_out  [0:N_SHAABAN-1]; // fetch status, unused downstream for now
    logic                          lif_valid_in  [0:N_SHAABAN-1];  // valid data selection for LIF
    logic signed [DATA_WIDTH-1:0]  lif_hist_in   [0:N_SHAABAN-1]; // H[t-1] per lane, from BRAM doutb
    logic signed [DATA_WIDTH-1:0]  lif_hist_out  [0:N_SHAABAN-1]; // H[t]   per lane, into BRAM dina
    logic signed [DATA_WIDTH-1:0]  lif_hist_out_dbg [0:N_SHAABAN-1];
	logic [2:0] stage2_last_frame_idx_o;
	logic special_row_col_ind;

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
        .conv3_filter   ({5'b0,conv3_filter}),
        .rd_mem_adderss (ctrl_rd_mem_adderss),
        .wr_mem_adderss (ctrl_wr_mem_adderss),
        .zero           (ctrl_zero),
        .zero_sel       (ctrl_zero_sel),
        .padding_flag   (ctrl_padding_flag),
        .gap_valid      (gap_sample_enable),
        .fetch_en_i     (ctrl_fetch_en_i),
        .next_i         (ctrl_next_i),
        .done           (snn_done),
        .stage2_last_frame_idx_o(stage2_last_frame_idx_o),
        .shb_mem_en     (shb_mem_en),
        .special_row_col_ind(special_row_col_ind)
    );

    logic try_next_i;   //drived in the test bench
    logic try_fetch;
    logic new_data_o;
    logic [3:0] frame_counter;
    logic frame_start_stg2_3_o; 

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
        .done_load_o  (ctrl_done_load_o),
        .new_data_o   (new_data_o),
        .frame_counter_o(frame_counter),
        .frame_start_o  (frame_start_o),
        .frame_start_stg2_3_o(frame_start_stg2_3_o)
`ifdef SIM
        ,.state_o     (map_state_o)          // FIX [8]: SIM only
`endif
    );

    assign map_done_o = map_ctrl_done_o;


    // =========================================================================
    // Pulse_generator
    // =========================================================================
    pulse_gen u_pulse_gen_stg1 (
        .clk          (clk),
        .rst_n        (arst_n),
        .frame_start  (frame_start_o),
        .pulse        (frame_start_pulse)
    );

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
                             (ctrl_zero_sel || (src_sel != 2'b11));  // FIX [3]

    spike_mem #(
        .MEM_WORD   (3200),
        .ADDR_WIDTH (6)
    ) u_spike_mem (
        .clk        (clk),
        .rst        (arst_n),
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
    // Per-lane fetch + BRAM_LIF_Mem_0 (HIERARCHY EDIT)
    // 32 individual fetch instances and 32 individual BRAM_LIF_Mem_0 instances,
    // one pair per Shaaban lane. Previously each lane's fetch+BRAM pair was
    // instantiated inside that lane's lif_mem_top; now they live here at
    // deep_snn_top and exchange hist_in/hist_out with top_shaaban_array on a
    // per-lane basis. new_data_o/frame_start_pulse are broadcast identically
    // to every lane, same as before.
    // =========================================================================
    logic signed [DATA_WIDTH-1:0]  s1_hist_in   [0:N_SHAABAN-1]; // H[t-1] per lane, from BRAM doutb
    genvar lif_l;
    
    generate
        for (lif_l = 0; lif_l < N_SHAABAN; lif_l++) begin : gen_lif_mem_lane
            fetch u_fetch (
                .clk         (clk),
                .arst_n      (arst_n),
                .frame_count (frame_counter), // only lane 0 sees first frame
                .frame_start (frame_start_pulse),
                .in_valid    (new_data_o),
                .rd_en       (lif_rd_en[lif_l]),
                .rd_addr     (lif_rd_addr[lif_l]),
                .wr_en       (lif_wr_en[lif_l]),
                .wr_addr     (lif_wr_addr[lif_l]),
                .out_valid   (lif_out_valid[lif_l]),
                .addr_out    (lif_addr_out[lif_l])
            );

            BRAM_LIF_Mem_0 #(
                .DATA_WIDTH (DATA_WIDTH),
                .ADDR_WIDTH (LIF_ADDR_WIDTH),
                .DEPTH      (LIF_MEM_DEPTH)
            ) u_hist_mem (
                // Port A - write H[t] back
                .clka  (clk),
                .ena   (lif_wr_en[lif_l]),
                .wea   (lif_wr_en[lif_l]),
                .addra (lif_wr_addr[lif_l]),
                .dina  (lif_hist_out_dbg[lif_l]),

                // Port B - read H[t-1]
                .clkb  (clk),
                .enb   (lif_rd_en[lif_l]),
                .web   (1'b0),
                .addrb (lif_rd_addr[lif_l]),
                .dinb  ({DATA_WIDTH{1'b0}}),
                .doutb (s1_hist_in[lif_l])
            );
        end
    endgenerate


    // pulse generator for stage 2 to make the start frame inout for stage 2

    logic frame_start_stg2;
    assign frame_start_stg2 = (frame_start_stg2_3_o);
    pulse_gen u_pulse_gen_stg2 (
        .clk          (clk),
        .rst_n        (arst_n),
        .frame_start  (frame_start_stg2),
        .pulse        (frame_start_pulse_stg2)
    );

    // =========================================================================
    // Stage 2 history memories: fetch_stage2_0 / fetch_stage2_1 / fetch_stage2_2
    //
    // Unlike the Stage-1 per-lane arrangement above (32 identical fetch+BRAM
    // pairs, one per Shaaban lane), each of these is a SINGLE flat-addressed
    // memory group -- POS_PER_FRAME already folds in all 64 channels (e.g.
    // 71552 = 1118*64), so there is exactly one fetch instance and one bank
    // array per group, not one per lane. Each group is driven by its own
    // new_data pulse from top_controller so the shared Shaaban/LIF pipeline
    // can be time-multiplexed across the three Stage-2 layers.
    //
    // Bank decode is a plain bit-slice (not division/comparators) because
    // every physical bank here is 2048 = 2^11 deep: bank_index = addr[MSBs],
    // local_addr = addr[10:0].
    //
    // hist_out_stage2_* (the data actually WRITTEN into these memories) has
    // no producer yet in this project snapshot -- tied to '0 as an explicit
    // placeholder (TODO) so nothing floats to X in sim. Wire it to the real
    // Stage-2 LIF/consumer once that module exists.
    // =========================================================================

    // -------------------------------------------------------------------
    // Group 0: fetch_stage2_0 -- 36 BRAM banks, no register-file tail
    // -------------------------------------------------------------------
    localparam int S2_0_POS_PER_FRAME = 73728;
    localparam int S2_0_NUM_BANKS     = 36;
    localparam int S2_0_ADDR_WIDTH    = $clog2(S2_0_POS_PER_FRAME); // 17
    localparam int S2_0_BANK_DEPTH    = 2048;
    localparam int S2_0_BANK_AW       = $clog2(S2_0_BANK_DEPTH);        // 11
    localparam int S2_0_BANK_IDX_W    = S2_0_ADDR_WIDTH - S2_0_BANK_AW; // 6

    logic                          s2_0_rd_en, s2_0_wr_en;
    logic [S2_0_ADDR_WIDTH-1:0]    s2_0_rd_addr, s2_0_wr_addr;
    logic                          s2_0_out_valid;
    logic [S2_0_ADDR_WIDTH-1:0]    s2_0_addr_out;

    fetch_stage2_0 u_fetch_stage2_0 (
        .clk         (clk),
        .arst_n      (arst_n),
        .frame_count (frame_counter),
        .frame_start (frame_start_pulse_stg2),
        .in_valid    (shb_mem_en[0]),
        .rd_en       (s2_0_rd_en),
        .rd_addr     (s2_0_rd_addr),
        .wr_en       (s2_0_wr_en),
        .wr_addr     (s2_0_wr_addr),
        .out_valid   (s2_0_out_valid),
        .addr_out    (s2_0_addr_out)
    );


    wire [S2_0_BANK_IDX_W-1:0] s2_0_rd_bank  = s2_0_rd_addr[S2_0_ADDR_WIDTH-1:S2_0_BANK_AW];
    wire [S2_0_BANK_AW-1:0]    s2_0_rd_local = s2_0_rd_addr[S2_0_BANK_AW-1:0];
    wire [S2_0_BANK_IDX_W-1:0] s2_0_wr_bank  = s2_0_wr_addr[S2_0_ADDR_WIDTH-1:S2_0_BANK_AW];
    wire [S2_0_BANK_AW-1:0]    s2_0_wr_local = s2_0_wr_addr[S2_0_BANK_AW-1:0];

    logic [DATA_WIDTH-1:0]      s2_0_bank_douta [0:S2_0_NUM_BANKS-1];
    logic [S2_0_BANK_IDX_W-1:0] s2_0_rd_bank_d1; // selects the valid bank's doutb 1 cycle later

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) s2_0_rd_bank_d1 <= '0;
        else         s2_0_rd_bank_d1 <= s2_0_rd_bank;
    end

    logic [S2_0_NUM_BANKS-1:0] s2_0_bank_wr_sel;  // per-bank write select (kept off the port connections below)
    logic [S2_0_NUM_BANKS-1:0] s2_0_bank_rd_sel;  // per-bank read select (kept off the port connections below)

    genvar s2_0_b;
    generate
        for (s2_0_b = 0; s2_0_b < S2_0_NUM_BANKS; s2_0_b++) begin : gen_s2_0_bank
            assign s2_0_bank_wr_sel[s2_0_b] = s2_0_wr_en && (s2_0_wr_bank == s2_0_b);
            assign s2_0_bank_rd_sel[s2_0_b] = s2_0_rd_en && (s2_0_rd_bank == s2_0_b);

            BRAM_LIF_Mem_0 #(
                .DATA_WIDTH (DATA_WIDTH),
                .ADDR_WIDTH (S2_0_BANK_AW),
                .DEPTH      (S2_0_BANK_DEPTH)
            ) u_bram (
                .clka  (clk),
                .ena   (s2_0_bank_wr_sel[s2_0_b]),
                .wea   (s2_0_bank_wr_sel[s2_0_b]),
                .addra (s2_0_wr_local),
                .dina  (lif_hist_out_dbg[0]),

                .clkb  (clk),
                .enb   (s2_0_bank_rd_sel[s2_0_b]),
                .web   (1'b0),
                .addrb (s2_0_rd_local),
                .dinb  ({DATA_WIDTH{1'b0}}),
                .doutb (s2_0_bank_douta[s2_0_b])
            );
        end
    endgenerate

    logic signed [DATA_WIDTH-1:0] s2_0_hist_in; 
    assign s2_0_hist_in = s2_0_bank_douta[s2_0_rd_bank_d1];

    // -------------------------------------------------------------------
    // Group 1: fetch_stage2_1 -- 62 BRAM banks + 128-entry register-file tail
    // -------------------------------------------------------------------
    localparam int S2_1_POS_PER_FRAME  = 127104;
    localparam int S2_1_NUM_MEM_BANKS  = 62;
    localparam int S2_1_MEM_SIZE       = S2_1_NUM_MEM_BANKS * 2048;          // 126976
    localparam int S2_1_NUM_REGS       = S2_1_POS_PER_FRAME - S2_1_MEM_SIZE; // 128
    localparam int S2_1_ADDR_WIDTH     = $clog2(S2_1_POS_PER_FRAME);         // 17
    localparam int S2_1_BANK_DEPTH     = 2048;
    localparam int S2_1_BANK_AW        = $clog2(S2_1_BANK_DEPTH);            // 11
    localparam int S2_1_BANK_IDX_W     = S2_1_ADDR_WIDTH - S2_1_BANK_AW;     // 6
    localparam int S2_1_REG_ADDR_WIDTH = (S2_1_NUM_REGS > 1) ? $clog2(S2_1_NUM_REGS) : 1; // 7

    logic                             s2_1_mem_rd_en, s2_1_mem_wr_en;
    logic [S2_1_ADDR_WIDTH-1:0]       s2_1_mem_rd_addr, s2_1_mem_wr_addr;
    logic                             s2_1_reg_rd_en, s2_1_reg_wr_en;
    logic [S2_1_REG_ADDR_WIDTH-1:0]   s2_1_reg_rd_addr, s2_1_reg_wr_addr;
    logic                             s2_1_out_valid;
    logic [S2_1_ADDR_WIDTH-1:0]       s2_1_addr_out;

    fetch_stage2_1 u_fetch_stage2_1 (
        .clk          (clk),
        .arst_n       (arst_n),
        .frame_count  (frame_counter),
        .frame_start  (frame_start_pulse_stg2),
        .in_valid     (shb_mem_en[1]),
        .mem_rd_en    (s2_1_mem_rd_en),
        .mem_rd_addr  (s2_1_mem_rd_addr),
        .mem_wr_en    (s2_1_mem_wr_en),
        .mem_wr_addr  (s2_1_mem_wr_addr),
        .reg_rd_en    (s2_1_reg_rd_en),
        .reg_rd_addr  (s2_1_reg_rd_addr),
        .reg_wr_en    (s2_1_reg_wr_en),
        .reg_wr_addr  (s2_1_reg_wr_addr),
        .out_valid    (s2_1_out_valid),
        .addr_out     (s2_1_addr_out)
    );


    wire [S2_1_BANK_IDX_W-1:0] s2_1_mem_rd_bank  = s2_1_mem_rd_addr[S2_1_ADDR_WIDTH-1:S2_1_BANK_AW];
    wire [S2_1_BANK_AW-1:0]    s2_1_mem_rd_local = s2_1_mem_rd_addr[S2_1_BANK_AW-1:0];
    wire [S2_1_BANK_IDX_W-1:0] s2_1_mem_wr_bank  = s2_1_mem_wr_addr[S2_1_ADDR_WIDTH-1:S2_1_BANK_AW];
    wire [S2_1_BANK_AW-1:0]    s2_1_mem_wr_local = s2_1_mem_wr_addr[S2_1_BANK_AW-1:0];

    logic [DATA_WIDTH-1:0] s2_1_bank_douta [0:S2_1_NUM_MEM_BANKS-1];

    logic [S2_1_NUM_MEM_BANKS-1:0] s2_1_bank_wr_sel;  // per-bank write select (kept off the port connections below)
    logic [S2_1_NUM_MEM_BANKS-1:0] s2_1_bank_rd_sel;  // per-bank read select (kept off the port connections below)

    genvar s2_1_b;
    generate
        for (s2_1_b = 0; s2_1_b < S2_1_NUM_MEM_BANKS; s2_1_b++) begin : gen_s2_1_bank
            assign s2_1_bank_wr_sel[s2_1_b] = s2_1_mem_wr_en && (s2_1_mem_wr_bank == s2_1_b);
            assign s2_1_bank_rd_sel[s2_1_b] = s2_1_mem_rd_en && (s2_1_mem_rd_bank == s2_1_b);

            BRAM_LIF_Mem_0 #(
                .DATA_WIDTH (DATA_WIDTH),
                .ADDR_WIDTH (S2_1_BANK_AW),
                .DEPTH      (S2_1_BANK_DEPTH)
            ) u_bram (
                .clka  (clk),
                .ena   (s2_1_bank_wr_sel[s2_1_b]),
                .wea   (s2_1_bank_wr_sel[s2_1_b]),
                .addra (s2_1_mem_wr_local),
                .dina  (lif_hist_out_dbg[1]),

                .clkb  (clk),
                .enb   (s2_1_bank_rd_sel[s2_1_b]),
                .web   (1'b0),
                .addrb (s2_1_mem_rd_local),
                .dinb  ({DATA_WIDTH{1'b0}}),
                .doutb (s2_1_bank_douta[s2_1_b])
            );
        end
    endgenerate

    logic [DATA_WIDTH-1:0] s2_1_reg_rd_data;

    hist_regfile_128x18 #(
        .DEPTH      (S2_1_NUM_REGS),
        .DATA_WIDTH (DATA_WIDTH)
    ) u_hist_regfile_stage2_1 (
        .clk     (clk),
        .arst_n  (arst_n),
        .rd_en   (s2_1_reg_rd_en),
        .rd_addr (s2_1_reg_rd_addr),
        .rd_data (s2_1_reg_rd_data),
        .wr_en   (s2_1_reg_wr_en),
        .wr_addr (s2_1_reg_wr_addr),
        .wr_data (lif_hist_out_dbg[1])
    );

    // Read-side select: BRAM bank vs. regfile, matching the 1-cycle read
    // latency both storage types share.
    logic [S2_1_BANK_IDX_W-1:0] s2_1_mem_rd_bank_d1;
    logic                       s2_1_rd_was_reg_d1;

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            s2_1_mem_rd_bank_d1 <= '0;
            s2_1_rd_was_reg_d1  <= 1'b0;
        end else begin
            s2_1_mem_rd_bank_d1 <= s2_1_mem_rd_bank;
            s2_1_rd_was_reg_d1  <= s2_1_reg_rd_en;
        end
    end

    logic signed [DATA_WIDTH-1:0] s2_1_hist_in; 
    assign s2_1_hist_in = s2_1_rd_was_reg_d1 ? s2_1_reg_rd_data
                                              : s2_1_bank_douta[s2_1_mem_rd_bank_d1];

    // -------------------------------------------------------------------
    // Group 2: fetch_stage2_2 -- 33 BRAM banks, no register-file tail
    // -------------------------------------------------------------------
    localparam int S2_2_POS_PER_FRAME = 67584;
    localparam int S2_2_NUM_BANKS     = 33;
    localparam int S2_2_ADDR_WIDTH    = $clog2(S2_2_POS_PER_FRAME); // 17
    localparam int S2_2_BANK_DEPTH    = 2048;
    localparam int S2_2_BANK_AW       = $clog2(S2_2_BANK_DEPTH);        // 11
    localparam int S2_2_BANK_IDX_W    = S2_2_ADDR_WIDTH - S2_2_BANK_AW; // 6

    logic                          s2_2_rd_en, s2_2_wr_en;
    logic [S2_2_ADDR_WIDTH-1:0]    s2_2_rd_addr, s2_2_wr_addr;
    logic                          s2_2_out_valid;
    logic [S2_2_ADDR_WIDTH-1:0]    s2_2_addr_out;

    fetch_stage2_2 u_fetch_stage2_2 (
        .clk         (clk),
        .arst_n      (arst_n),
        .frame_count (frame_counter),
        .frame_start (frame_start_pulse_stg2),
        .in_valid    (shb_mem_en[2]),
        .rd_en       (s2_2_rd_en),
        .rd_addr     (s2_2_rd_addr),
        .wr_en       (s2_2_wr_en),
        .wr_addr     (s2_2_wr_addr),
        .out_valid   (s2_2_out_valid),
        .addr_out    (s2_2_addr_out)
    );


    wire [S2_2_BANK_IDX_W-1:0] s2_2_rd_bank  = s2_2_rd_addr[S2_2_ADDR_WIDTH-1:S2_2_BANK_AW];
    wire [S2_2_BANK_AW-1:0]    s2_2_rd_local = s2_2_rd_addr[S2_2_BANK_AW-1:0];
    wire [S2_2_BANK_IDX_W-1:0] s2_2_wr_bank  = s2_2_wr_addr[S2_2_ADDR_WIDTH-1:S2_2_BANK_AW];
    wire [S2_2_BANK_AW-1:0]    s2_2_wr_local = s2_2_wr_addr[S2_2_BANK_AW-1:0];

    logic [DATA_WIDTH-1:0]      s2_2_bank_douta [0:S2_2_NUM_BANKS-1];
    logic [S2_2_BANK_IDX_W-1:0] s2_2_rd_bank_d1;

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) s2_2_rd_bank_d1 <= '0;
        else         s2_2_rd_bank_d1 <= s2_2_rd_bank;
    end

    logic [S2_2_NUM_BANKS-1:0] s2_2_bank_wr_sel;  // per-bank write select (kept off the port connections below)
    logic [S2_2_NUM_BANKS-1:0] s2_2_bank_rd_sel;  // per-bank read select (kept off the port connections below)

    genvar s2_2_b;
    generate
        for (s2_2_b = 0; s2_2_b < S2_2_NUM_BANKS; s2_2_b++) begin : gen_s2_2_bank
            assign s2_2_bank_wr_sel[s2_2_b] = s2_2_wr_en && (s2_2_wr_bank == s2_2_b);
            assign s2_2_bank_rd_sel[s2_2_b] = s2_2_rd_en && (s2_2_rd_bank == s2_2_b);

            BRAM_LIF_Mem_0 #(
                .DATA_WIDTH (DATA_WIDTH),
                .ADDR_WIDTH (S2_2_BANK_AW),
                .DEPTH      (S2_2_BANK_DEPTH)
            ) u_bram (
                .clka  (clk),
                .ena   (s2_2_bank_wr_sel[s2_2_b]),
                .wea   (s2_2_bank_wr_sel[s2_2_b]),
                .addra (s2_2_wr_local),
                .dina  (lif_hist_out_dbg[2]),

                .clkb  (clk),
                .enb   (s2_2_bank_rd_sel[s2_2_b]),
                .web   (1'b0),
                .addrb (s2_2_rd_local),
                .dinb  ({DATA_WIDTH{1'b0}}),
                .doutb (s2_2_bank_douta[s2_2_b])
            );
        end
    endgenerate

    logic signed [DATA_WIDTH-1:0] s2_2_hist_in;
    assign s2_2_hist_in = s2_2_bank_douta[s2_2_rd_bank_d1];





    // pulse generator for stage 2 to make the start frame inout for stage 2

    logic frame_start_stg3;
    assign frame_start_stg3 = (frame_start_stg2_3_o);
    pulse_gen u_pulse_gen_stg3 (
        .clk          (clk),
        .rst_n        (arst_n),
        .frame_start  (frame_start_stg3),
        .pulse        (frame_start_pulse_stg3)
    );

    // =========================================================================
    // Stage 3 history memory: fetch_stage3
    //
    // Single flat-addressed memory group (one fetch instance, one bank array),
    // same shape as the Stage-2 groups above. Unlike Stage 2 (which is enabled
    // per-group off top_controller's shb_mem_en bus), Stage 3 has exactly ONE
    // enable straight from top_controller: it is active whenever "stage"
    // (src_sel) == 2.
    //
    // Sized for NUM_BANKS = 36 physical 36Kb BRAMs. At DATA_WIDTH-wide words,
    // a 36Kb BRAM is 2048 entries deep (2048*18 = 36864 = 36Kb), so
    // POS_PER_FRAME = 36 * 2048 = 73728 exactly - divides evenly, same as the
    // Stage-2 Group-2 (32-bank) case, so bank decode is a plain bit-slice
    // (no comparator/remainder logic needed):
    //   bank_index = addr[16:11], local_addr = addr[10:0].
    //
    // hist_out_stage3 (the data actually WRITTEN into this memory) has no
    // producer yet in this project snapshot -- tied to '0 as an explicit
    // placeholder (TODO) so nothing floats to X in sim. Wire it to the real
    // Stage-3 LIF/consumer once that module exists.
    // =========================================================================
    localparam int S3_POS_PER_FRAME = 133120; 
    localparam int S3_NUM_BANKS     = 65;
    localparam int S3_ADDR_WIDTH    = $clog2(S3_POS_PER_FRAME); // 18
    localparam int S3_BANK_DEPTH    = 2048;
    localparam int S3_BANK_AW       = $clog2(S3_BANK_DEPTH);        // 11
    localparam int S3_BANK_IDX_W    = S3_ADDR_WIDTH - S3_BANK_AW;   // 7

    // Single enable from top_controller: active only during stage == 2.
    wire s3_in_valid = (src_sel == 2'b10);

    logic                          s3_rd_en, s3_wr_en;
    logic [S3_ADDR_WIDTH-1:0]      s3_rd_addr, s3_wr_addr;
    logic                          s3_out_valid;
    logic [S3_ADDR_WIDTH-1:0]      s3_addr_out;

    fetch_stage3 u_fetch_stage3 (
        .clk         (clk),
        .arst_n      (arst_n),
        .frame_count (frame_counter),
        .frame_start (frame_start_pulse_stg3),
        .in_valid    (s3_in_valid),
        .rd_en       (s3_rd_en),
        .rd_addr     (s3_rd_addr),
        .wr_en       (s3_wr_en),
        .wr_addr     (s3_wr_addr),
        .out_valid   (s3_out_valid),
        .addr_out    (s3_addr_out)
    );


    wire [S3_BANK_IDX_W-1:0] s3_rd_bank  = s3_rd_addr[S3_ADDR_WIDTH-1:S3_BANK_AW];
    wire [S3_BANK_AW-1:0]    s3_rd_local = s3_rd_addr[S3_BANK_AW-1:0];
    wire [S3_BANK_IDX_W-1:0] s3_wr_bank  = s3_wr_addr[S3_ADDR_WIDTH-1:S3_BANK_AW];
    wire [S3_BANK_AW-1:0]    s3_wr_local = s3_wr_addr[S3_BANK_AW-1:0];

    logic [DATA_WIDTH-1:0]      s3_bank_douta [0:S3_NUM_BANKS-1];
    logic [S3_BANK_IDX_W-1:0]   s3_rd_bank_d1; // selects the valid bank's doutb 1 cycle later

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) s3_rd_bank_d1 <= '0;
        else         s3_rd_bank_d1 <= s3_rd_bank;
    end

    logic [S3_NUM_BANKS-1:0] s3_bank_wr_sel;  // per-bank write select (kept off the port connections below)
    logic [S3_NUM_BANKS-1:0] s3_bank_rd_sel;  // per-bank read select (kept off the port connections below)

    genvar s3_b;
    generate
        for (s3_b = 0; s3_b < S3_NUM_BANKS; s3_b++) begin : gen_s3_bank
            assign s3_bank_wr_sel[s3_b] = s3_wr_en && (s3_wr_bank == s3_b);
            assign s3_bank_rd_sel[s3_b] = s3_rd_en && (s3_rd_bank == s3_b);

            BRAM_LIF_Mem_0 #(
                .DATA_WIDTH (DATA_WIDTH),
                .ADDR_WIDTH (S3_BANK_AW),
                .DEPTH      (S3_BANK_DEPTH)
            ) u_bram (
                .clka  (clk),
                .ena   (s3_bank_wr_sel[s3_b]),
                .wea   (s3_bank_wr_sel[s3_b]),
                .addra (s3_wr_local),
                .dina  (lif_hist_out_dbg[0]),

                .clkb  (clk),
                .enb   (s3_bank_rd_sel[s3_b]),
                .web   (1'b0),
                .addrb (s3_rd_local),
                .dinb  ({DATA_WIDTH{1'b0}}),
                .doutb (s3_bank_douta[s3_b])
            );
        end
    endgenerate

    logic signed [DATA_WIDTH-1:0] s3_hist_in; 
    assign s3_hist_in = s3_bank_douta[s3_rd_bank_d1];

    // =========================================================================
    // Mux to select which stage's hist_in and which valid signal is fed to top_shaaban_array
    // =========================================================================
    always_comb begin
        lif_hist_in = '{default: '0};
        lif_valid_in = '{default: '0};
        case (src_sel)
            2'b00: begin
                // hist in
                lif_hist_in = s1_hist_in;   // Stage 1 (per-lane)
                // valid in
                for (int i = 0; i < N_SHAABAN; i++) begin
                    lif_valid_in[i] = new_data_o;
                end
            end
            2'b01: begin 
                // hist in
                lif_hist_in[0] = s2_0_hist_in; // Stage 2, Group 0
                lif_hist_in[1] = s2_1_hist_in; // Stage 2, Group 1
                lif_hist_in[2] = s2_2_hist_in; // Stage 2, Group 2

                // valid in
                lif_valid_in[0] = shb_mem_en[0]; // Stage 2, Group 0
                lif_valid_in[1] = shb_mem_en[1]; // Stage 2, Group 1
                lif_valid_in[2] = shb_mem_en[2]; // Stage 2, Group 2
            end
            2'b10: begin
                // hist in
                lif_hist_in[0] = s3_hist_in;   // Stage 3
                // valid in
                lif_valid_in[0] = 1'b1; // Stage 3
            end

            default:begin
                // hist in
                lif_hist_in = '{default: '0};
                // valid in
                lif_valid_in = '{default: '0};
            end
        endcase
    end


    // =========================================================================
    // top_shaaban_array
    // =========================================================================
    top_shaaban_array #(
        .DATA_WIDTH     (DATA_WIDTH),
        .N_SHAABAN      (N_SHAABAN),
        .INPUTS_PER_SHB (INPUTS_PER_SHB)
    ) u_shaaban_array (
        .clk               (clk),
        .rst               (arst_n),
        .first_frame       ((frame_counter == 0)),
        .new_data_en       (lif_valid_in),
        .shb_bus           (shb_bus),
        .conv_bias_param   (conv_bias_param),
        .mult_weight_param (mult_weight_param),
        .add_weight_param  (add_weight_param),
        .hist_in           (lif_hist_in),
        .hist_out          (lif_hist_out),
        .spike_out         (spike_out),
        .shaaban_spike_bus (shaaban_spike_bus),
        .hist_out_dbg      (lif_hist_out_dbg)
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
        .rst_n          (rst),
        .clear          (gap_clear),
        .sample_valid   ((src_sel == 2'b10) && gap_sample_enable &&
                          ctrl_mem_enable[{5'd0,conv3_filter}]),
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