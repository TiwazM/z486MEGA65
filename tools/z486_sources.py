#!/usr/bin/env python3
"""The z486 sources of the MEGA65 core, and their Vivado 2022.2 copies.

z486 and z486_MiSTer set `default_nettype none and declare ports without a net type, which
Vivado 2022.2 (the M2M toolchain) rejects (Synth 8-6735, not downgradable). Every source that
sets `default_nettype none is read from a copy in CORE/gen/ (same relative path) with
`default_nettype wire instead; that only drops the lint check. PATCHES changes a few more
sources the same way (the copies are what Vivado reads).

  tools/z486_sources.py      writes the copies (run before a build; synth_pre.tcl does it too)
"""
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
GEN = os.path.join(ROOT, "CORE", "gen")

# z486_MiSTer files outside system.sv's tree that the wrapper (CORE/sv/z486_mega65.sv) uses
EXTRA = ["z486_MiSTer/sys/video_cleaner.sv"]

# memory images the CPU reads with $readmemh by bare file name (synth_pre.tcl copies them into
# the synthesis run's directory)
DATA = ["z486/ucode.hex", "z486/pla_entry_rom.hex", "z486/pla_group_entry.hex",
        "z486/x87/x87_ucode.mem"]

NETTYPE_NONE = re.compile(r"`default_nettype\s+none")

