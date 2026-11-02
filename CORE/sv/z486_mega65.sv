// z486 PC for MEGA65: z486_MiSTer's system.sv and SDRAM backend, wired for the M2M shell.
//
// This replaces the parts of z486_mister.sv (the MiSTer top level) that are not MiSTer-only:
//   * system.sv (CPU, chipset, VGA/ET4000, OPL3/SB, IDE, floppy) with the same parameters
//   * split_sdram_backend.sv on the R6's SDRAM (IS42S16320F, 64 MB: sdram_size 2'd2); the R6
//     has DQM pins, so HAS_DQM = 1 (MiSTer's modules have none)
//   * a 256 KB second-level cache between the CPU's memory port and the SDRAM (guest_l2.sv,
//     after MegaMac's), which MiSTer has not
//   * the SVGA framebuffer descriptor (z486_mister.sv, MISTER_FB / MISTER_FB_PALETTE)
//   * the audio mix (SB Pro mixer volumes, OPL, speaker; no CMS, CD-DA or MT-32)
//   * the video stream for M2M: positive syncs (video_cleaner) and separate H/V blanks that
//     cover the syncs; system.sv only gives a display enable
//
// The ddram_* port is MiSTer's DDR3 port (64-bit words, clk_sys): the boot image and the SVGA
// framebuffer. mega65.vhd maps it into HyperRAM. fb_base_o is still a DDR3 address.
//
// The PS/2 keyboard and mouse lines, the game port's joystick and the mgmt bus of ide.v /
// floppy.v come from mega65.vhd.

