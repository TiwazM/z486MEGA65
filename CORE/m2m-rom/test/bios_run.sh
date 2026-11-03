#!/bin/bash
# z486 for MEGA65: bios_patch.asm (the system BIOS's mouse sync check) in the
# QNICE emulator: z486_MiSTer's boot0.rom gets tools/bios_patch.py's writes,
# other files none (bios_test.py).
#
#   CORE/m2m-rom/test/bios_run.sh
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

C=$W/bios
rm -rf "$C"
python3 "$H/bios_test.py" gen "$C"
B=$C/build
mkdir -p "$B"
cp "$Q"/monitor/*.asm "$B/"
cp "$H/bios_harness.asm" "$H/../bios_patch.asm" "$B/"
(cd "$B" && cc -xc -E bios_harness.asm 2>cpp.err | sed '/^#.*/d' > __t.asm &&
    "$W/qasm" __t.asm test.out test.lis > qasm.log 2>&1) || { tail -20 "$B/qasm.log"; exit 1; }
(cd "$B" && timeout ${TMO:-600} "$W/emu/qnice" -a ../sd.img test.out < /dev/null > emu.log 2>&1) || true
python3 "$H/bios_test.py" check "$C" "$B/emu.log"
