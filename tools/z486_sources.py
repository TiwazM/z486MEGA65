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