`default_nettype none

module z486_mega65 #(
    parameter int CLK_HZ = 64_000_000
) (
    input  wire        clk_sys,
    input  wire        clk_audio,          // 24.576 MHz (OPL3, SB)
    input  wire        clk_sdram,          // clk_sys's frequency, the SDRAM's phase (clk.vhd)
    input  wire        reset,              // asynchronous to clk_sys

    // Video (clk_sys, CE per pixel)
    output wire        video_ce,
    output wire  [7:0] video_r,
    output wire  [7:0] video_g,
    output wire  [7:0] video_b,
    output wire        video_hs,           // active high
    output wire        video_vs,           // active high
    output wire        video_hblank,       // covers video_hs
    output wire        video_vblank,       // covers video_vs

    // SVGA framebuffer descriptor and palette (clk_sys, MiSTer's FB_* semantics)
    output reg         fb_en,
    output reg  [11:0] fb_width,
    output reg  [11:0] fb_height,
    output reg   [4:0] fb_format,
    output reg  [31:0] fb_base,            // DDR3 byte address
    output reg  [13:0] fb_stride,
    output wire  [7:0] fb_pal_a,
    output wire [23:0] fb_pal_d,
    output wire        fb_pal_wr,

    // MiSTer DDR3 port (clk_sys): boot image and SVGA framebuffer
    input  wire        ddram_busy,
    output wire  [7:0] ddram_burstcnt,
    output wire [28:0] ddram_addr,
    input  wire [63:0] ddram_dout,
    input  wire        ddram_dout_ready,
    output wire        ddram_rd,
    output wire [63:0] ddram_din,
    output wire  [7:0] ddram_be,
    output wire        ddram_we,

    // SDRAM (R6: IS42S16320F)
    output wire        sdram_clk,
    output wire        sdram_cke,
    output wire [12:0] sdram_a,
    output wire  [1:0] sdram_ba,
    inout  wire [15:0] sdram_dq,
    output wire        sdram_dqml,
    output wire        sdram_dqmh,
    output wire        sdram_ncs,
    output wire        sdram_ncas,
    output wire        sdram_nras,
    output wire        sdram_nwe,

    // Audio (clk_audio)
    output reg  [15:0] audio_l,
    output reg  [15:0] audio_r,

    // Floppy / IDE management bus (clk_sys), MiSTer's HPS side of ide.v and floppy.v
    input  wire [15:0] mgmt_address,
    input  wire        mgmt_read,
    output wire [15:0] mgmt_readdata,
    input  wire        mgmt_write,
    input  wire [15:0] mgmt_writedata,
    output wire  [1:0] fdd_request,
    output wire  [2:0] ide0_request,
    output wire  [2:0] ide1_request,

    // PS/2 lines (clk_sys): *_in = the device's lines, *_out = the controller's
    input  wire        ps2_kbd_clk_in,
    input  wire        ps2_kbd_data_in,
    output wire        ps2_kbd_clk_out,
    output wire        ps2_kbd_data_out,
    input  wire        ps2_mouse_clk_in,
    input  wire        ps2_mouse_data_in,
    output wire        ps2_mouse_clk_out,
    output wire        ps2_mouse_data_out,

    // The game port (201h): joystick 1, digital, active high (MiSTer's layout: 0 right, 1 left,
    // 2 down, 3 up, 4..7 buttons 1..4); a 4-button joystick, joystick 2 absent
    input  wire  [7:0] joy_dig,

    input  wire        cpu_slow,           // the CPU at 33 MHz (z486's throttle), else full speed
    input  wire  [1:0] ram_size,           // 0/1/2/3 = 16/32/64/128 MB; the R6 has 64 MB

    // The L2 cache (guest_l2.sv; clk_sys): on (a 0 -> 1 empties it first), and its line fills
    // from the cache and from the SDRAM
    input  wire        l2_enable,
    input  wire        cache_off,          // z486's L1 caches off (every access uncached)
    input  wire        sb_take_starved,    // a new Sound Blaster DMA command takes over a starved
                                           // transfer at once (sound_dsp.v, z486_sources.py)
    output wire [31:0] l2_hits,
    output wire [31:0] l2_misses,

    // Debug (clk_sys): system.sv's boot and POST state, the CPU's CS:EIP, and the bytes of its
    // debug port (the BIOS's port 0x402 and the stall watchdog's messages)
    output wire  [2:0] dbg_boot_stage,     // 1 copying, 2-3 reading HyperRAM, 4 copied, 5 running
    output wire        dbg_bios_loaded,
    output wire        dbg_vga_sig_checked,
    output wire        dbg_vga_sig_bad,
    output wire        dbg_first_instr,    // the CPU executed F000:FFF0
    output wire  [7:0] dbg_post_code,      // the last write to port 0x80 or 0x190
    output wire        dbg_post_write,
    output wire        dbg_cpu_pe,
    output wire [15:0] dbg_cpu_cs,
    output wire [31:0] dbg_cpu_eip,
    output wire  [7:0] dbg_log_byte,
    output wire        dbg_log_we,
    output wire        dbg_mem_busy,       // the SDRAM controller (initialization, refresh)
    output wire [23:0] dbg_io_rd,          // the last I/O read: port, byte (z486_sources.py)
    output wire [23:0] dbg_io_wr,          // the last I/O write: port, byte
    output wire  [1:0] dbg_sb_req,         // the Sound Blaster's DMA requests: 16-bit, 8-bit
    output wire        dbg_sb_irq,         // the Sound Blaster's IRQ
    output wire        dbg_io_rd_stb,      // dbg_io_rd / dbg_io_wr hold a new access
    output wire        dbg_io_wr_stb,
    output wire        dbg_sb_cmd_wait,    // the Sound Blaster holds a new DMA command back
    output wire        dbg_sb_smp_stb,     // the Sound Blaster took a DMA output sample:
    output wire [15:0] dbg_sb_smp_dif,     // its distance from the one before (left channel),
    output wire [15:0] dbg_sb_smp_pos,     // its index in the DSP's block

    // CD audio (pc_cdrom.vhd's cd_audio, clk_sys, 44.1 kHz): mixed with the SB Pro mixer's CD
    // volume, as z486_mister.sv mixes cdda.v's
    input  wire [15:0] cd_l,
    input  wire [15:0] cd_r
);

// z486_mister.sv's build: 8 KB + 8 KB L1, critical-word-first line reads, x87 on, no CMS
localparam DCACHE_SET_BITS  = 7;
localparam DCACHE_LINE_WRAP = 1'b1;
localparam ICACHE_SET_BITS  = 7;
localparam ENABLE_X87       = 1'b1;
localparam ENABLE_CMS       = 1'b0;

// ------------------------------------------------------------------------------------------
// Reset: the input, plus the keyboard controller's 0xFE reset (MiSTer routes it through the
// HPS), synchronized to clk_sys
// ------------------------------------------------------------------------------------------

wire       software_reset;
reg  [3:0] soft_reset_cnt = 4'd0;
(* ASYNC_REG = "TRUE" *) reg [1:0] reset_meta = 2'b11;
reg  [2:0] reset_sync = 3'b111;

always @(posedge clk_sys) begin
    reset_meta <= {reset_meta[0], reset};
    if (reset_meta[1])
        soft_reset_cnt <= 4'd0;
    else if (software_reset)
        soft_reset_cnt <= 4'hF;
    else if (|soft_reset_cnt)
        soft_reset_cnt <= soft_reset_cnt - 4'd1;
    reset_sync <= {reset_sync[1:0], reset_meta[1] | (|soft_reset_cnt)};
end

wire core_reset = reset_sync[2];

// ------------------------------------------------------------------------------------------
// System RAM: the SDRAM backend
// ------------------------------------------------------------------------------------------

wire        guest_mem_busy;
// system.sv's memory port (the CPU's), before the L2 cache
wire [31:0] cpu_mem0_addr;
wire [31:0] cpu_mem0_din;
wire [31:0] cpu_mem0_dout;
wire        cpu_mem0_resp_valid;
wire  [3:0] cpu_mem0_be;
wire  [7:0] cpu_mem0_burstcount;
wire        cpu_mem0_line_read;
wire        cpu_mem0_ready;
wire        cpu_mem0_valid;
wire        cpu_mem0_write;
// the SDRAM's port 0, after the L2 cache
wire [31:0] guest_mem0_addr;
wire [31:0] guest_mem0_din;
wire [31:0] guest_mem0_dout;
wire        guest_mem0_resp_valid;
wire  [3:0] guest_mem0_be;
wire  [7:0] guest_mem0_burstcount;
wire        guest_mem0_line_read;
wire        guest_mem0_ready;
wire        guest_mem0_valid;
wire        guest_mem0_write;
wire [31:0] guest_mem1_addr;
wire [31:0] guest_mem1_din;
wire [31:0] guest_mem1_dout;
wire        guest_mem1_resp_valid;
wire  [3:0] guest_mem1_be;
wire  [7:0] guest_mem1_burstcount;
wire        guest_mem1_ready;
wire        guest_mem1_valid;
wire        guest_mem1_write;

// The L2 cache between the CPU's port and the SDRAM's port 0; DMA writes (port 1) drop lines
guest_l2 #(
    .IDX_BITS(14)                          // 256 KB, 72 block RAM tiles
) l2 (
    .clk          (clk_sys),
    .reset        (core_reset),
    .enable       (l2_enable),
    .u_valid      (cpu_mem0_valid),
    .u_ready      (cpu_mem0_ready),
    .u_write      (cpu_mem0_write),
    .u_addr       (cpu_mem0_addr),
    .u_din        (cpu_mem0_din),
    .u_be         (cpu_mem0_be),
    .u_burstcount (cpu_mem0_burstcount),
    .u_line_read  (cpu_mem0_line_read),
    .u_dout       (cpu_mem0_dout),
    .u_resp_valid (cpu_mem0_resp_valid),
    .d_valid      (guest_mem0_valid),
    .d_ready      (guest_mem0_ready),
    .d_write      (guest_mem0_write),
    .d_addr       (guest_mem0_addr),
    .d_din        (guest_mem0_din),
    .d_be         (guest_mem0_be),
    .d_burstcount (guest_mem0_burstcount),
    .d_line_read  (guest_mem0_line_read),
    .d_dout       (guest_mem0_dout),
    .d_resp_valid (guest_mem0_resp_valid),
    .dma_we       (guest_mem1_valid && guest_mem1_ready && guest_mem1_write),
    .dma_addr     (guest_mem1_addr),
    .hits         (l2_hits),
    .misses       (l2_misses)
);

split_sdram_backend #(
    .FREQ(CLK_HZ),
    .HAS_DQM(1'b1),
    .FAST_GRADE(1'b1)
) guest_memory (
    .clk(clk_sys),
    .reset(core_reset),
    .refresh_allowed(1'b1),
    .sdram_size(ram_size),
    .busy(guest_mem_busy),
    .mem0_valid(guest_mem0_valid),
    .mem0_ready(guest_mem0_ready),
    .mem0_write(guest_mem0_write),
    .mem0_addr(guest_mem0_addr),
    .mem0_din(guest_mem0_din),
    .mem0_dout(guest_mem0_dout),
    .mem0_resp_valid(guest_mem0_resp_valid),
    .mem0_be(guest_mem0_be),
    .mem0_burstcount(guest_mem0_burstcount),
    .mem0_wrap(guest_mem0_line_read),
    .mem1_valid(guest_mem1_valid),
    .mem1_ready(guest_mem1_ready),
    .mem1_write(guest_mem1_write),
    .mem1_addr(guest_mem1_addr),
    .mem1_din(guest_mem1_din),
    .mem1_dout(guest_mem1_dout),
    .mem1_resp_valid(guest_mem1_resp_valid),
    .mem1_be(guest_mem1_be),
    .mem1_burstcount(guest_mem1_burstcount),
    .sdram_dq(sdram_dq),
    .sdram_a(sdram_a),
    .sdram_ba(sdram_ba),
    .sdram_dqm({sdram_dqmh, sdram_dqml}),
    .sdram_nwe(sdram_nwe),
    .sdram_nras(sdram_nras),
    .sdram_ncas(sdram_ncas),
    .sdram_ncs(sdram_ncs),
    .sdram_cke(sdram_cke)
);

// The SDRAM clock, forwarded through an ODDR: clk_sdram is clk_sys at 292.5 degrees, the
// middle of the window measured on an R6 (clk.vhd; MiSTer's PLL uses 180 at 85 MHz), plus a fine
// phase QNICE can set to measure it again.
ODDR #(
    .DDR_CLK_EDGE("SAME_EDGE"),
    .INIT(1'b0),
    .SRTYPE("SYNC")
) sdram_clk_oddr (
    .Q(sdram_clk),
    .C(clk_sdram),
    .CE(1'b1),
    .D1(1'b1),
    .D2(1'b0),
    .R(1'b0),
    .S(1'b0)
);

assign dbg_mem_busy = guest_mem_busy;

// ------------------------------------------------------------------------------------------
// The PC
// ------------------------------------------------------------------------------------------

wire        core_ce_pixel;
wire        core_de;
wire        core_hs;
wire        core_vs;
wire  [7:0] core_r;
wire  [7:0] core_g;
wire  [7:0] core_b;

wire [19:0] vga_start_addr;
wire  [8:0] vga_width;
wire [10:0] vga_height;
wire  [8:0] vga_stride;
wire  [3:0] vga_flags;
wire        vga_off;
wire  [7:0] vga_pal_a;
wire [17:0] vga_pal_d;
wire        vga_pal_we;

wire  [8:0] sample_cms_l;
wire  [8:0] sample_cms_r;
wire [15:0] sample_sb_l;
wire [15:0] sample_sb_r;
wire [15:0] sample_opl_l;
wire [15:0] sample_opl_r;
wire        speaker_out;
wire        sbp;
wire  [4:0] vol_master_l;
wire  [4:0] vol_master_r;
wire  [4:0] vol_voice_l;
wire  [4:0] vol_voice_r;
wire  [4:0] vol_cd_l;
wire  [4:0] vol_cd_r;
wire  [4:0] vol_midi_l;
wire  [4:0] vol_midi_r;
wire  [4:0] vol_line_l;
wire  [4:0] vol_line_r;
wire  [1:0] vol_spk;
wire  [4:0] vol_en;

wire        video_f60 = 1'b1;           // MiSTer's default: VGA timing forced to 60 Hz

system #(
    .SYS_FREQ(CLK_HZ),
    .DCACHE_SET_BITS(DCACHE_SET_BITS),
    .DCACHE_LINE_WRAP(DCACHE_LINE_WRAP),
    .ICACHE_SET_BITS(ICACHE_SET_BITS),
    .ENABLE_X87(ENABLE_X87),
    .ENABLE_CMS(ENABLE_CMS),
    .ENABLE_SHARED_MAILBOX(1'b0),      // MiSTer's live HPS mailbox (shared folders)
    .ENABLE_VOODOO(1'b0)
) core (
    .clk_sys             (clk_sys),
    .reset               (core_reset),
    .hps_apply_reset     (1'b0),
    .software_reset      (software_reset),
    .clock_rate          (28'(CLK_HZ)),

    .fdd_request         (fdd_request),
    .ide0_request        (ide0_request),
    .ide1_request        (ide1_request),
    .floppy_wp           (2'b00),
    .joystick_dis        (2'b10),          // joystick 2 absent: its axes and buttons read 1
    .joystick_dig_1      ({6'd0, joy_dig}),
    .joystick_dig_2      (14'd0),
    .joystick_ana_1      (16'd0),          // no stick movement: the axes follow the directions
    .joystick_ana_2      (16'd0),
    .joystick_mode       (3'd1),           // 4 buttons: buttons 3 and 4 are joystick 1's
    .joystick_timed      (2'd0),

    .mgmt_address        (mgmt_address),
    .mgmt_read           (mgmt_read),
    .mgmt_readdata       (mgmt_readdata),
    .mgmt_write          (mgmt_write),
    .mgmt_writedata      (mgmt_writedata),

    .ext_mem_busy        (guest_mem_busy),
    .ext_mem0_addr       (cpu_mem0_addr),
    .ext_mem0_din        (cpu_mem0_din),
    .ext_mem0_dout       (cpu_mem0_dout),
    .ext_mem0_resp_valid (cpu_mem0_resp_valid),
    .ext_mem0_line_dout  (128'd0),
    .ext_mem0_line_resp_valid(1'b0),
    .ext_mem0_be         (cpu_mem0_be),
    .ext_mem0_burstcount (cpu_mem0_burstcount),
    .ext_mem0_line_read  (cpu_mem0_line_read),
    .ext_mem0_ready      (cpu_mem0_ready),
    .ext_mem0_valid      (cpu_mem0_valid),
    .ext_mem0_write      (cpu_mem0_write),
    .ext_mem1_addr       (guest_mem1_addr),
    .ext_mem1_din        (guest_mem1_din),
    .ext_mem1_dout       (guest_mem1_dout),
    .ext_mem1_resp_valid (guest_mem1_resp_valid),
    .ext_mem1_be         (guest_mem1_be),
    .ext_mem1_burstcount (guest_mem1_burstcount),
    .ext_mem1_ready      (guest_mem1_ready),
    .ext_mem1_valid      (guest_mem1_valid),
    .ext_mem1_write      (guest_mem1_write),

    .ddram_busy          (ddram_busy),
    .ddram_burstcnt      (ddram_burstcnt),
    .ddram_addr          (ddram_addr),
    .ddram_dout          (ddram_dout),
    .ddram_dout_ready    (ddram_dout_ready),
    .ddram_rd            (ddram_rd),
    .ddram_din           (ddram_din),
    .ddram_be            (ddram_be),
    .ddram_we            (ddram_we),

    .sd_clk              (),
    .sd_cmd              (),
    .sd_dat              (),

    .ioctl_download      (1'b0),           // the boot image comes through ddram_*
    .ioctl_index         (16'd0),
    .ioctl_wr            (1'b0),
    .ioctl_addr          (27'd0),
    .ioctl_dout          (16'd0),
    .ioctl_wait          (),
    .img_mounted         (1'b0),
    .img_readonly        (1'b0),
    .img_size            (64'd0),
    .img_lba             (),
    .img_blk_cnt         (),
    .img_rd              (),
    .img_wr              (),
    .img_ack             (1'b0),
    .img_buff_addr       (),
    .img_buff_din        (16'd0),
    .img_buff_dout       (),
    .img_buff_wr         (),

    .ps2_mouseclk_in     (ps2_mouse_clk_in),
    .ps2_mousedat_in     (ps2_mouse_data_in),
    .ps2_mouseclk_out    (ps2_mouse_clk_out),
    .ps2_mousedat_out    (ps2_mouse_data_out),
    .ps2_kbclk_in        (ps2_kbd_clk_in),
    .ps2_kbdat_in        (ps2_kbd_data_in),
    .ps2_kbclk_out       (ps2_kbd_clk_out),
    .ps2_kbdat_out       (ps2_kbd_data_out),
    .mouse_data          (8'd0),
    .mouse_data_valid    (1'b0),
    .mouse_host_cmd      (),
    .mouse_host_cmd_clear(1'b0),
    .zsst_host_req_valid (),
    .zsst_host_req_ready (1'b0),
    .zsst_host_address   (),
    .zsst_host_writedata (),
    .zsst_host_byteenable(),
    .zsst_host_write     (),
    .zsst_host_rsp_valid (1'b0),
    .zsst_host_rsp_ready (),
    .zsst_host_readdata  (32'd0),
    .zsst_host_error     (1'b0),
    .zsst_memory_enable  (),
    .zsst_init_enable    (),

    .dbg_uart_byte       (dbg_log_byte),
    .dbg_uart_we         (dbg_log_we),
    .mpu_uart_tx         (),
    .dbg_sd_avm_address  (),
    .dbg_sd_avm_writedata(),
    .dbg_sd_avm_write    (),
    .dbg_sd_avm_wait     (),
    .dbg_sd_avm_accept   (),
    .dbg_mm_addr         (),
    .dbg_mm_din          (),
    .dbg_mm_dout         (),
    .dbg_mm_valid        (),
    .dbg_mm_write        (),
    .dbg_mm_ready        (),
    .dbg_mm_resp_valid   (),
    .dbg_mem_address     (),
    .dbg_mem_din         (),
    .dbg_mem_dout        (),
    .dbg_mem_valid       (),
    .dbg_mem_we          (),
    .dbg_mem_ready       (),
    .dbg_mem_resp_valid  (),
    .dbg_avm_address     (),
    .dbg_avm_readdata    (),
    .dbg_avm_ready       (),
    .dbg_avm_resp_valid  (),
    .dbg_cpu_din_z       (),

    .bootcfg             (6'd0),
    .ram_size            (ram_size),
    .uma_ram             (1'b0),
    .cpu_speed_osd       (cpu_slow ? 3'd1 : 3'd0), // OSD "56" = 33 (z486_sources.py), or full
    .fast_off            (1'b0),
    .cache_off           (cache_off),
    .x87_off             (1'b0),
    .syscfg              (),

    .video_ce            (core_ce_pixel),
    .video_blank_n       (core_de),
    .video_hsync         (core_hs),
    .video_vsync         (core_vs),
    .video_r             (core_r),
    .video_g             (core_g),
    .video_b             (core_b),
    .video_f60           (video_f60),
    .video_border        (1'b0),
    .video_scanline_req  (1'b0),
    .video_scanline_ready(),
    .video_scanline_frame_start(1'b0),
    .video_scanline_y    (11'd0),
    .video_scanline_width(),
    .video_scanline_height(),
    .video_native_frames (),
    .video_scanline_done (),

    .video_start_addr    (vga_start_addr),
    .video_width         (vga_width),
    .video_height        (vga_height),
    .video_stride        (vga_stride),
    .video_flags         (vga_flags),
    .video_off           (vga_off),
    .video_pal_a         (vga_pal_a),
    .video_pal_d         (vga_pal_d),
    .video_pal_we        (vga_pal_we),

    .clk_audio           (clk_audio),
    .sample_cms_l        (sample_cms_l),
    .sample_cms_r        (sample_cms_r),
    .sample_sb_l         (sample_sb_l),
    .sample_sb_r         (sample_sb_r),
    .sample_opl_l        (sample_opl_l),
    .sample_opl_r        (sample_opl_r),
    .sound_fm_mode       (1'b1),           // OPL3
    .sound_cms_en        (1'b0),
    .speaker_out         (speaker_out),
    .sbp                 (sbp),
    .vol_master_l        (vol_master_l),
    .vol_master_r        (vol_master_r),
    .vol_voice_l         (vol_voice_l),
    .vol_voice_r         (vol_voice_r),
    .vol_cd_l            (vol_cd_l),
    .vol_cd_r            (vol_cd_r),
    .vol_midi_l          (vol_midi_l),
    .vol_midi_r          (vol_midi_r),
    .vol_line_l          (vol_line_l),
    .vol_line_r          (vol_line_r),
    .vol_spk             (vol_spk),
    .vol_en              (vol_en),

    .debug_boot_stage    (dbg_boot_stage),
    .debug_sd_error      (),
    .debug_bios_loaded   (dbg_bios_loaded),
    .debug_vga_bios_sig_bad(dbg_vga_sig_bad),
    .debug_vga_bios_sig_checked(dbg_vga_sig_checked),
    .debug_first_instruction(dbg_first_instr),
    .debug_post_code     (dbg_post_code),
    .debug_post_write    (dbg_post_write),

    .cpu_pe              (dbg_cpu_pe),
    .cpu_vm              (),
    .cpu_cs              (dbg_cpu_cs),
    .cpu_eip             (dbg_cpu_eip),
    .cpu_cs_base         (),
    .dbg_io_rd           (dbg_io_rd),
    .dbg_io_wr           (dbg_io_wr),
    .dbg_sb_req          (dbg_sb_req),
    .dbg_sb_irq          (dbg_sb_irq),
    .dbg_io_rd_stb       (dbg_io_rd_stb),
    .dbg_io_wr_stb       (dbg_io_wr_stb),
    .dbg_sb_cmd_wait     (dbg_sb_cmd_wait),
    .sb_take_starved     (sb_take_starved),
    .dbg_sb_smp_stb      (dbg_sb_smp_stb),
    .dbg_sb_smp_dif      (dbg_sb_smp_dif),
    .dbg_sb_smp_pos      (dbg_sb_smp_pos)
);

// ------------------------------------------------------------------------------------------
// Video: system.sv gives a display enable; M2M wants active-high syncs and H/V blanks that
// cover them. A line without any display enable is a vertical-blank line (latched at the
// line's horizontal sync); video_cleaner turns the syncs positive and ORs them into the blanks.
// ------------------------------------------------------------------------------------------

wire core_hs_pos;                          // VGA modes differ in sync polarity
reg  core_hs_pos_d;
reg  line_had_de;
reg  core_vblank;

s_fix hs_polarity (
    .clk     (clk_sys),
    .sync_in (core_hs),
    .sync_out(core_hs_pos)
);

always @(posedge clk_sys) begin
    core_hs_pos_d <= core_hs_pos;
    if (core_de) begin
        line_had_de <= 1'b1;
        core_vblank <= 1'b0;
    end else if (core_hs_pos && !core_hs_pos_d) begin
        core_vblank <= !line_had_de;
        line_had_de <= 1'b0;
    end
end

video_cleaner video_cleaner (
    .clk_vid    (clk_sys),
    .ce_pix     (core_ce_pixel),
    .R          (core_r),
    .G          (core_g),
    .B          (core_b),
    .HSync      (core_hs),
    .VSync      (core_vs),
    .HBlank     (~core_de),
    .VBlank     (core_vblank),
    .DE_in      (core_de),
    .interlace  (1'b0),
    .f1         (1'b0),
    .VGA_R      (video_r),
    .VGA_G      (video_g),
    .VGA_B      (video_b),
    .VGA_VS     (video_vs),
    .VGA_HS     (video_hs),
    .VGA_DE     (),
    .HBlank_out (video_hblank),
    .VBlank_out (video_vblank),
    .DE_out     ()
);

assign video_ce = core_ce_pixel;

// ------------------------------------------------------------------------------------------
// SVGA framebuffer descriptor (z486_mister.sv, MISTER_FB): ET4000 linear hi-colour modes set
// vga_flags[1:0] != 0 with PELWIDTH (vga_flags[2]) = 0; the scaler then reads the pixels from
// the framebuffer instead of the VGA stream. Format bits 4:3 as ao486's defaults (RGB, 565).
// ------------------------------------------------------------------------------------------

always @(posedge clk_sys) begin
    fb_en          <= ~vga_flags[2] && |vga_flags[1:0];
    fb_base        <= {4'h3, 6'b111110, vga_start_addr, 2'b00};
    fb_width       <= (vga_flags[1:0] == 2'd3) ? 12'd640 :
                      vga_flags[2] ? {1'b0, vga_width, 2'b00} : {vga_width, 3'b000};
    fb_stride      <= {2'b00, vga_stride, 3'b000};
    fb_height      <= vga_flags[3] ? {2'b0, vga_height[10:1]} : {1'b0, vga_height};
    fb_format[2:0] <= (vga_flags[1:0] == 2'd3) ? 3'b101 :
                      (vga_flags[1:0] == 2'd2) ? 3'b100 : 3'b011;  // 24 / 16 / 8 bpp
    fb_format[4:3] <= 2'b00;
end

assign fb_pal_a  = vga_pal_a;
assign fb_pal_d  = {vga_pal_d[17:12], vga_pal_d[17:16],
                    vga_pal_d[11:6],  vga_pal_d[11:10],
                    vga_pal_d[5:0],   vga_pal_d[5:4]};
assign fb_pal_wr = vga_pal_we;

// ------------------------------------------------------------------------------------------
// Audio (clk_audio): z486_mister.sv's mix without CMS and MT-32. The SB Pro mixer volumes
// apply to the voice (SB), MIDI (OPL) and CD channels and, as master, to the whole mix; the
// mixer's output switches (vol_en) turn the CD's left and right on and off, as on MiSTer.
// ------------------------------------------------------------------------------------------

wire [15:0] cdda_l;
wire [15:0] cdda_r;

cdc_vector_handshake_continuous #(
    .DATA_WIDTH(32)
) cd_cdc (
    .clk_in  (clk_sys),
    .clk_out (clk_audio),
    .data_in ({cd_l, cd_r}),
    .data_out({cdda_l, cdda_r})
);

wire        speaker_out_audio;
reg  [16:0] spk;
reg  [16:0] spk_out;

synchronizer speaker_out_sync (
    .clk(clk_audio),
    .in (speaker_out),
    .out(speaker_out_audio)
);

always @(posedge clk_audio) begin
    spk     <= {2'b00, {3'b000, speaker_out_audio} << 2'd2, 11'd0};
    spk_out <= spk >> ~vol_spk;
end

reg  [15:0] mix_dry_l;
reg  [15:0] mix_dry_r;
reg  [16:0] mix_tmp_l;
reg  [16:0] mix_tmp_r;
wire [15:0] master_l, master_r, sb_l, sb_r, opl_l, opl_r, cdv_l, cdv_r;
wire        sb_volume_valid;

sb_volume #(
    .NUM_CH(8),
    .SAMPLE_WIDTH(16)
) sb_volume_inst (
    .clk        (clk_audio),
    .sbp        (sbp),
    .volumes_in ({vol_master_l, vol_master_r,
                  vol_voice_l,  vol_voice_r,
                  vol_midi_l,   vol_midi_r,
                  vol_cd_l,     vol_cd_r}),
    .samples_in ({mix_dry_l,    mix_dry_r,
                  sample_sb_l,  sample_sb_r,
                  sample_opl_l, sample_opl_r,
                  cdda_l,       cdda_r}),
    .samples_out({master_l, master_r,
                  sb_l,     sb_r,
                  opl_l,    opl_r,
                  cdv_l,    cdv_r}),
    .valid      (sb_volume_valid)
);

always @(posedge clk_audio) begin
    if (sb_volume_valid) begin
        audio_l   <= master_l;
        audio_r   <= master_r;
        mix_tmp_l <= spk_out + {sb_l[15], sb_l} + {opl_l[15], opl_l}
                   + (vol_en[2] ? {cdv_l[15], cdv_l} : 17'd0);
        mix_tmp_r <= spk_out + {sb_r[15], sb_r} + {opl_r[15], opl_r}
                   + (vol_en[1] ? {cdv_r[15], cdv_r} : 17'd0);
    end
    mix_dry_l <= (^mix_tmp_l[16:15]) ? {mix_tmp_l[16], {15{mix_tmp_l[15]}}} : mix_tmp_l[15:0];
    mix_dry_r <= (^mix_tmp_r[16:15]) ? {mix_tmp_r[16], {15{mix_tmp_r[15]}}} : mix_tmp_r[15:0];
end

endmodule

`default_nettype wire