# Source changes for the MEGA65, (old, new) pairs that must each occur once.
# sdram.v: at or below FREQ66 it takes one cycle for tRP and tRCD, which is 15.6 ns at the
# PC's 64 MHz, under the R6's IS42S16320F-6 (18 ns). Without the shortcut every value comes from
# its nanoseconds: tRP and tRCD 2 cycles, tWR 1, tRC 4.
# pic.v: the Bochs BIOS sets up the keyboard (POST 77) before the PICs (ICW1). A key released
# in between (Ctrl+Alt+Del, Enter at a "reboot" prompt) raises IRQ1 before ICW1 clears IRR, and
# an 8259 then waits for a new rising edge, which never comes while nobody reads port 60h: the
# keyboard stays dead until a full reset (and IRQ12 the same for the mouse). After ICW1 the edge
# detector takes an input that is high as a new edge, so a pending request is served once.
PATCHES = {
    "z486_MiSTer/src/memory/sdram.v": [
        ("localparam integer FREQ66 = 75_000_000;   // pushing the edge",
         "localparam integer FREQ66 = 0;            // MEGA65: timing from FAST_GRADE's ns"),
    ],
    # cpu_throttle.sv: speed 3 (the OSD's "56") is 33: 56 of the R6's 64 MHz is no slow-down;
    # CAPS LOCK down selects it (mega65.vhd, z486_mega65.sv)
    "z486/cpu_throttle.sv": [
        ("        3'd3: target_mhz = 7'd56;",
         "        3'd3: target_mhz = 7'd33;     // MEGA65: CAPS LOCK's speed (was 56)"),
    ],
    # system.sv: the last I/O read (port, the byte it returned) and the last write, for the debug
    # snapshot (mega65.vhd, qmon.py status): a polling loop shows the port it waits on. The byte
    # is taken the clock after io_read, when the peripheral has registered it (iobus_adapter.sv).
    # Also the Sound Blaster's DMA requests (one that stays up is waiting on the DMA controller),
    # its IRQ, and a strobe the clock each of the two registers holds a new access (the I/O
    # trace in mega65.vhd logs some of them), and each sample the DSP takes by DMA: how far it
    # jumps from the one before, and where in the block it is (the trace's jump log). And the
    # PICs' registers, the IRQ lines, the 8042's state and the INTAs the PIC acknowledged with
    # another vector than the CPU's (pic.v, pic_inta_bridge.sv, ps2.v below); inta_hold is the
    # switch for the bridge's vector_hold
    "z486_MiSTer/src/system.sv": [
        ("    output     [31:0] cpu_cs_base,",
         "    output     [31:0] cpu_cs_base,\n"
         "    output reg [23:0] dbg_io_rd,        // MEGA65: the last I/O read: port, byte\n"
         "    output reg [23:0] dbg_io_wr,        // MEGA65: the last I/O write: port, byte\n"
         "    output      [1:0] dbg_sb_req,       // MEGA65: the Sound Blaster's DMA requests, 16/8-bit\n"
         "    output            dbg_sb_irq,       // MEGA65: the Sound Blaster's IRQ (5)\n"
         "    output reg        dbg_io_rd_stb,    // MEGA65: dbg_io_rd holds a new read\n"
         "    output reg        dbg_io_wr_stb,    // MEGA65: dbg_io_wr holds a new write\n"
         "    output            dbg_sb_cmd_wait,  // MEGA65: the Sound Blaster holds a DMA command back\n"
         "    input             sb_take_starved,  // MEGA65: sound_dsp.v's dma_take_starved\n"
         "    output            dbg_sb_smp_stb,   // MEGA65: the Sound Blaster took a DMA output sample\n"
         "    output     [15:0] dbg_sb_smp_dif,   // MEGA65: its distance from the one before (left)\n"
         "    output     [15:0] dbg_sb_smp_pos,   // MEGA65: its index in the DSP's block\n"
         "    output            dbg_sb_out_stb,   // MEGA65: the DSP's output (left) changed\n"
         "    output     [15:0] dbg_sb_out_dif,   // MEGA65: by how much\n"
         "    output      [1:0] dbg_sb_out_why,   // MEGA65: 0 a DMA sample, 1 held at 0, 2 direct/ADPCM\n"
         "    output            sample_sb_new,    // MEGA65: toggles with each DSP output sample (clk_audio)\n"
         "    output            sample_sb_mute,   // MEGA65: the DSP holds its output at 0 (clk_audio)\n"
         "    input             inta_hold,        // MEGA65: the PIC holds its vector from the first INTA\n"
         "    output     [47:0] dbg_pic,          // MEGA65: IRR, ISR, IMR of the master, then the slave\n"
         "    output     [15:0] dbg_irq,          // MEGA65: the IRQ lines into the PICs\n"
         "    output     [15:0] dbg_ps2,          // MEGA65: the 8042's IRQs, output buffer, enables, states\n"
         "    output     [15:0] dbg_ps2_fifo,     // MEGA65: the bytes in its mouse and keyboard FIFOs\n"
         "    output     [15:0] dbg_inta_bad,     // MEGA65: INTAs the PIC acknowledged with another vector\n"
         "    output     [15:0] dbg_inta_last,    // MEGA65: the last one: the CPU's vector, the PIC's\n"
         "    output      [1:0] fdd_motor,        // MEGA65: floppy.v's motor bits (drive sounds)\n"
         "    output            fdd_sel,          // MEGA65: the selected floppy drive\n"
         "    output     [15:0] fdd_cyl,          // MEGA65: B:'s and A:'s head cylinders\n"
         "    input       [1:0] fdd_chg_en,       // MEGA65: B:'s, A:'s DIR bit 7 from fdd_chg (the internal drive)\n"
         "    input       [1:0] fdd_chg,          // MEGA65: its disk change line\n"
         "    input             fdd_real_speed,   // MEGA65: the images at a real drive's speed"),
        ("pic_inta_bridge inta_bridge (",
         "wire pic_vector_hold;  // MEGA65 (z486_sources.py)\n"
         "pic_inta_bridge inta_bridge ("),
        ("    .cpu_inta_ready     (inta_ready)\n);",
         "    .cpu_inta_ready     (inta_ready),\n"
         "    .vector_hold_en     (inta_hold),         // MEGA65 (z486_sources.py)\n"
         "    .vector_hold        (pic_vector_hold),\n"
         "    .dbg_mismatches     (dbg_inta_bad),\n"
         "    .dbg_mismatch_last  (dbg_inta_last)\n);"),
        ("\t.irq_mouse         (irq_12)\n);",
         "\t.irq_mouse         (irq_12),\n\n"
         "\t.dbg_state         (dbg_ps2),           // MEGA65 (z486_sources.py)\n"
         "\t.dbg_fifo          (dbg_ps2_fifo)\n);"),
        ("\t.interrupt_input   (interrupt)\n);",
         "\t.interrupt_input   (interrupt),\n\n"
         "\t.vector_hold       (pic_vector_hold),   // MEGA65 (z486_sources.py)\n"
         "\t.dbg_regs          (dbg_pic)\n);\n"
         "assign dbg_irq = interrupt;"),
        ("\t.request           (fdd_request),\n\t.irq               (irq_6)\n);",
         "\t.request           (fdd_request),\n\t.irq               (irq_6),\n\n"
         "\t.drv_motor         (fdd_motor),         // MEGA65 (z486_sources.py): drive sounds\n"
         "\t.drv_sel           (fdd_sel),\n"
         "\t.drv_cyl           (fdd_cyl),\n"
         "\t.ext_chg_en        (fdd_chg_en),\n"
         "\t.ext_chg           (fdd_chg),\n"
         "\t.real_speed        (fdd_real_speed)\n);"),
        ("\t.sbp               (sbp),",
         "\t.sbp               (sbp),\n\n"
         "\t.dma_take_starved  (sb_take_starved),  // MEGA65 (z486_sources.py)\n"
         "\t.dbg_cmd_wait      (dbg_sb_cmd_wait),\n"
         "\t.dbg_smp_stb       (dbg_sb_smp_stb),\n"
         "\t.dbg_smp_dif       (dbg_sb_smp_dif),\n"
         "\t.dbg_smp_pos       (dbg_sb_smp_pos),\n"
         "\t.dbg_out_stb       (dbg_sb_out_stb),\n"
         "\t.dbg_out_dif       (dbg_sb_out_dif),\n"
         "\t.dbg_out_why       (dbg_sb_out_why),\n"
         "\t.sample_sb_new     (sample_sb_new),\n"
         "\t.sample_sb_mute    (sample_sb_mute),"),
        ("// IO Bus Adapter (z486 IO cycles to byte-sequential peripheral bus)",
         "// MEGA65: the last I/O read and write (z486_sources.py)\n"
         "reg dbg_io_rd_d;\n"
         "always @(posedge clk_sys) begin\n"
         "    dbg_io_rd_d <= iobus_read;\n"
         "    if (iobus_read)  dbg_io_rd[23:8] <= iobus_address;\n"
         "    if (dbg_io_rd_d) dbg_io_rd[7:0]  <= iobus_readdata8;\n"
         "    if (iobus_write) dbg_io_wr       <= {iobus_address, iobus_writedata_byte};\n"
         "    dbg_io_rd_stb <= dbg_io_rd_d;\n"
         "    dbg_io_wr_stb <= iobus_write;\n"
         "end\n"
         "assign dbg_sb_req = {dma_sb_req_16, dma_sb_req_8};\n"
         "assign dbg_sb_irq = irq_5;\n\n"
         "// IO Bus Adapter (z486 IO cycles to byte-sequential peripheral bus)"),
        # vga.v's HiColor DAC (below): its 565 flag out to the wrapper's framebuffer format
        ("\toutput wire        video_off,",
         "\toutput wire        video_off,\n"
         "\toutput wire        video_565,         // MEGA65: the HiColor DAC is in 16-bit 565 (z486_sources.py)\n"
         "\toutput wire        video_dac24,       // MEGA65: the HiColor DAC is in 24-bit mode (z486_sources.py)"),
        ("\t.vga_off           (video_off),",
         "\t.vga_off           (video_off),\n"
         "\t.vga_565           (video_565),       // MEGA65 (z486_sources.py)\n"
         "\t.vga_dac24         (video_dac24),     // MEGA65 (z486_sources.py)"),
    ],
    # floppy.v: the drives' state for the drive sounds (mega65.vhd's fdd_sound.vhd: the MEGA65's
    # internal drive follows them): the DOR's motor bits, the selected drive and each drive's
    # head cylinder (its present cylinder number: SEEK, RECALIBRATE, a read's or write's implied seek).
    # For the internal drive as a PC drive (fdd_phys.vhd through pc_mgmt.vhd): register 1 reads
    # the sector waiting by cylinder (15..8), head (7) and sector (6..0); register 6 written while
    # a sector waits ends the command with that error (ST2 in bits 15..8, ST1 in 7..0: an 82077's
    # status for a sector that could not be read or written), as a real controller ends it; and
    # DIR bit 7 is the drive's own disk change line (ext_chg) instead of the image's; for that drive
    # (ext_chg_en) a written sector waits for register 7 (on the disk) before the command goes on.
    # FORMAT on that drive: any sector count (the drive is mounted with 36 so that any disk reads),
    # each sector's ID handed over (registers 8-12: the FORMAT's state, its ID, the track's numbers,
    # the head's cylinder) and answered by register 7 (or 6), no filler bytes popped: fdd_phys
    # writes the whole track with the last ID
    "z486_MiSTer/src/soc/floppy.v": [
        ("\toutput      [1:0] request\n);",
         "\toutput      [1:0] request,\n\n"
         "\toutput      [1:0] drv_motor,  // MEGA65 (z486_sources.py): the DOR's motor bits, B: A:\n"
         "\toutput            drv_sel,    // MEGA65: the selected drive\n"
         "\toutput     [15:0] drv_cyl,    // MEGA65: B:'s and A:'s head cylinders\n"
         "\tinput       [1:0] ext_chg_en, // MEGA65: B:'s, A:'s DIR bit 7 from ext_chg (the internal drive)\n"
         "\tinput       [1:0] ext_chg,    // MEGA65: its disk change line\n"
         "\tinput             real_speed  // MEGA65: the images at a real drive's speed (rs_go)\n"
         ");"),
        ("assign mgmt_readdata = (!mgmt_address) ? {selected_drive[0], sd_sector[14:0]} : (&mgmt_address) ? fifo_readdata : 16'd1;",
         "wire [15:0] fmt_rd;  // MEGA65: registers 8-12, a FORMAT on the internal drive (see the end)\n"
         "assign mgmt_readdata = (!mgmt_address) ? {selected_drive[0], sd_sector[14:0]} :\n"
         "                       (mgmt_address == 4'd1) ? {cylinder[selected_drive[0]], head[selected_drive[0]], sector[selected_drive[0]][6:0]} :  // MEGA65\n"
         "                       (mgmt_address >= 4'd8 && mgmt_address <= 4'd12) ? fmt_rd :  // MEGA65\n"
         "                       (&mgmt_address) ? fifo_readdata : 16'd1;"),
        ("wire fifo_write = mgmt_write && &mgmt_address;",
         "wire fifo_write = mgmt_write && &mgmt_address;\n\n"
         "// MEGA65 (z486_sources.py): register 6 written while a sector waits: the command ends with\n"
         "// that error, ST2 in bits 15..8, ST1 in 7..0 (the internal drive could not read or write it)\n"
         "wire media_error;\n"
         "// MEGA65: register 7 written: the internal drive (ext_chg_en) has written the sector; until\n"
         "// then its write waits with the FIFO empty (the PC's command goes on only once it is on the\n"
         "// disk, and an error still ends this command)\n"
         "wire write_ack = mgmt_write && mgmt_address == 4'd7;\n"
         "// MEGA65: real_speed: a sector of an image waits in S_PREPARE for rs_go (see the end)\n"
         "wire rs_go;"),
        ("\telse if(state == S_PREPARE)                                                   state <= S_SD_CONTROL;",
         "\telse if(state == S_PREPARE && rs_go)                                         state <= S_SD_CONTROL;  // MEGA65"),
        ("\telse if(state == S_SD_WRITE_WAIT_FOR_EMPTY_FIFO && fifo_empty)                state <= S_UPDATE_SECTOR;",
         "\telse if(state == S_SD_WRITE_WAIT_FOR_EMPTY_FIFO && fifo_empty &&  // MEGA65: write_ack\n"
         "\t        (~ext_chg_en[selected_drive[0]] || write_ack))                       state <= S_UPDATE_SECTOR;"),
        ("    (io_address == 3'd7) ? { change[selected_drive[0]], 7'h7F } :",
         "    (io_address == 3'd7) ? { ext_chg_en[selected_drive[0]] ? ext_chg[selected_drive[0]] : change[selected_drive[0]], 7'h7F } :  // MEGA65"),
        ("\tcmd_read_id_finished;\n",
         "\tcmd_read_id_finished ||\n\tmedia_error;  // MEGA65\n"),
        ("\tcmd_read_id_finished\n);",
         "\tcmd_read_id_finished ||\n\tmedia_error  // MEGA65\n);"),
        ("\telse if(cmd_invalid_start)                                                   reply_left <= 4'd1;",
         "\telse if(media_error)                                                         reply_left <= 4'd7;  // MEGA65\n"
         "\telse if(cmd_invalid_start)                                                   reply_left <= 4'd1;"),
        ("\telse if(cmd_invalid_start)                                                reply <= { reply[79:8], 8'h80 };",
         "\telse if(media_error)                                                      reply <= { 24'd0, 8'd2, sector[selected_drive[0]], 7'b0,head[selected_drive[0]], cylinder[selected_drive[0]], mgmt_writedata[15:8], mgmt_writedata[7:0], (8'h40 | { 5'd0, head[selected_drive[0]], selected_drive }) };  // MEGA65\n"
         "\telse if(cmd_invalid_start)                                                reply <= { reply[79:8], 8'h80 };"),
        ("reg [3:0] state;\n",
         "reg [3:0] state;\n"
         "assign media_error = mgmt_write && mgmt_address == 4'd6 &&  // MEGA65 (z486_sources.py)\n"
         "\t(state == S_SD_READ_WAIT_FOR_DATA || state == S_SD_WRITE_WAIT_FOR_EMPTY_FIFO || state == S_SD_FORMAT_WAIT_FOR_FILL);\n"),
        ("\tif(~rst_n)                                                                    state <= S_IDLE;",
         "\tif(~rst_n)                                                                    state <= S_IDLE;\n"
         "\telse if(media_error)                                                         state <= S_IDLE;  // MEGA65"),
        ("\tcommand[15:8] != media_sectors_per_track[selected_drive[0]]; //invalid secotr count",
         "\t(command[15:8] != media_sectors_per_track[selected_drive[0]] && ~ext_chg_en[selected_drive[0]]); //invalid secotr count (MEGA65: the internal drive, any)"),
        ("reg [7:0] format_filler_byte;\n",
         "reg [7:0] format_gap, format_sc;  // MEGA65: the FORMAT's gap 3 and sectors (register 9)\n"
         "always @(posedge clk) begin\n"
         "\tif(~rst_n)                      begin format_gap <= 8'd0; format_sc <= 8'd0; end\n"
         "\telse if(cmd_format_ok_at_start) begin format_gap <= command[7:0]; format_sc <= command[15:8]; end\n"
         "end\n\n"
         "reg [7:0] format_filler_byte;\n"),
        ("\telse if(state == S_SD_FORMAT_WAIT_FOR_FILL && &format_counter && fifo_read) format_sector_count <= format_sector_count - 8'd1;",
         "\telse if(state == S_SD_FORMAT_WAIT_FOR_FILL && (ext_chg_en[selected_drive[0]] ? write_ack : (&format_counter && fifo_read))) format_sector_count <= format_sector_count - 8'd1;  // MEGA65"),
        ("\telse if(state == S_SD_FORMAT_WAIT_FOR_FILL && &format_counter && fifo_read)   state <= S_WAIT;",
         "\telse if(state == S_SD_FORMAT_WAIT_FOR_FILL &&  // MEGA65: the internal drive's track, register 7\n"
         "\t        (ext_chg_en[selected_drive[0]] ? write_ack : (&format_counter && fifo_read))) state <= S_WAIT;"),
        ("\nendmodule",
         "\n// MEGA65: the drives' state for the drive sounds (z486_sources.py)\n"
         "assign drv_motor = {motor_enable[1], motor_enable[0]};\n"
         "assign drv_sel   = selected_drive_r;\n\n"
         "// MEGA65: each drive's head, its present cylinder number: RECALIBRATE, SEEK and a read's or\n"
         "// write's implied seek move it. Not cylinder[], which also takes the C+1 an 82077 reports\n"
         "// after a (multi-track) read or write ends at the end of the track on head 1, and a\n"
         "// FORMAT's ID fields: a real controller's head stays where it is. But the internal drive's\n"
         "// FORMAT seeks to its IDs' cylinder: the Bochs BIOS never sends SEEK (its FORMAT relies on an\n"
         "// emulated controller taking the cylinder from the IDs, as Bochs's does).\n"
         "(* ramstyle = \"logic\" *) reg [7:0] head_pcn[2];\n"
         "always @(posedge clk) begin\n"
         "\tif(~rst_n | sw_reset)                                                                                                begin head_pcn[0] <= 8'd0; head_pcn[1] <= 8'd0; end\n"
         "\telse if(cmd_read_write_start && (cmd_read_write_incorrect_sector_at_start || cmd_write_and_writeprotected_at_start)) head_pcn[selected_drive[0]] <= command[47:40];\n"
         "\telse if(cmd_read_write_ok_at_start)                                                                                  head_pcn[selected_drive[0]] <= command[47:40];\n"
         "\telse if(cmd_recalibrate_start)                                                                                       head_pcn[selected_drive[0]] <= 8'd0;\n"
         "\telse if(cmd_seek_start)                                                                                              head_pcn[selected_drive[0]] <= io_writedata;\n"
         "\telse if(state == S_WAIT_FOR_FORMAT_INPUT && format_data_count == 3'd4 && ext_chg_en[selected_drive[0]])             head_pcn[selected_drive[0]] <= format_data[31:24];\n"
         "end\n"
         "assign drv_cyl   = {head_pcn[1], head_pcn[0]};\n\n"
         "// MEGA65: a FORMAT's sector for the internal drive (pc_mgmt.vhd, fdd_phys.vhd): register 8\n"
         "// FORMAT running (15), the data rate (13..12), the head's cylinder (7..0); 9 the sectors per\n"
         "// track and gap 3; 10 and 11 the sector's ID field (C H, R N); 12 the IDs left with this one\n"
         "// and the filler byte\n"
         "assign fmt_rd = (mgmt_address == 4'd8)  ? {cmd_format_in_progress, 1'b0, data_rate, 4'd0, head_pcn[selected_drive[0]]} :\n"
         "                (mgmt_address == 4'd9)  ? {format_sc, format_gap} :\n"
         "                (mgmt_address == 4'd10) ? format_data[31:16] :\n"
         "                (mgmt_address == 4'd11) ? format_data[15:0] :\n"
         "                                          {format_sector_count, format_filler_byte};\n\n"
         "// MEGA65: real_speed, the images at a real drive's speed (not the internal drive's, ext_chg_en:\n"
         "// a real one). The disk turns at 300 rpm (360 rpm with 15 sectors per track: a 1.2 MB 5.25\"\n"
         "// disk); sector R is in slot R-1 of a turn. A read's, write's or FORMAT's sector goes on\n"
         "// from S_PREPARE once it has passed under the head (a FORMAT's: any slot, a track in one\n"
         "// turn), after the steps of a read's or write's implied seek ((16 - SRT) units each, the\n"
         "// units of floppy.v's SEEK: 1 ms at 500 kbit/s, as an 82077 steps) and 15 units to settle.\n"
         "wire        rs_on   = real_speed && ~ext_chg_en[selected_drive[0]];\n"
         "wire  [7:0] rs_spt  = (media_sectors_per_track[selected_drive[0]] == 8'd0)? 8'd1 : media_sectors_per_track[selected_drive[0]];\n"
         "wire [27:0] rs_inc  = (rs_spt == 8'd15)? {18'd0, rs_spt, 2'b00} + {19'd0, rs_spt, 1'b0} : {18'd0, rs_spt, 2'b00} + {20'd0, rs_spt};\n"
         "reg  [27:0] rs_acc;   // rs_inc a clock, a slot per clk_rate: spt slots in 1/5 (1/6) s\n"
         "wire [28:0] rs_sum  = {1'b0, rs_acc} + {1'b0, rs_inc};\n"
         "reg   [7:0] rs_pos;   // the slot under the head\n"
         "reg   [7:0] rs_last;  // the slot that has just passed (rs_tick)\n"
         "reg         rs_tick;\n"
         "always @(posedge clk) begin\n"
         "\trs_tick <= 1'b0;\n"
         "\tif(~rst_n | ~rs_on)                begin rs_acc <= 28'd0; rs_pos <= 8'd0; rs_last <= 8'd0; end  // (no turn without it)\n"
         "\telse if(rs_sum >= {1'b0, clk_rate}) begin\n"
         "\t\trs_acc  <= rs_sum[27:0] - clk_rate;\n"
         "\t\trs_tick <= 1'b1;\n"
         "\t\trs_last <= rs_pos;\n"
         "\t\trs_pos  <= (rs_pos + 8'd1 >= rs_spt)? 8'd0 : rs_pos + 8'd1;\n"
         "\tend\n"
         "\telse                                    rs_acc <= rs_sum[27:0];\n"
         "end\n"
         "wire  [7:0] rs_sec  = sector[selected_drive[0]];\n"
         "wire  [7:0] rs_want = (rs_sec == 8'd0 || rs_sec > rs_spt)? 8'd0 : rs_sec - 8'd1;\n"
         "reg  [27:0] rs_macc;  // the step units (delay_adder a clock, a unit per clk_rate)\n"
         "wire [28:0] rs_msum = {1'b0, rs_macc} + {1'b0, delay_adder};\n"
         "reg         rs_unit;\n"
         "always @(posedge clk) begin\n"
         "\trs_unit <= 1'b0;\n"
         "\tif(~rst_n)                          rs_macc <= 28'd0;\n"
         "\telse if(rs_msum >= {1'b0, clk_rate}) begin rs_macc <= rs_msum[27:0] - clk_rate; rs_unit <= 1'b1; end\n"
         "\telse                                 rs_macc <= rs_msum[27:0];\n"
         "end\n"
         "wire  [7:0] rs_dist = (command[47:40] > head_pcn[selected_drive[0]])? command[47:40] - head_pcn[selected_drive[0]] : head_pcn[selected_drive[0]] - command[47:40];\n"
         "reg  [12:0] rs_seek;  // units left of the implied seek\n"
         "always @(posedge clk) begin\n"
         "\tif(~rst_n)                                                    rs_seek <= 13'd0;\n"
         "\telse if(cmd_read_write_ok_at_start && rs_on && rs_dist != 8'd0) rs_seek <= rs_dist * (13'd16 - specify_srt) + 13'd15;\n"
         "\telse if(rs_unit && rs_seek != 13'd0)                           rs_seek <= rs_seek - 13'd1;\n"
         "end\n"
         "assign rs_go = ~rs_on || (rs_seek == 13'd0 && rs_tick && (cmd_format_in_progress || rs_last == rs_want));\n\n"
         "endmodule"),
    ],
    # sound_dsp.v: the write status port (2xCh) reads busy for 3 us after a DMA request starts,
    # not for as long as it is up. The DSP holds a request until the DMA controller answers it,
    # which a masked channel (a driver reprogramming or stopping it) or one past its terminal
    # count never does: the port read busy for good, and a driver waiting for it to send its
    # next command (Phantasmagoria's DACBLAST.DRV, port 22Ch) hung. A real SB16's status port
    # does not follow its DMA requests.
    # A new DMA command (B6h, C6h, 1Ch...) waits in dma_command for the transfer in progress to
    # reach the end of its block. Phantasmagoria's driver stops a sound by masking its DMA
    # channel, without a pause or exit command, so that block never ends: the DSP's request
    # stays up, and the next sound's command waited behind it. With dma_take_starved a command
    # starts at once when the block in progress has starved, its request unanswered for two
    # sample periods, since it began; while the DMA controller keeps up, the old rule holds.
    # Not only while it starves: the title music unmasks the channel at its new buffer 3 us
    # before its B6h, the old block took the rest of its samples from there, and every IRQ
    # then came that far into a buffer half, while the driver refilled the half it counts as
    # played (crackle: jumps at the same two places in every block, I/O trace 2026-11-02).
    # A switch (mega65.vhd, qmon.py sbfix) so the same core can play it both ways;
    # dbg_cmd_wait is for the I/O trace, and so are the dbg_smp_ outputs: each DMA output
    # sample's jump from the one before (left channel) and its index in the block. Jumps at
    # the same index in every block come from the buffer halves; jumps anywhere, from the data.
    "z486_MiSTer/src/soc/sound/sound_dsp.v": [
        ("wire dsp_busy_start = cmd_start || dma_req || pause_decrement;",
         "// MEGA65: busy at a new DMA request only, not while it waits (z486_sources.py)\n"
         "reg dma_req_last;\n"
         "always @(posedge clk) dma_req_last <= dma_req;\n"
         "wire dsp_busy_start = cmd_start || (dma_req && !dma_req_last) || pause_decrement;"),
        ("\tinput             sbp_stereo_ff_rst,",
         "\tinput             sbp_stereo_ff_rst,\n"
         "\tinput             dma_take_starved,  // MEGA65: a new command takes over a starved transfer\n"
         "\toutput            dbg_cmd_wait,      // MEGA65: a new DMA command waits for the old block\n"
         "\toutput reg        dbg_smp_stb,       // MEGA65: a DMA output sample (the I/O trace's jump log)\n"
         "\toutput reg [15:0] dbg_smp_dif,       // MEGA65: its distance from the one before (left)\n"
         "\toutput reg [15:0] dbg_smp_pos,       // MEGA65: its index in the block\n"
         "\toutput reg        dbg_out_stb,       // MEGA65: the output (left) changed (the I/O trace)\n"
         "\toutput reg [15:0] dbg_out_dif,       // MEGA65: by how much\n"
         "\toutput reg  [1:0] dbg_out_why,       // MEGA65: 0 a DMA sample, 1 held at 0, 2 direct/ADPCM\n"
         "\toutput reg        out_new_tgl,       // MEGA65: toggles with each sample the DSP outputs\n"
         "\toutput            out_mute,          // MEGA65: the output held at 0 (speaker off in SB Pro mode, 80h)"),
        ("wire dma_restart_possible = ~tr0 || (",
         "// MEGA65: sample periods the DMA request has gone unanswered, up to 2 (z486_sources.py)\n"
         "reg [1:0] dma_starved;\n"
         "always @(posedge clk) begin\n"
         "\tif(!rst_n || sw_reset || ~dma_normal_req)  dma_starved <= 2'd0;\n"
         "\telse if(timer_0_isr && ~dma_starved[1])    dma_starved <= dma_starved + 2'd1;\n"
         "end\n"
         "// MEGA65: the block in progress has starved since it began, though its request may be\n"
         "// answered again (a driver unmasking the channel before its next command)\n"
         "reg dma_stalled;\n"
         "always @(posedge clk) begin\n"
         "\tif(!rst_n || sw_reset || dma_single_start || dma_auto_start || dma_auto_restart || dma_finished) dma_stalled <= 1'b0;\n"
         "\telse if(dma_starved[1])                                                                         dma_stalled <= 1'b1;\n"
         "end\n"
         "assign dbg_cmd_wait = dma_command != S_IDLE;\n\n"
         "wire dma_restart_possible = ~tr0 || (dma_take_starved && (dma_starved[1] || dma_stalled)) || ("),
        ("// Attenuation should not be needed",
         "// MEGA65: each DMA output sample's distance from the one before (left channel) and its\n"
         "// index in the block, for the I/O trace's jump log (mega65.vhd; z486_sources.py)\n"
         "reg  [15:0] dbg_cnt;\n"
         "reg  [15:0] dbg_smp_last;\n"
         "wire [16:0] dbg_smp_sub = {sample_dma_l[15], sample_dma_l} - {dbg_smp_last[15], dbg_smp_last};\n"
         "always @(posedge clk) begin\n"
         "\tif(dma_single_start || dma_auto_start || dma_auto_restart || dma_finished)  dbg_cnt <= 16'd0;\n"
         "\telse if(dma_output)                                                         dbg_cnt <= dbg_cnt + 1'd1;\n"
         "\tif(dma_output) dbg_smp_pos <= dbg_cnt;\n"
         "\tdbg_smp_stb <= sample_output && adpcm_type == ADPCM_NONE;\n"
         "\tif(sample_output && adpcm_type == ADPCM_NONE) begin\n"
         "\t\tdbg_smp_last <= sample_dma_l;\n"
         "\t\tdbg_smp_dif  <= dbg_smp_sub[16] ? 16'd0 - dbg_smp_sub[15:0] : dbg_smp_sub[15:0];\n"
         "\tend\n"
         "end\n\n"
         "// Attenuation should not be needed"),
        ("\tend\nend\n\n//------------------------------------------------------------------------------\n\nendmodule",
         "\tend\nend\n\n"
         "// MEGA65: the output's changes and their cause (the I/O trace), a toggle with each sample\n"
         "// the DSP outputs and its hold at 0, for z486_mega65.sv's output stage (z486_sources.py)\n"
         "wire out_zero = (~speaker_on & sbp) | pause_active;\n"
         "wire out_dma  = sample_output && adpcm_type == ADPCM_NONE;\n"
         "wire out_dir  = cmd_direct_output | adpcm_active | (~adpcm_reference_awaiting & adpcm_reference_output);\n"
         "assign out_mute = out_zero;\n"
         "reg  [1:0]  dbg_out_cause;\n"
         "reg  [15:0] dbg_out_last;\n"
         "wire [16:0] dbg_out_sub = {sample_value_l[15], sample_value_l} - {dbg_out_last[15], dbg_out_last};\n"
         "always @(posedge clk) begin\n"
         "\tdbg_out_cause <= out_zero ? 2'd1 : out_dma ? 2'd0 : 2'd2;\n"
         "\tdbg_out_last  <= sample_value_l;\n"
         "\tdbg_out_stb   <= sample_value_l != dbg_out_last;\n"
         "\tdbg_out_dif   <= dbg_out_sub[16] ? 16'd0 - dbg_out_sub[15:0] : dbg_out_sub[15:0];\n"
         "\tdbg_out_why   <= dbg_out_cause;\n"
         "\tif(!rst_n)                              out_new_tgl <= 1'b0;\n"
         "\telse if(~out_zero && (out_dma || out_dir)) out_new_tgl <= ~out_new_tgl;\n"
         "end\n\n"
         "//------------------------------------------------------------------------------\n\nendmodule"),
    ],
    "z486_MiSTer/src/soc/sound/sound.v": [
        ("\tinput      [27:0] clock_rate\n",
         "\tinput             dma_take_starved,  // MEGA65: sound_dsp.v (z486_sources.py)\n"
         "\toutput            dbg_cmd_wait,\n"
         "\toutput            dbg_smp_stb,\n"
         "\toutput     [15:0] dbg_smp_dif,\n"
         "\toutput     [15:0] dbg_smp_pos,\n"
         "\toutput            dbg_out_stb,\n"
         "\toutput     [15:0] dbg_out_dif,\n"
         "\toutput      [1:0] dbg_out_why,\n"
         "\toutput            sample_sb_new,     // MEGA65: toggles with each DSP output sample (clk_audio)\n"
         "\toutput            sample_sb_mute,    // MEGA65: the DSP holds its output at 0 (clk_audio)\n\n"
         "\tinput      [27:0] clock_rate\n"),
        ("\t.sbp_stereo_ff_rst (sbp_stereo_ff_rst),",
         "\t.sbp_stereo_ff_rst (sbp_stereo_ff_rst),\n"
         "\t.dma_take_starved  (dma_take_starved),\n"
         "\t.dbg_cmd_wait      (dbg_cmd_wait),\n"
         "\t.dbg_smp_stb       (dbg_smp_stb),\n"
         "\t.dbg_smp_dif       (dbg_smp_dif),\n"
         "\t.dbg_smp_pos       (dbg_smp_pos),\n"
         "\t.dbg_out_stb       (dbg_out_stb),\n"
         "\t.dbg_out_dif       (dbg_out_dif),\n"
         "\t.dbg_out_why       (dbg_out_why),\n"
         "\t.out_new_tgl       (dsp_new_tgl),\n"
         "\t.out_mute          (dsp_mute),"),
        ("wire [15:0] dsp_value_l, dsp_value_r;",
         "wire [15:0] dsp_value_l, dsp_value_r;\n"
         "wire        dsp_new_tgl, dsp_mute;   // MEGA65 (z486_sources.py)"),
        ("\t.DATA_WIDTH(16*2 + 9*2)\n) audio_cdc (\n\t.clk_in(clk),\n\t.clk_out(clk_audio),\n"
         "\t.data_in({dsp_value_l, dsp_value_r, cms_l, cms_r}),\n"
         "\t.data_out({sample_sb_l, sample_sb_r, sample_cms_l, sample_cms_r})",
         "\t.DATA_WIDTH(16*2 + 9*2 + 2)          // MEGA65: + the DSP's sample toggle and hold at 0\n"
         ") audio_cdc (\n\t.clk_in(clk),\n\t.clk_out(clk_audio),\n"
         "\t.data_in({dsp_value_l, dsp_value_r, cms_l, cms_r, dsp_new_tgl, dsp_mute}),\n"
         "\t.data_out({sample_sb_l, sample_sb_r, sample_cms_l, sample_cms_r, sample_sb_new, sample_sb_mute})"),
    ],
    "z486_MiSTer/src/soc/pic.v": [
        ("wire [7:0] edge_detect = interrupt_input & ~interrupt_last;",
         "// MEGA65: an input that is high when ICW1 ends counts as a new edge (z486_sources.py)\n"
         "reg icw1_last;\n"
         "always @(posedge clk) begin\n"
         "\tif(rst_n == 1'b0)   icw1_last <= 1'b0;\n"
         "\telse                icw1_last <= init_icw1;\n"
         "end\n"
         "wire [7:0] edge_detect = interrupt_input & ~((icw1_last && ~init_icw1) ? 8'h00 : interrupt_last);"),
        ("\tinput               interrupt_done\n);\n\nwire [7:0] mas_readdata;",
         "\tinput               interrupt_done,\n\n"
         "\tinput               vector_hold,  // MEGA65: the vectors stay as they are (z486_sources.py)\n"
         "\toutput      [47:0]  dbg_regs      // MEGA65: IRR, ISR, IMR of the master, then the slave\n"
         ");\n\nwire [7:0] mas_readdata;"),
        ("\t.interrupt_done(interrupt_done)\n);",
         "\t.interrupt_done(interrupt_done),\n\n"
         "\t.vector_hold(vector_hold),\n"
         "\t.dbg_regs(dbg_regs[47:24])\n);"),
        ("\t.interrupt_done(sla_select & interrupt_done)\n);",
         "\t.interrupt_done(sla_select & interrupt_done),\n\n"
         "\t.vector_hold(vector_hold),\n"
         "\t.dbg_regs(dbg_regs[23:0])\n);"),
        ("\tinput            interrupt_done\n);",
         "\tinput            interrupt_done,\n\n"
         "\tinput            vector_hold,  // MEGA65 (z486_sources.py)\n"
         "\toutput    [23:0] dbg_regs\n);"),
        ("else if(irq || interrupt_do) slave_active <= irr_slave[irq_value];",
         "else if((irq || interrupt_do) && ~vector_hold) slave_active <= irr_slave[irq_value];  // MEGA65: held"),
        ("else if(irq || interrupt_do) interrupt_vector <= { interrupt_offset, irq_value };",
         "else if((irq || interrupt_do) && ~vector_hold) interrupt_vector <= { interrupt_offset, irq_value };  // MEGA65: held"),
        ("wire [7:0] interrupt_vector_bits = 8'h01 << interrupt_vector[2:0];",
         "wire [7:0] interrupt_vector_bits = 8'h01 << interrupt_vector[2:0];\n\n"
         "assign dbg_regs = {irr, isr, imr};  // MEGA65 (z486_sources.py)"),
    ],
    # pic_inta_bridge.sv, pic.v: the bridge gives the CPU the vector on its second INTA and pulses
    # interrupt_done a clock later, and the 8259 acknowledges (IRR bit off, ISR bit on) the vector
    # it holds then. Its vector register follows the highest request every clock, so a request
    # that wins in that clock is acknowledged while the CPU runs the other one's handler: the CPU
    # takes IRQ15 (the CD-ROM) or IRQ14, the slave acknowledges IRQ12 (the mouse), the disk's
    # handler's EOI clears IRQ12's ISR bit, and the mouse's line, high until port 60h is read,
    # never makes a new edge. The mouse is dead for good, and so is the keyboard, its bytes
    # behind the mouse's in the 8042 (Wing Commander III, 2026-11-02: no access to ports 60h/64h
    # for minutes, the mouse inhibited after 60 bytes, mid-stream). An 8259 fixes the vector at
    # the first INTA; with vector_hold the vectors and the cascade's select stay as they are
    # from the first INTA to the acknowledge. A switch (mega65.vhd, qmon.py intahold) so the
    # same core runs both ways; the bridge counts the INTAs where the PIC acknowledged another
    # vector than the CPU took (CORE/sim/tb_inta.sv)
    "z486_MiSTer/src/pic_inta_bridge.sv": [
        ("    output reg         cpu_inta_ready          // Ready signal during INTA\n);",
         "    output reg         cpu_inta_ready,         // Ready signal during INTA\n\n"
         "    input              vector_hold_en,         // MEGA65: hold the PIC's vector from the first INTA\n"
         "    output             vector_hold,            // MEGA65: to the PIC (z486_sources.py)\n"
         "    output reg  [15:0] dbg_mismatches,         // MEGA65: INTAs the PIC acknowledged with another vector\n"
         "    output reg  [15:0] dbg_mismatch_last       // MEGA65: the last one: the CPU's vector, the PIC's\n"
         ");"),
        ("\nendmodule",
         "\n// MEGA65: the PIC keeps its vector from the first INTA to its acknowledge, as an 8259 does;\n"
         "// and the INTAs where the vector the CPU took is not the one the PIC acknowledges, the clock\n"
         "// after (z486_sources.py)\n"
         "assign vector_hold = vector_hold_en && state != S_IDLE;\n\n"
         "always @(posedge clk) begin\n"
         "    if (!reset_n) begin\n"
         "        dbg_mismatches    <= 16'd0;\n"
         "        dbg_mismatch_last <= 16'd0;\n"
         "    end else if (pic_interrupt_done && cpu_inta_din[7:0] != pic_interrupt_vector) begin\n"
         "        if (dbg_mismatches != 16'hFFFF)\n"
         "            dbg_mismatches <= dbg_mismatches + 16'd1;\n"
         "        dbg_mismatch_last <= {cpu_inta_din[7:0], pic_interrupt_vector};\n"
         "    end\n"
         "end\n\n"
         "endmodule"),
    ],
    # vga.v: a HiColor DAC's command and extended registers, as Tseng's BIOS V8.00N programs and
    # reads them for its DAC type 20h (the type it detects on z486; Sierra SC1502x-like: 86Box
    # pairs that BIOS family with one). int 10h AX=10F0h sets a HiColor mode through them,
    # 10F2h reads it back, and the VESA call 4F03h (the current mode) asks 10F2h. vga.v had no
    # such registers: after 4F02h set 110h or 111h (640x480, 15 or 16 bit), 4F03h answered 101h
    # (8 bit), and The Eleventh Hour stopped with "unable to set requested graphic mode"; and
    # every 16-bit picture went out as 555. After four reads of 3C6h in a row the next access is
    # the command register; a fifth read with its bit 4 set opens the extended registers: the
    # next write is an index, the one after it is skipped, further writes go to the indexed
    # register on (the index counts up), reads return it; an access to 3C7h-3C9h ends a
    # sequence. Register 3 holds the mode the BIOS set: 02h 15 bit, 03h 16 bit, 09h 24 bit.
    # The index is 8 bits, registers 0..7 kept, the rest ignored (they read 0): at power-on
    # the BIOS loads 34 bytes from index 20h; a 3-bit index wrapped them onto register 1,
    # which the BIOS's detection reads, and it took the DAC for type 24h, the one that can
    # do 800x600 at 24 bit (VESA 115h), which z486's display could not show (stripes). Since
    # 2026-11-10 register 1 reads 01h, so the BIOS takes type 24h on purpose: it sets 115h
    # through the DAC's 16-bit path (attribute 16h = A0h, CRTC 37h = 8Bh, the CRTC counting
    # 16-bit words: 01h = 95h, offset 12Ch), which vga_flags calls 16 bit; vga_dac24 (register 3
    # at 09h) tells the wrapper the pixels are 24 bit (CORE/sim/build/vbe/VBECRTC.COM).
    # vga_565 tells the wrapper to read 16-bit pixels as 565 (CORE/sim/build/vbe/VBEPROBE.COM
    # shows what the BIOS reads back)
    "z486_MiSTer/src/soc/vga.v": [
        ("\toutput reg          scanline_done\n);",
         "\toutput reg          scanline_done,\n\n"
         "\toutput              vga_565,           // MEGA65: the HiColor DAC is in 16-bit 565 (z486_sources.py)\n"
         "\toutput              vga_dac24          // MEGA65: the HiColor DAC is in 24-bit mode (z486_sources.py)\n"
         ");"),
        ("always @(posedge clk_sys) if(~rst_n) dac_mask <= 8'hFF; else if(io_c_write && io_address == 4'h6) dac_mask <= io_writedata[7:0];",
         "// MEGA65: the HiColor DAC's command and extended registers (z486_sources.py)\n"
         "reg  [2:0] hdac_cnt;                   // reads of 3C6h in a row, up to 4\n"
         "reg  [7:0] hdac_cr;                    // the command register\n"
         "reg  [1:0] hdac_ext;                   // 0 off, 1 the index next, 2 a byte to skip, 3 data\n"
         "reg  [7:0] hdac_idx;                   // registers 0..7 kept, the rest read 0\n"
         "reg  [7:0] hdac_reg [0:7];\n"
         "wire       hdac_rd6     = io_c_read_valid && io_address == 4'h6;\n"
         "wire       hdac_wr6     = io_c_write && io_address == 4'h6;\n"
         "wire       hdac_end     = (io_c_read_valid || io_c_write) && (io_address == 4'h7 || io_address == 4'h8 || io_address == 4'h9);\n"
         "wire       hdac_mask_wr = hdac_wr6 && hdac_ext == 2'd0 && hdac_cnt != 3'd4;\n"
         "// register 1 reads 01h: the BIOS's detection (7A6Bh) then takes the DAC for type 24h, which\n"
         "// adds 800x600 at 24 bit (VESA 115h); the BIOS never writes it\n"
         "wire [7:0] hdac_rreg    = (hdac_idx == 8'd1) ? 8'h01 :\n"
         "                          (hdac_idx[7:3] == 5'd0) ? hdac_reg[hdac_idx[2:0]] : 8'h00;\n"
         "wire [7:0] hdac_read    = (hdac_ext == 2'd3) ? hdac_rreg : (hdac_cnt == 3'd4) ? hdac_cr : dac_mask;\n"
         "\n"
         "integer hdac_i;\n"
         "always @(posedge clk_sys) begin\n"
         "\tif(~rst_n) begin\n"
         "\t\thdac_cnt <= 3'd0;\n"
         "\t\thdac_cr  <= 8'd0;\n"
         "\t\thdac_ext <= 2'd0;\n"
         "\t\thdac_idx <= 8'd0;\n"
         "\t\tfor(hdac_i = 0; hdac_i < 8; hdac_i = hdac_i + 1) hdac_reg[hdac_i] <= 8'd0;\n"
         "\tend\n"
         "\telse if(hdac_end) begin\n"
         "\t\thdac_cnt <= 3'd0;\n"
         "\t\thdac_ext <= 2'd0;\n"
         "\tend\n"
         "\telse if(hdac_rd6) begin\n"
         "\t\tif(hdac_ext == 2'd0) begin\n"
         "\t\t\tif(hdac_cnt != 3'd4) hdac_cnt <= hdac_cnt + 3'd1;\n"
         "\t\t\telse if(hdac_cr[4])  hdac_ext <= 2'd1;\n"
         "\t\tend\n"
         "\tend\n"
         "\telse if(hdac_wr6) begin\n"
         "\t\tcase(hdac_ext)\n"
         "\t\t\t2'd1: begin hdac_idx <= io_writedata[7:0]; hdac_ext <= 2'd2; end\n"
         "\t\t\t2'd2: hdac_ext <= 2'd3;\n"
         "\t\t\t2'd3: begin\n"
         "\t\t\t\tif(hdac_idx[7:3] == 5'd0) hdac_reg[hdac_idx[2:0]] <= io_writedata[7:0];\n"
         "\t\t\t\thdac_idx <= hdac_idx + 8'd1;\n"
         "\t\t\tend\n"
         "\t\t\tdefault: begin\n"
         "\t\t\t\tif(hdac_cnt == 3'd4) hdac_cr <= io_writedata[7:0];\n"
         "\t\t\t\thdac_cnt <= 3'd0;\n"
         "\t\t\tend\n"
         "\t\tendcase\n"
         "\tend\n"
         "end\n"
         "\n"
         "// 16-bit pixels are 565 in extended mode (command bit 3) with register 3 at 03h, or with\n"
         "// command bits 7:5 = 110 (C0h, 16 bit on the BIOS's other path, as on AT&T/Sierra DACs)\n"
         "assign vga_565 = hdac_cr[3] ? (hdac_reg[3] == 8'h03) : (hdac_cr[7:5] == 3'b110);\n"
         "// 24-bit pixels: extended mode with register 3 at 09h (the BIOS's 24-bit modes; 800x600 sends\n"
         "// them over the 16-bit path, attribute 16h bits 5:4 = 10b, which vga_flags reads as 16 bit)\n"
         "assign vga_dac24 = hdac_cr[3] && (hdac_reg[3] == 8'h09);\n"
         "\n"
         "always @(posedge clk_sys) if(~rst_n) dac_mask <= 8'hFF; else if(hdac_mask_wr) dac_mask <= io_writedata[7:0];"),
        ("\t(io_c_read_valid && io_address == 4'h6)                      ? dac_mask : //pel mask",
         "\t(io_c_read_valid && io_address == 4'h6)                      ? hdac_read : //pel mask; MEGA65: the HiColor DAC's registers"),
    ],
    # ps2.v: status bit 5 said "mouse data" whenever the mouse's FIFO held a byte, also while the
    # byte in the output buffer (port 60h) was a key; on an 8042 it says where that byte came
    # from. A keyboard handler that leaves "mouse data" alone (SeaBIOS's does) left the key
    # there, and IRQ1, high until it is read, made no new edge. And its state for the debug
    # snapshot: bits 0/1 IRQ1/IRQ12, 2 the output buffer full, 3 with the mouse's byte, 4/5 the
    # keyboard/mouse disabled, 6/7 their IRQs enabled (command byte), 11..8/15..12 the
    # keyboard's/mouse's line state; the FIFOs' bytes, the mouse's in 14..8, the keyboard's 6..0.
    # And its mouse FIFO, which an 8042 does not have (one output byte; a mouse drops what it
    # has not sent when a command comes): a command to the mouse (D4) drops the bytes queued,
    # also one in the output buffer, when its byte is written and again when it goes out
    # (mouse_drop; by then a byte the mouse was still sending has arrived); while the mouse port is off (command byte bit 5, A7)
    # and from a command's D4 byte until it has gone out (mouse_hold) they wait in the FIFO,
    # not in the output buffer: the D4 byte turns the port on, and the PC reads the answer at
    # once. Windows quitting writes command byte 75h
    # (IRQ12 and the port off), sends D4 F4 and wants FA next; it read an old packet byte
    # instead (I/O trace, 2026-11-02), left IRQ12 off, and the mouse's bytes, unread, held the
    # keyboard's back for good
    "z486_MiSTer/src/soc/ps2.v": [
        ("\toutput                  ps2_mousedat_out   // Mouse data output (open-drain)\n);",
         "\toutput                  ps2_mousedat_out,  // Mouse data output (open-drain)\n\n"
         "\toutput       [15:0]     dbg_state,  // MEGA65: IRQs, output buffer, enables, states (z486_sources.py)\n"
         "\toutput       [15:0]     dbg_fifo    // MEGA65: the bytes in the mouse's and the keyboard's FIFOs\n"
         ");"),
        ("        ~(mouse_fifo_empty),         // Bit 5: Mouse output buffer full",
         "        status_mousebufferfull,      // Bit 5: MEGA65: the output buffer's byte is the mouse's"),
        ("\nendmodule",
         "\n// MEGA65: the state for the debug snapshot (z486_sources.py)\n"
         "assign dbg_state = {mouse_state, keyb_state, allow_irq_mouse, allow_irq_keyb, disable_mouse,\n"
         "                    disable_keyboard, status_mousebufferfull, status_outputbufferfull,\n"
         "                    irq_mouse, irq_keyb};\n"
         "assign dbg_fifo  = {1'b0, mouse_fifo_counter, 1'b0, keyb_fifo_counter};\n\n"
         "endmodule"),
        ("    else if(io_read_valid && io_address[2:0] == 3'd0 && status_mousebufferfull) irq_mouse <= 1'b0;",
         "    else if(io_read_valid && io_address[2:0] == 3'd0 && status_mousebufferfull) irq_mouse <= 1'b0;\n"
         "    else if(mouse_drop)                                                         irq_mouse <= 1'b0;  // MEGA65"),
        ("    else if(outputbuffer_idle && ~(mouse_fifo_empty))   status_mousebufferfull <= 1'b1;  // Set when mouse data available",
         "    else if(mouse_drop)                                 status_mousebufferfull <= 1'b0;  // MEGA65: a command drops the mouse's bytes\n"
         "    else if(outputbuffer_idle && ~(mouse_fifo_empty) && ~(mouse_hold))      status_mousebufferfull <= 1'b1;  // MEGA65: not while held"),
        ("    else if(outputbuffer_idle && (~(mouse_fifo_empty) || ~(keyb_fifo_empty)))   status_outputbufferfull <= 1'b1;  // Set when any data available",
         "    else if(mouse_drop && status_mousebufferfull)                               status_outputbufferfull <= 1'b0;  // MEGA65\n"
         "    else if(outputbuffer_idle && ((~(mouse_fifo_empty) && ~(mouse_hold)) || ~(keyb_fifo_empty)))   status_outputbufferfull <= 1'b1;  // MEGA65: no mouse data while held"),
        ("    .sclr       (cmd_self_test),                                                //Clear on self-test",
         "    .sclr       (cmd_self_test || mouse_drop),                                  //Clear on self-test; MEGA65: and a command to the mouse"),
        ("// Mouse FIFO signals",
         "// MEGA65: a byte to the mouse is written and goes out: what the mouse sent before is dropped;\n"
         "// its bytes wait while its port is off and from a command's D4 byte until it went out (z486_sources.py)\n"
         "wire mouse_drop = write_to_mouse || mouse_state == PS2_SEND_INHIBIT;\n"
         "wire mouse_hold = disable_mouse || write_to_mouse || (status_inputbufferfull && input_for_mouse && ~(input_write_done));\n\n"
         "// Mouse FIFO signals"),
    ],
}


