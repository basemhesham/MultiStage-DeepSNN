`timescale 1ns / 1ps

module top_pixel_source_mapper #(
    parameter int PIXEL_W        = 18,
    parameter int FRAC_BITS      = 9,
    parameter int FRAME_NO       = 6,
    parameter int FRAME_NO_WIDTH = 3
)(
    input  logic                         clk,
    input  logic                         arst_n,
    input  logic [1:0]                   src_sel,
    input  logic [FRAME_NO_WIDTH-1:0]    frame,
    input  logic [(100*PIXEL_W)-1:0]     pixel_mem_data,   // 100 x 18-bit inputs
    input  logic [3199:0]                spike_mem_data,
    output logic signed [PIXEL_W-1:0]    pixels_mapped [0:11][0:31][0:8]
);

    // -------------------------------------------------------------------------
    // Unpack 100 inputs from flat bus
    // -------------------------------------------------------------------------
    logic signed [PIXEL_W-1:0] in_mem [0:99];

    genvar m;
    generate
        for (m = 0; m < 100; m++) begin : gen_inmem
            assign in_mem[m] = $signed(pixel_mem_data[m*PIXEL_W +: PIXEL_W]);
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Stage 1 intermediate
    // -------------------------------------------------------------------------
    logic signed [PIXEL_W-1:0] pixels_s1 [0:11][0:31][0:8];

    // -------------------------------------------------------------------------
    // Stage 1 mapping function
    //
    // Design:
    //   - 4 windows of 25 inputs each  (100 inputs total)
    //   - 12 groups total = 4 windows x 3 groups-per-window. Groups 3k,
    //     3k+1, 3k+2 all carry the SAME window-k pixel data; they exist
    //     as separate groups purely so the OUTER system can assign a
    //     different filter-weight set to each of the 3 groups for the
    //     same input window.
    //   - WITHIN a group, the 32 channels cycle through the 3 blocks of
    //     the 5x5-via-3x3x3 decomposition: BLOCK = cp1 % 3
    //       BLOCK 0 (cp1 = 0,3,6,...30) : taps[0:8] -> in[w*25+0 : w*25+8]
    //       BLOCK 1 (cp1 = 1,4,7,...31) : taps[0:8] -> in[w*25+9 : w*25+17]
    //       BLOCK 2 (cp1 = 2,5,8,...29) : taps[0:6] -> in[w*25+18: w*25+24]
    //                                     taps[7:8] -> zero (27-mul padding)
    //   - Channels with the same BLOCK (e.g. cp1=0,3,6,...) all receive
    //     identical tap data; differentiation is by external filter weight.
    //
    // Channel rotation reference (informational only):
    //   Separately from the above tap-cycling, there is also a channel
    //   relabeling contract used by the OUTER system to know which
    //   physical filter channel corresponds to port position cp1 in each
    //   group (kept from the original stage1_stream_index logic). This
    //   rotation does NOT affect the pixels_mapped values computed above:
    //     BLOCK_G = gp1 % 3 (group's position within its triplet: 0,1,2)
    //     BLOCK_G 0: cp1 -> channel (BLOCK_G*32 + cp1)                 [identity]
    //     BLOCK_G 1: cp1 -> channel (BLOCK_G*32 + cp1+1) for cp1 < 30
    //                cp1==30 -> channel (BLOCK_G*32 + 0)
    //                cp1==31 -> channel (BLOCK_G*32 + 31)
    //     BLOCK_G 2: cp1 -> channel (BLOCK_G*32 + cp1+2) for cp1 < 30
    //                cp1>=30 -> channel (BLOCK_G*32 + (cp1-30))
    //   (function stage1_channel_rotation below implements this purely
    //    for documentation / simulation tracing; it is unused in the
    //    pixels_mapped assignment)
    // -------------------------------------------------------------------------

    function automatic int stage1_channel_rotation(
        input int block,
        input int lane
    );
        begin
            case (block % 3)
                0: stage1_channel_rotation = (block * 32) + lane;
                1: stage1_channel_rotation = (block * 32) +
                                         ((lane < 30) ? lane + 1 :
                                          (lane == 30) ? 0 : 31);
                default:
                   stage1_channel_rotation = (block * 32) +
                                         ((lane < 30) ? lane + 2 : lane - 30);
            endcase
        end
    endfunction

    genvar gp1, cp1, tp1;
    generate
        for (gp1 = 0; gp1 < 12; gp1++) begin : gen_ps1_group
            for (cp1 = 0; cp1 < 32; cp1++) begin : gen_ps1_channel
                for (tp1 = 0; tp1 < 9; tp1++) begin : gen_ps1_tap

                    // Which of the 4 windows does this group belong to?
                    localparam int WINDOW     = gp1 / 3;
                    // Position of this group within its triplet (0,1,2)
                    localparam int BLOCK_G    = gp1 % 3;
                    // Base input index for this window
                    localparam int WIN_OFFSET = WINDOW * 25;

                    // Global channel index after rotation — ensures the
                    // "continuation" channels (32,63,64,65...) land at the
                    // END of each group rather than the beginning, preserving
                    // correct block cycling continuity across group boundaries
                    localparam int GLOBAL_CH  =
                        (BLOCK_G == 0) ? (BLOCK_G * 32) + cp1 :
                        (BLOCK_G == 1) ? (BLOCK_G * 32) + ((cp1 < 30) ? cp1 + 1 :
                                                            (cp1 == 30) ? 0 : 31) :
                                         (BLOCK_G * 32) + ((cp1 < 30) ? cp1 + 2 :
                                                            cp1 - 30);

                    // Which 3x3 block this channel computes, derived from
                    // the rotated global channel index
                    localparam int BLOCK      = GLOBAL_CH % 3;
                    // Base tap offset within the window for this block
                    localparam int TAP_OFFSET = BLOCK * 9;
                    // Absolute input index
                    localparam int IN_IDX     = WIN_OFFSET + TAP_OFFSET + tp1;

                    if (BLOCK == 2 && tp1 >= 7) begin
                        // Last 2 taps of block 2 are zero-padded
                        assign pixels_s1[gp1][cp1][tp1] = '0;
                    end else begin
                        assign pixels_s1[gp1][cp1][tp1] = in_mem[IN_IDX];
                    end

                end
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Stage 2 — spike frame windows (unchanged)
    // -------------------------------------------------------------------------
    logic fil_in [31:0][39:0];
    logic conv_windows [31:0][11:0][8:0];
    logic signed [PIXEL_W-1:0] pixels_s2 [0:11][0:31][0:8];

    mem_mapping #(
        .FRAME_NO       (FRAME_NO),
        .FRAME_NO_WIDTH (FRAME_NO_WIDTH),
        .MEM_WORD       (3200)
    ) u_mem_mapping (
        .clk    (clk),
        .arst_n (arst_n),
        .frame  (frame),
        .mem    (spike_mem_data),
        .fil_in (fil_in)
    );

    genvar fi;
    generate
        for (fi = 0; fi < 32; fi++) begin : gen_frame_mapping
            frame_input_mapping u_frame_map (
                .frame (frame[2:0]),
                .in    (fil_in[fi]),
                .conv  (conv_windows[fi])
            );
        end
    endgenerate

    genvar gp2, cp2, tp2;
    generate
        for (gp2 = 0; gp2 < 12; gp2++) begin : gen_ps2_group
            for (cp2 = 0; cp2 < 32; cp2++) begin : gen_ps2_channel
                for (tp2 = 0; tp2 < 9; tp2++) begin : gen_ps2_tap
                    assign pixels_s2[gp2][cp2][tp2] =
                        {{(PIXEL_W-FRAC_BITS-1){1'b0}},
                          conv_windows[cp2][gp2][tp2],
                          {FRAC_BITS{1'b0}}};
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Stage 3 — binary mux stage (unchanged)
    // -------------------------------------------------------------------------
    logic stage3_mem [0:1023];
    logic stage3_windows [0:8][0:3][0:63];
    logic signed [PIXEL_W-1:0] pixels_s3 [0:11][0:31][0:8];

    genvar sm;
    generate
        for (sm = 0; sm < 1024; sm++) begin : gen_stage3_mem_unpack
            assign stage3_mem[sm] = spike_mem_data[sm];
        end
    endgenerate

    bin_muxing_stage2 u_stage3_bin_mux (
        .din  (stage3_mem),
        .dout (stage3_windows)
    );

    genvar win3, ch3, tap3;
    generate
        for (win3 = 0; win3 < 4; win3++) begin : gen_ps3_window
            for (ch3 = 0; ch3 < 32; ch3++) begin : gen_ps3_channel
                for (tap3 = 0; tap3 < 9; tap3++) begin : gen_ps3_tap
                    assign pixels_s3[(win3 * 2)    ][ch3][tap3] =
                        {{(PIXEL_W-FRAC_BITS-1){1'b0}},
                          stage3_windows[tap3][win3][ch3],
                          {FRAC_BITS{1'b0}}};

                    assign pixels_s3[(win3 * 2) + 1][ch3][tap3] =
                        {{(PIXEL_W-FRAC_BITS-1){1'b0}},
                          stage3_windows[tap3][win3][ch3 + 32],
                          {FRAC_BITS{1'b0}}};
                end
            end
        end
    endgenerate

    genvar zrow3, zch3, ztap3;
    generate
        for (zrow3 = 8; zrow3 < 12; zrow3++) begin : gen_ps3_zero_row
            for (zch3 = 0; zch3 < 32; zch3++) begin : gen_ps3_zero_channel
                for (ztap3 = 0; ztap3 < 9; ztap3++) begin : gen_ps3_zero_tap
                    assign pixels_s3[zrow3][zch3][ztap3] = '0;
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Output mux — select active stage
    // -------------------------------------------------------------------------
    genvar gm, cm, tm;
    generate
        for (gm = 0; gm < 12; gm++) begin : gen_pmux_group
            for (cm = 0; cm < 32; cm++) begin : gen_pmux_channel
                for (tm = 0; tm < 9; tm++) begin : gen_pmux_tap
                    always_comb begin
                        case (src_sel)
                            2'b00:   pixels_mapped[gm][cm][tm] = pixels_s1[gm][cm][tm];
                            2'b01:   pixels_mapped[gm][cm][tm] = pixels_s2[gm][cm][tm];
                            2'b10:   pixels_mapped[gm][cm][tm] = pixels_s3[gm][cm][tm];
                            default: pixels_mapped[gm][cm][tm] = pixels_s1[gm][cm][tm];
                        endcase
                    end
                end
            end
        end
    endgenerate

endmodule