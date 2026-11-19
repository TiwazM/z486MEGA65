#!/usr/bin/env python3
# A simulation-only copy of a Verilog file for iverilog, which rejects a wire or reg used
# before its declaration (Vivado accepts it; z486_MiSTer's dma.v does it). Compiles with the
# given command, and for each "declaration after use" error moves that declaration to the
# top of its module ('wire x = e' becomes 'wire x;' there and 'assign x = e' in place).
#   hoist_decls.py in.v out.v "iverilog ... {f} ..."     ({f}: the copy being made)
import re, subprocess, sys

src, dst, cmd = sys.argv[1], sys.argv[2], sys.argv[3]
L = open(src).read().split("\n")
for _ in range(100):
    open(dst, "w").write("\n".join(L))
    r = subprocess.run(cmd.format(f=dst), shell=True, capture_output=True, text=True)
    m = re.search(r"Unable to bind wire/reg/memory `(\w+)(?:\[[^`]*)?' in `[\w.]+'\n"
                  r"(\S+?):(\d+):\s+: A symbol with that name was declared here",
                  r.stdout + r.stderr)
    if not m or m.group(2) != dst:
        sys.exit(0)
    line = int(m.group(3)) - 1
    decl = L[line]
    mstart = max(i for i in range(line) if re.match(r"\s*module\b", L[i]))
    pend = next(i for i in range(mstart, line) if L[i].strip().startswith(");"))
    mm = re.match(r"(\s*(?:wire|reg)\s*(?:signed\s*)?(?:\[[^\]]+\]\s*)?)(\w+)\s*(=.*)$", decl)
    if mm:
        L[line] = "assign " + mm.group(2) + " " + mm.group(3)
        L.insert(pend + 1, mm.group(1) + mm.group(2) + ";   // moved up for iverilog")
    else:
        L[line] = "// moved up for iverilog: " + decl
        L.insert(pend + 1, decl)
sys.exit("hoist_decls.py: too many moves")