def _manifest(path, base, skip=None):
    out = []
    for line in open(os.path.join(ROOT, path)):
        line = line.strip()
        if not line or line.startswith("#") or (skip and line.startswith(skip)):
            continue
        out.append(os.path.join(base, line))
    return out


def sources():
    """The z486 sources in compile order, as paths relative to the repository root."""
    cpu = _manifest("z486/boards/common/rtl_sources.f", "z486", skip="boards/common/")
    pc = _manifest("ooc/pc_sources.f", "z486_MiSTer")
    return cpu + pc + EXTRA


def needs_patch(rel):
    return rel in PATCHES or \
        bool(NETTYPE_NONE.search(open(os.path.join(ROOT, rel), errors="replace").read()))


def project_path(rel):
    """Where Vivado reads the file from, relative to the repository root."""
    return os.path.join("CORE", "gen", rel) if needs_patch(rel) else rel


def write_patched():
    count = 0
    for rel in sources():
        if not needs_patch(rel):
            continue
        text = open(os.path.join(ROOT, rel), errors="replace").read()
        dst = os.path.join(GEN, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        new = NETTYPE_NONE.sub("`default_nettype wire", text)
        for old, rep in PATCHES.get(rel, []):
            if new.count(old) != 1:
                sys.exit("%s: the patch no longer applies: %s" % (rel, old))
            new = new.replace(old, rep)
        if not os.path.exists(dst) or open(dst, errors="replace").read() != new:
            open(dst, "w").write(new)
        count += 1
    return count


if __name__ == "__main__":
    missing = [f for f in sources() if not os.path.exists(os.path.join(ROOT, f))]
    if missing:
        sys.exit("missing sources (git submodule update --init?): " + ", ".join(missing))
    print("z486 sources: %d, patched copies in CORE/gen: %d" % (len(sources()), write_patched()))
