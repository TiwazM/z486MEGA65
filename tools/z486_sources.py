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
    # jumps from the one before, and where in the block it is (the trace's jump log)
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
         "    output     [15:0] dbg_sb_smp_pos,   // MEGA65: its index in the DSP's block"),
        ("\t.sbp               (sbp),",
         "\t.sbp               (sbp),\n\n"
         "\t.dma_take_starved  (sb_take_starved),  // MEGA65 (z486_sources.py)\n"
         "\t.dbg_cmd_wait      (dbg_sb_cmd_wait),\n"
         "\t.dbg_smp_stb       (dbg_sb_smp_stb),\n"
         "\t.dbg_smp_dif       (dbg_sb_smp_dif),\n"
         "\t.dbg_smp_pos       (dbg_sb_smp_pos),"),
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
         "\toutput reg [15:0] dbg_smp_pos,       // MEGA65: its index in the block"),
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
    ],
    "z486_MiSTer/src/soc/sound/sound.v": [
        ("\tinput      [27:0] clock_rate\n",
         "\tinput             dma_take_starved,  // MEGA65: sound_dsp.v (z486_sources.py)\n"
         "\toutput            dbg_cmd_wait,\n"
         "\toutput            dbg_smp_stb,\n"
         "\toutput     [15:0] dbg_smp_dif,\n"
         "\toutput     [15:0] dbg_smp_pos,\n\n"
         "\tinput      [27:0] clock_rate\n"),
        ("\t.sbp_stereo_ff_rst (sbp_stereo_ff_rst),",
         "\t.sbp_stereo_ff_rst (sbp_stereo_ff_rst),\n"
         "\t.dma_take_starved  (dma_take_starved),\n"
         "\t.dbg_cmd_wait      (dbg_cmd_wait),\n"
         "\t.dbg_smp_stb       (dbg_smp_stb),\n"
         "\t.dbg_smp_dif       (dbg_smp_dif),\n"
         "\t.dbg_smp_pos       (dbg_smp_pos),"),
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
