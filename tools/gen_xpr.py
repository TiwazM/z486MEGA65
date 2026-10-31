#!/usr/bin/env python3
"""Generate CORE/CORE-R6.xpr from Megamiga's CORE-R6.xpr (the framework's file list).

Keeps the project settings, the run strategies, the synth_pre.tcl hook, the constraint set and
every source under M2M/ (the vendored framework), drops Megamiga's own sources and adds the
z486 core: CORE/vhdl, the SystemVerilog wrapper and z486 / z486_MiSTer (tools/z486_sources.py,
with the Vivado 2022.2 copies in CORE/gen), and CORE/CORE-impl.xdc to the constraints, for
implementation only. Megamiga hard rule 2: SFType only VHDL2008, SVerilog or none.

  tools/gen_xpr.py [tools/megamiga-CORE-R6.xpr] [CORE/CORE-R6.xpr]

After pc10-iii's tools/gen_xpr.py (Johan Smolinski); licensed under GPL v3.
"""
import os
import re
import sys

import z486_sources

ROOT = z486_sources.ROOT

# CORE/ files, relative to CORE/ (= $PPRDIR)
CORE_VHDL = ["vhdl/globals.vhd", "vhdl/config.vhd", "vhdl/clk.vhd", "vhdl/ps2_device.vhd",
             "vhdl/pc_keyboard.vhd", "vhdl/pc_mouse.vhd", "vhdl/pc_mgmt.vhd", "vhdl/disk_sd.vhd", "vhdl/mega65.vhd"]
CORE_SV = ["sv/guest_l2.sv", "sv/z486_mega65.sv"]

# Verilog include directories, relative to CORE/
INCLUDE_DIRS = ["../z486", "../z486/x87", "../z486_MiSTer/src"]
DEFINES = [("Z486_XILINX", "1")]

# The implementation-only constraints (the over-constraint of main_clk), relative to CORE/
IMPL_XDC = ('      <File Path="$PPRDIR/CORE-impl.xdc">\n        <FileInfo>\n'
            '          <Attr Name="UsedIn" Val="implementation"/>\n'
            '        </FileInfo>\n      </File>\n')


def sftype(path):
    # z486_MiSTer's .v files use SystemVerilog too (Quartus reads them that way): every
    # Verilog source of the core is SVerilog
    if path.endswith(".vhd"):
        return "VHDL2008"
    if path.endswith(".sv") or path.endswith(".v"):
        return "SVerilog"
    return None


def entry(path):
    t = sftype(path)
    return ('      <File Path="$PPRDIR/%s">\n        <FileInfo%s>\n'
            '          <Attr Name="UsedIn" Val="synthesis"/>\n'
            '          <Attr Name="UsedIn" Val="simulation"/>\n'
            '        </FileInfo>\n      </File>\n' % (path, ' SFType="%s"' % t if t else ""))


def main():
    args = sys.argv[1:]
    src = args[0] if len(args) > 0 else os.path.join(ROOT, "tools", "megamiga-CORE-R6.xpr")
    dst = args[1] if len(args) > 1 else os.path.join(ROOT, "CORE", "CORE-R6.xpr")

    z486_sources.write_patched()
    core = CORE_VHDL + CORE_SV
    core += [os.path.relpath(os.path.join(ROOT, z486_sources.project_path(f)),
                             os.path.join(ROOT, "CORE")) for f in z486_sources.sources()]
    for path in core:
        assert os.path.exists(os.path.join(ROOT, "CORE", path)), path

    x = open(src).read()
    m = re.search(r'(<FileSet Name="sources_1".*?<Filter Type="Srcs"/>\n)(.*?)(      <Config>.*?</FileSet>)',
                  x, re.S)
    head, body, tail = m.group(1), m.group(2), m.group(3)
    entries = re.findall(r'      <File Path=".*?</File>\n', body, re.S)
    keep = [e for e in entries if '$PPRDIR/../M2M/' in e]
    keep += [entry(p) for p in core]

    tail = re.sub(r'\s*<Option Name="VerilogDir"[^>]*/>', '', tail)
    tail = re.sub(r'\s*<Define Name[^>]*/>', '', tail)
    opts = "".join('\n        <Option Name="VerilogDir" Val="$PPRDIR/%s"/>' % d for d in INCLUDE_DIRS)
    opts += "".join('\n        <Define Name="%s" Val="%s"/>' % d for d in DEFINES)
    tail = tail.replace("      <Config>", "      <Config>" + opts, 1)

    x = x[:m.start()] + head + "".join(keep) + tail + x[m.end():]

    # CORE-impl.xdc after CORE.xdc, for implementation only
    constrs_end = '      <Config>\n        <Option Name="ConstrsType" Val="XDC"/>'
    assert x.count(constrs_end) == 1
    x = x.replace(constrs_end, IMPL_XDC + constrs_end)
    open(dst, "w").write(x)
    print("%s: %d framework sources, %d core sources" % (os.path.relpath(dst, ROOT),
                                                         len(keep) - len(core), len(core)))


if __name__ == "__main__":
    main()
