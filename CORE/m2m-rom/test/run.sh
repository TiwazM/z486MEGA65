#!/bin/bash
# z486 for MEGA65: cdimage.asm (CD_PREP: ISO, raw .bin, .cue + .bin/.wav) in
# the QNICE emulator against FAT32 SD images made by mtools, with 512-byte and
# 4 KB clusters; check.py compares the track table and the extent map with
# gen.py's own layout.
#
#   CORE/m2m-rom/test/run.sh
#
# Needs cc, python3 and mtools. Everything is built below ./work.
set -e
H=$(cd "$(dirname "$0")" && pwd)
Q=$(cd "$H/../../../M2M/QNICE" && pwd)
W=${WORK:-$H/work}
mkdir -p "$W"

if [ ! -x "$W/qasm" ] || [ "$Q/assembler/qasm.c" -nt "$W/qasm" ]; then
    cc -O2 -w -o "$W/qasm" "$Q/assembler/qasm.c"
fi
if [ ! -x "$W/emu/qnice" ]; then
    rm -rf "$W/emu" "$W/dist_kit"; mkdir -p "$W/emu" "$W/dist_kit"
    cp "$Q"/emulator/*.c "$Q"/emulator/*.h "$W/emu/"
    perl "$Q/monitor/sysdef2header.pl" "$Q/monitor/sysdef.asm" "$W/dist_kit/sysdef.h"
    (cd "$W/emu" && cc qnice.c uart.c sd.c timer.c -O3 -fcommon -DUSE_SD -DUSE_UART -DUSE_TIMER \
        -UUSE_VGA -UUSE_IDE -U__EMSCRIPTEN__ -UDEBUG -lpthread -o qnice 2>/dev/null)
fi

rc=0
for spc in 1 8; do
    C=$W/case$spc
    rm -rf "$C"
    python3 "$H/gen.py" "$C" $spc
    B=$C/build
    mkdir -p "$B"
    cp "$Q"/monitor/*.asm "$B/"
    cp "$H/harness.asm" "$C/cases.inc" "$H/../cdimage.asm" "$H/../cdimage_vars.asm" "$B/"
    (cd "$B" && cc -xc -E harness.asm 2>cpp.err | sed '/^#.*/d' > __t.asm &&
        "$W/qasm" __t.asm test.out test.lis > qasm.log 2>&1) || { tail -20 "$B/qasm.log"; exit 1; }
    (cd "$B" && timeout ${TMO:-600} "$W/emu/qnice" -a ../sd.img test.out < /dev/null > emu.log 2>&1) || true
    echo "cluster $((spc * 512)) bytes:"
    python3 "$H/check.py" "$C" "$B/emu.log" || rc=1
done
exit $rc
