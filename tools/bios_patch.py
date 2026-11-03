#!/usr/bin/env python3
"""The sync check for z486_MiSTer's system BIOS (CORE/m2m-rom/bios_patch.asm).

The Bochs BIOS's IRQ12 handler (F000:51B8) files the mouse's bytes by position and never
checks a packet's first byte, so one lost byte leaves every packet after it one position
off. The firmware patches the BIOS's copy in HyperRAM: at F000:5209 the handler calls a
check in the filler before the POST entry (F000:E000), which does what the 8 bytes there
did and then drops a byte at position 0 without bit 3.

  tools/bios_patch.py [boot0.rom]            the sums and BPT_TAB for bios_patch.asm
  tools/bios_patch.py [boot0.rom] --check    compare with bios_patch.asm
  tools/bios_patch.py [boot0.rom] --dis      disassemble the patched handler (capstone)
  tools/bios_patch.py [boot0.rom] --out F    write the patched image to F

The default file is z486_MiSTer/verilator/boot0.rom. The firmware loads it two bytes per
word (the first in the low byte) from 4K-word window PC_BIOS_WIN (0x01F8 = 0xF0000), and
sums the words as it loads them: S1 += word, S2 += S1 (16 bits each).
"""
import os
import re
import struct
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
ROM = os.path.join(ROOT, "z486_MiSTer", "verilator", "boot0.rom")
ASM = os.path.join(ROOT, "CORE", "m2m-rom", "bios_patch.asm")

PC_BIOS_WIN = 0x01F8
CALL_AT = 0x5209                    # in int74_function: the position into [bp-2]
CALL_OLD = bytes.fromhex("8A46FC 2407 8846FE")      # mov al,[bp-4]; and al,7; mov [bp-2],al
CHECK_AT = 0xE000                   # filler (zeros) up to the POST entry at E05B
POST = 0xE05B
CHECK = bytes.fromhex(
    "8A46FC"        # mov  al,[bp-4]        the position (EBDA 26h, read before)
    "2407"          # and  al,7
    "8846FE"        # mov  [bp-2],al
    "750A"          # jnz  ok               not position 0: as before
    "F646FF08"      # test byte [bp-1],8    the byte: a packet's first has bit 3
    "7504"          # jnz  ok
    "89EC"          # mov  sp,bp            out of step: drop it (int74_function's
    "5D"            # pop  bp               own early return, as at 51D8)
    "C3"            # ret
    "C3"            # ok: ret
)


def patched(rom):
    if len(rom) != 0x10000:
        raise SystemExit("not 64 KB")
    if rom[CALL_AT:CALL_AT + len(CALL_OLD)] != CALL_OLD:
        raise SystemExit("F000:%04X is not the expected code" % CALL_AT)
    if any(rom[CHECK_AT:POST]):
        raise SystemExit("F000:%04X..%04X is not filler" % (CHECK_AT, POST))
    call = b"\xE8" + struct.pack("<H", (CHECK_AT - (CALL_AT + 3)) & 0xFFFF)
    call += b"\x90" * (len(CALL_OLD) - len(call))
    new = bytearray(rom)
    new[CALL_AT:CALL_AT + len(call)] = call
    new[CHECK_AT:CHECK_AT + len(CHECK)] = CHECK
    return bytes(new)


def sums(rom):
    s1 = s2 = 0
    for (w,) in struct.iter_unpack("<H", rom):
        s1 = (s1 + w) & 0xFFFF
        s2 = (s2 + s1) & 0xFFFF
    return s1, s2


def table(rom, new):
    """(4K window, word in it, new word) for every word that changes"""
    t = []
    for a in range(0, len(rom), 2):
        if rom[a:a + 2] != new[a:a + 2]:
            w = a // 2
            t.append((PC_BIOS_WIN + (w >> 12), w & 0xFFF, struct.unpack_from("<H", new, a)[0]))
    return t


def asm_values(path):
    src = open(path).read()
    s1 = int(re.search(r"^BPT_S1\s+\.EQU\s+0x([0-9A-Fa-f]+)", src, re.M).group(1), 16)
    s2 = int(re.search(r"^BPT_S2\s+\.EQU\s+0x([0-9A-Fa-f]+)", src, re.M).group(1), 16)
    body = src[re.search(r"^BPT_TAB\b", src, re.M).start():]
    words = [int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]+)", body.split(".DW     0\n")[0])]
    return (s1, s2), [tuple(words[i:i + 3]) for i in range(0, len(words), 3)]


def main():
    args = sys.argv[1:]
    path = ROM
    if args and not args[0].startswith("--"):
        path = args.pop(0)
    rom = open(path, "rb").read()
    new = patched(rom)
    s, t = sums(rom), table(rom, new)
    if "--out" in args:
        open(args[args.index("--out") + 1], "wb").write(new)
    if "--check" in args:
        if asm_values(ASM) != (s, t):
            print("bios_patch.asm does not match %s" % path)
            return 1
        print("bios_patch.asm matches %s" % path)
        return 0
    if "--dis" in args:
        import capstone
        md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_16)
        for a, b in ((0x51B8, 0x5291), (CHECK_AT, CHECK_AT + len(CHECK))):
            for i in md.disasm(new[a:b], a):
                print("F000:%04X  %-6s %s" % (i.address, i.mnemonic, i.op_str))
            print()
        return 0
    print("BPT_S1          .EQU    0x%04X" % s[0])
    print("BPT_S2          .EQU    0x%04X" % s[1])
    for i, (win, off, w) in enumerate(t):
        print("%s.DW     0x%04X, 0x%04X, 0x%04X" % ("BPT_TAB         " if i == 0 else " " * 16,
                                                   win, off, w))
    print(" " * 16 + ".DW     0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
