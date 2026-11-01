#!/bin/zsh
# Assembles the DOS test programs in tools/dos (GNU as in the m65build image) into
# tools/dos/build/*.COM, and puts them on tools/dos/build/z486test.iso (mkisofs) for the
# CD-ROM drive.
set -e
root=${0:A:h:h:h}
image=${M65_IMAGE:-m65build}
mkdir -p "$root/tools/dos/build/iso"
docker run --init --rm --platform linux/amd64 --user 1000:1000 \
    --mount type=bind,source="$root/tools/dos",target=/dos \
    $image bash -c "
        cd /dos &&
        for s in *.s; do
            n=\$(basename \$s .s | tr a-z A-Z)
            as --32 -o build/\$n.o \$s &&
            ld -m elf_i386 -Ttext 0x100 --oformat binary -o build/iso/\$n.COM build/\$n.o || exit 1
        done"
# CDPAT.BIN: VTEST's CD pattern, 4 MB, word w = w ^ (w >> 16) * 3C6Fh ^ A5C3h (16 bits)
python3 -c "
import struct
n = 2 * 1024 * 1024
b = bytearray(2 * n)
for w in range(n):
    struct.pack_into('<H', b, 2 * w, (w & 0xFFFF) ^ (((w >> 16) * 0x3C6F) & 0xFFFF) ^ 0xA5C3)
open('$root/tools/dos/build/iso/CDPAT.BIN', 'wb').write(b)"
mkisofs -quiet -V Z486TEST -o "$root/tools/dos/build/z486test.iso" "$root/tools/dos/build/iso"
ls -la "$root/tools/dos/build/iso" "$root/tools/dos/build/z486test.iso"
