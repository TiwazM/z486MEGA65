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
PATCHES = {
    "z486_MiSTer/src/memory/sdram.v": [
        ("localparam integer FREQ66 = 75_000_000;   // pushing the edge",
         "localparam integer FREQ66 = 0;            // MEGA65: timing from FAST_GRADE's ns"),
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
