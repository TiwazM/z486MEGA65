# Design notes

Part of [z486MEGA65](../README.md). How the core is put together: the plan, then what each part of the shell does and why.

## Plan

- **Board:** MEGA65 R6 (XC7A200T-2), on MiSTer2MEGA65 in Megamiga's fork
  ([m2m-provenance.md](m2m-provenance.md)).
- **Memory:** the R6's 64 MB SDRAM for system RAM; HyperRAM for the SVGA
  framebuffer (VRAM) and the boot image.
- **Clock:** 66.0 MHz, twice CAPS LOCK's 33 MHz (64 MHz until 2026-11-10). A
  DX2-66's 66.667 MHz missed by 0.25 ns before the 2026-11-10 path work; one MMCM
  makes 66.0 MHz (VCO 660 MHz), which meets timing with 0.56 ns to spare.
- **Disks:** a hardware replacement for MiSTer's ARM-side IDE/floppy handling,
  after `mgmt_bridge.sv` in
  [PCXT-EGA-MEGA65](https://github.com/silent-command/PCXT-EGA-MEGA65)
  (same `ide.v` / `floppy.v`), fed by the fork's hardware SD engine as in
  [pc10-iii](https://github.com/johansmolinski/pc10-iii).
- **Keyboard and mouse:** MEGA65 keyboard and joystick-port mouse as PS/2
  devices, after PCXT-EGA-MEGA65's `keyboard.vhd` and `m65_mouse_ps2.vhd`.
- **Later:**
  - The x87's speed and accuracy ([x87](x87.md): what it costs per
    instruction, what it gets wrong, the order to fix it); perhaps a Voodoo 1.
  - Programs that bring SciTech's UniVBE engine (UVBELib) take z486's VGA for
    an ET4000/W32: The Eleventh Hour prints "Tseng Labs SuperVGA (ET4000/W32
    unknown revision) with 2 Mb, VBE 1.2" and "RAM DAC: Normal 8 bit DAC",
    then runs with its sound but a black screen. z486's ET4000 has W32
    traits (2 MB, the extended segment register 3CBh, CRTC 31h-37h kept but
    mostly without effect) but no linear framebuffer (CRTC 30h/36h), which
    UniVBE's W32 driver most likely draws into (not traced). Either a plain
    AX to such detection (an AX had at most 1 MB) or the W32's linear window;
    the second goes with a W32 hardware cursor (Windows' software cursor
    flickers when the picture under it changes, as on a real ET4000AX).
  - 1351 mouse smoothing (`pc_mouse.vhd`, done for v0.2.1, not on the board
    yet): the mouSTer moves its 1351 position about every 10 ms, and packets
    at the 40 per second Windows sets took two or three of those steps in turn
    (an I/O trace while moving steadily: x −7, −10, −7, −10, ...), so the
    pointer juddered. Now each reading's counts go out one at a time, evenly
    over the time the reading before took (at most ~16 ms); what is left when
    the next comes goes with it. `tb_pc_mouse_pot.vhd` 6.: 6 counts every
    10 ms at 40 packets a second, 12 or 18 counts a packet before, 15 each now.
  - Ultima Underworld 2 hangs with its Sound Blaster option (its Pro option
    with `T4` works): the card's blocks and IRQ 5 run, then the CPU stops
    taking interrupts; where it is then is not known. With the Pro option
    some sound effects may not play (not certain: to compare with DOSBox
    first; then `qmon.py iotrace start quiet` while one should play). One of
    DOOM's demo sounds also feels off (the same with `sbsoft` on and off),
    likewise to compare with DOSBox.
  - CD music while a game loads from the hard disk, not tried on the board.
  - Chris's 3D Benchmark (Phil's DOS Benchmark Pack, `MARKS/CHRISB/BENCH.EXE`,
    DJGPP: invalid, zero divide and overflow unmasked) stops with "Floating Point
    exception at eip=00003df5", the FLD m32 after an FSTP m32 (BENCH.EXE
    3DD1..3DF5: two products, FSUBP, FSTP m32). In z486's simulation an x87
    instruction with a memory operand does not take a pending unmasked exception
    while the x87 is still busy with the one before: it runs, and the exception
    comes at the next instruction (`z486/tests/programs/x87_pending_direct.asm`:
    WAIT and the register forms pass, every memory form fails). That explains
    where it is reported, not what raised it: BENCH.EXE's sequence over 128 value
    sets (`x87_chris3d.asm`) is bit-exact with no exception, and stores that page
    fault (`x87_store_page_fault.asm`) restart cleanly. v0.1-preview stops the
    same way (the same EIP and registers, 2026-11-07): older than this round's
    x87 work, so a bisect over the fpu cores would find nothing.
    Found (2026-11-10, the whole-PC simulation of BENCH.EXE under FreeDOS and
    CWSDPMI, with an x87 watch: the status word, the stack and the microcode
    around the first unmasked exception): DJGPP's control word is 037Ah (invalid
    and zero divide unmasked), so a store may not queue behind a busy x87
    (queue_safe), and BENCH's FSTP m32 comes two instructions after FSUBP. It
    fell back to its 386 routine, which sends the command before it writes: the
    x87 converted and popped, then the write page-faulted (CR2 100F8A74h: CWSDPMI
    maps a page on its first touch), and the restarted FSTP found the stack empty
    (IE, stack underflow), reported at 3DF5. The direct store path checks its
    destination first (the overlay's CW), so the store now holds for a busy x87
    and then goes direct (z486 aac6a40, `x87_store_page_fault_busy`; for v0.2.2).
    In the whole-PC simulation with the fix BENCH.EXE runs on in its graphics
    mode, no unmasked x87 exception, to the run's end (700M sim_time; it stopped
    at 452M before). On the board (v022c, 2026-11-11) it runs to its end: Chris's
    Bench Score 43.3, 25.9 frames per second.
  - SpeedSys 4.78 sat after its header on v0.2 and v0.2.1 (2026-11-08/11; the
    `natdbg` test core had reached its system box). Found in the whole-PC
    simulation, which stopped there too (2026-11-11): right after the header
    SpeedSys enters unreal mode from its code segment, 469Dh there (MOV CR0 with
    PE, LGDT, FS/GS/DS/ES with a 4 GB data selector, PE off, no far jump). z486
    cleared CS[1:0] when PE was set, to make CPL 0 (z386 did so from its first
    commit); the Intel486 leaves CS as it is. CS came back as 469Ch, the next
    real-mode interrupt pushed 469Ch and its IRET resumed 16 bytes off, a RET went
    to 469C:0000, and the CPU ran into SpeedSys's data: the PSP segment 21CDh it
    keeps at CS:0, CD 21 = INT 21h with AH = 01h, DOS waiting for a key forever.
    Only code segments whose selector value has RPL bits set are hit, so it
    depends on where DOS loads SpeedSys: v0.2's hang at 41DF:4ADF (bits 11),
    natdbg's code segment 4148h (bits 00). Fix: z486 holds CPL 0 from that CR0
    write to the next CS load and leaves CS alone (z486 a3dbae9,
    `unreal_odd_cs`; not on the board yet). In the simulation SpeedSys then
    determines the system contents and shows its system box.
  - SpeedSys 4.78 then stops in its system box, on `natdbg` (4148:5D86..5DA1)
    and in the simulation with the fix (469D:5D76..5DA7, from 1.265G to the
    run's end at 1.5G): not a port 61h poll, as read from the I/O trace before
    (the last I/O was SpeedSys starting timers 0 and 2), but SpeedSys's bubble
    sort of 169 dwords (its timing samples), which never ends: it sorts at
    C35D:0021, in the VGA BIOS ROM, so no swap sticks. A SpeedSys bug that our
    BIOS brings out: to show the BIOS's name it scans F000:0000..FFFD with
    DS = F000 for a year "198x"/"199x" followed by ',', '-' or ' ' (469D:1348),
    and when there is none it leaves without its POP DS (469D:136F). z486_MiSTer's
    system BIOS (the Bochs BIOS) has only "(c) 2001-2017  The Bochs Project", so
    DS stays F000 and SpeedSys takes its buffer segment from F000:0019 (C35Dh)
    instead of its data segment (5C0Dh). Found with the DS-change watch of the
    simulation (2026-11-11); the CPU is not involved (the same bytes sort right in
    the CPU testbench, also with an interrupt every 20..275 cycles). Any BIOS
    string with such a year avoids it: the firmware now writes "(C)1991, Bochs
    BIOS for z486." into the BIOS's filler (85418f3). On the board (v022c,
    2026-11-11) SpeedSys runs through, its BIOS line "Bochs BIOS for z486.".
  - OS/2 Warp 4.52's boot CD (MCP2, El Torito with a 2.88 MB floppy image)
    trapped on its WARP logo screen (2026-11-10): TRAP 000D, "internal
    processing error at ##0168:fff1eb1c - 000e:cb1c, 60000, 9084". Found in the
    whole-PC simulation (2026-11-11), which ends on the same screen: a page fault
    goes through OS/2's trap gate, so IF stays set, and the RTC's IRQ 8 (OS/2's
    512 Hz clock) came at the #PF handler's first instruction. z486 cleared the
    sequencer's per-event flags only when an instruction issued, so the IRQ's
    delivery still had the #PF's error-code flag and pushed an error code too
    (16 bytes for 12); the IRQ stub's `add esp,8 / iretd` then took the #PF
    handler's EIP as CS, #GP(D7FC). Events taken at a boundary now clear the
    flags too (z486 08262e5, `irq_after_fault_errcode`), and the simulation
    boots on past that point. Not on the board yet. The simulation only got
    there with its own copy of rtc.v: Verilator saw the blocking `ce_8192hz`
    on different clocks in `periodic_start` and `periodic_major`, so the RTC's
    periodic interrupt never came (the FPGA builds a flip-flop there, so the
    core is not affected) and IBM1FLPY.ADD waited for its timeout forever.
    On v022c (2026-11-11) it got past the logo, then stopped a program with
    "c0000005 DOSCALL1.DLL 0003:0000419a" (P2 FFFFFFFF), and the simulation did
    the same (2026-11-12, after 4.29G sim_time). Not a #GP but a #TS: OS/2 keeps
    an invalid ring-2 stack in its TSS (SS2 = 0400h, RPL 0, a DPL-0 data segment
    of limit 0), so every 16-bit call gate from ring 3 into its ring-2 IOPL code
    (here DOSFSRAMSEMREQUEST, CALL at E01F:419A) raises #TS(0400h), and the #TS
    handler switches stacks itself. z486 pushed 0401h: the gate CALL's microcode
    (5B9) sets the flag that marks a CALL as nesting for a task switch, and the
    fault path's EXT test (878) read the same flag, so the CALL's own fault
    looked external and OS/2 refused it. EXT now has its own latch, set only in
    event delivery (z486 d84ee22, `call_gate16_ring2_ts`); a simulation replay
    with 0400h pushed ran on to "Loading, please wait..." with no error. On
    v022e (2026-11-12) Setup comes up and asks for the install CD; with it in,
    the kernel stopped: TRAP 000E, ERRCD 0002, CR2 0000A02C at 0168:FFF1A4AC,
    an FNSAVE [EBX] (EBX FEF1A010) saving the FPU owner's state, on its 16-bit
    ring-0 stack (SS 0030, B = 0). The microcode steps through such multi-word
    images with IN+D, and in protected mode IN+D wrapped at 64K whenever SS was
    16-bit, whatever the segment: the image's first 24 bytes went to EBX, the
    registers (from offset 1Ch) to (EBX & 0FFFFh) + 1Ch. IN+D now wraps with
    the stack's size only on SS (and during a stack switch), with the
    instruction's address size elsewhere (z486 test `x87_fsave_ss16`, FNSAVE and
    FRSTOR above 64K on a 16-bit stack, plus SGDT/SIDT; `x87_fsave_ss32` the
    same on a 32-bit stack). On v022f (2026-11-12) the swap works and Setup
    reaches LVM. After that the boot CD stopped at every reset, even with
    another hard disk image: a garbage line, then a halt at 0800:0376 in
    OS2BOOT (the boot floppy's loader). OS2BOOT reads with INT 13h AH=42h when
    it finds 'I13X' at 3000:0000; the OS/2 that ran before leaves that there,
    the Bochs BIOS has no AH=42h on the El Torito floppy, and its SYS02025 is
    printed from DS=3000. No reset cleared RAM (the Bochs BIOS has no memory
    test; loading a core over JTAG keeps the SDRAM too). The firmware's BIOS
    patch now clears conventional memory at every normal POST (fpu 60a9229;
    the shutdown returns skip it). v022g (2026-11-12): a reset with OS/2 Setup
    running boots the CD back into Setup.
    After Setup copied its files, OS/2's first boot from the hard disk froze
    every time, about 26 s in (just after its mouse driver starts): CS:EIP
    0148:7E92, interrupts pending and never taken, no memory traffic (qmon's
    L2 and L1 off changed nothing). The debug EIP is the address after the
    last issued instruction: `mov [bp+14h],ax` right after `arpl ax,bx` in a
    16-bit kernel thunk, the store spanning two 16-byte code lines. When an
    instruction ends (RNI) and the next one's bytes are not there yet, the
    microcode ROM runs on into the finished routine's next words, which never
    execute. ARPL's next word is a repeat word (it waits for a protection
    test, or for COUNTR to count down), and an interrupt's entry and IRET
    leave COUNTR at 8: z486 let that dead word repeat, which held the ROM, so
    the store's first word never loaded and the dead word repeated forever.
    A word now repeats only while an instruction is running, as the I/O wait
    already did (z486 4cdcb65; test `os2_arpl_store_intr`, OS/2's thunk with
    INTR swept across it; `_nocache` hangs the old core at the same place).
    v022h (2026-11-14): OS/2 boots from the hard disk to its graphical screen.
    CACHECHK's "Timer messed up!" may be the same, and Norton System
    Information 8.0's disk test (seeks 0.0 ms, transfer 0.0 KB/s, disk index
    2.8; PIOTEST measures 3 MB/s): a disk too fast for its timing, or the
    timer. CACHECHK's clock (26.1 MHz) is a BSR loop: z486 runs BSR/BSF with
    the 386's bit-by-bit microcode. SI 8.0's CPU index is 121.7 (its 486DX-33
    71.2, Pentium-66 211.4), the overall index 82.0 with that disk figure.
  - Tiny Core's CorePlus CD (Linux 6.18) reaches its kernel on v022c, which
    then oopses while unpacking the initramfs ("BUG: kernel NULL pointer
    dereference", in generic_perform_write) and idles. The simulation does
    the same at about 7.0G sim_time. The bad pointer is `current`, from
    `mov eax, fs:[current_task]` (64 A1) right after a RET, followed by a CALL.
    Right after a RET the A1 takes the microcode read path; its line had left
    the L1, so the read missed while the instruction retired (its translation
    was known good). The CALL's early redirect then raised a queue flush, and
    data_access dropped the outstanding read on any queue flush, so the MOV's
    deferred register write took OPR_R as it was: the previous read's value
    (ESI's in the simulation; the board's 0 fits the same path). A queue flush now leaves a
    microcode read in flight; faults and interrupt entry still end it
    (z486 test `ucrd_miss_retire`: the old core fails A1 + CALL in its first
    round). On v022e (2026-11-12) the oops is gone. The kernel then panics
    with "No working init found": with `loglevel=7`, "rootfs image is not
    initramfs (write error)" and "/initrd.image: incomplete write (-28 !=
    14122569)". That is RAM, not the CPU: the initramfs is unpacked into a
    tmpfs capped at half of RAM, core.gz holds 20.6 MB, and with 64 MB, a
    14 MB kernel and the 13.8 MB initrd still in memory the cap is reached
    before /bin/sh (busybox, near the archive's end). `rootfstype=ramfs` on
    the boot line has no cap, and the init runs (v022e). It then crawled
    after "Setting Language to C Done.", nearly every sample at 0060:C013C700,
    the FWAIT after the FNSAVE in copy_fpstate_to_sigframe(): Linux (i386,
    no FXSR) saves the x87 state straight into the user's signal frame with
    page faults off; when the save faults, it clears the frame with ordinary
    stores (which fault the page in or make it writable) and saves again.
    Two bugs kept it faulting. A TLB hit whose permissions deny the access
    raised #PF from the TLB entry, but Linux raises a PTE's permissions (R/W
    after copy-on-write) without INVLPG, so the clearing stores faulted on
    the stale entry for ever; such a hit now walks the tables again and
    faults only if they still deny it. And FNSAVE, FNSTENV, FRSTOR and
    FLDENV transfer through their 386 routines, which send the command
    first: a fault mid-transfer left the transfer open and PEREQ up, and the
    restarted routine waited at its start for PEREQ to fall, for ever,
    interrupts still taken. Such a transfer runs only inside its routine, so
    one still open when another instruction issues (the bridge idle) was
    abandoned: x87_control drops it (z486 dcf9b3a; tests
    `x87_fnsave_pf_retry`, `x87_fnsave_fwait_intr`). v022i (2026-11-14): past
    the crawl, tc-config waits for `/dev/rtc0` for ever: rtc_cmos refused
    the clock, "only 24-hr supported" (the CMOS's registers A and B, under
    Disks below; `nortc` skips the wait). With 60 MB the full CorePlus
    set of extensions does not fit: the ramfs root cannot be swapped, and
    the OOM killer takes tc-config and tce-load (no desktop, a login
    prompt). Its TinyCore entry (`lst=xbase.lst`, Xvesa and FLWM) reaches
    the desktop, but without a pointer: Linux found no mouse port (the
    8042's D3, under Mouse below; `i8042.noloop` skips that test). v022k
    (2026-11-14): TinyCore boots to its desktop, mouse working, with only
    `rootfstype=ramfs` on the boot line.
  - Native mode measures the PC's picture a line short (640x479, 720x399 at
    the DOS prompt; `qmon.py status`'s native line) and cropped SpeedSys's
    screen (its "Ver 4.78" cut at the right) in its 1:1 window; earlier it kept
    a wrong size into Windows (rows dropped) until a reset. After v0.2: first
    in simulation, native's count against the lines and pixels ascal takes in
    (p_main_native counts a line where its display enable ends), then the fix.
  - After v0.2, in this order: native's measurement (above); the x87's
    memory forms taking a pending exception (the cause is found, the fix needs
    the x87's command port: [CPU](cpu.md) 6), then what raises Chris's 3D
    Benchmark's; SpeedSys's port 61h loop (unpack it first). Done for v0.2.1,
    not on the board yet: BSF/BSR in 3 microcode words ([CPU](cpu.md)), the
    menu's boot order (CD-ROM first: El Torito), the 1351 smoothing.
  - 800x600 in True Color (VESA 115h, for v0.2.1; right on the board 2026-11-10): the HiColor
    DAC's extended register 1 reads 01h, so Tseng's BIOS takes it for type 24h and offers
    115h. The BIOS sets it through the DAC's 16-bit path (attribute 16h = A0h, CRTC 37h =
    8Bh, the CRTC counting 16-bit words: 01h = 95h, offset 12Ch = 2400 bytes), which vga.v's
    flags call 16 bit and which the board showed as stripes; the DAC's 24-bit mode (register
    3 = 09h, `vga_dac24`) now makes the wrapper read it as 24 bit, 800 wide. Every 24-bit
    picture's width comes from the CRTC (bytes / 3) instead of a fixed 640. 1024x768 in 64K
    colours (117h) the BIOS already offers and sets right (CRTC 01h = 7Fh, offset 100h,
    attribute 16h = A0h: 1024 wide, 2048-byte lines, 16 bit), and the board shows it right. `CORE/sim/build/vbe/` VBEMODES.COM (the 15/16/24-bit mode list) and VBECRTC.COM
    (the registers after 4F02h, with the DAC made type 24h) in the full-system simulation.

## What the shell does now

- `CORE/sv/z486_mega65.sv` wires z486_MiSTer's `system.sv` (CPU, chipset,
  VGA/ET4000, OPL3/SB, IDE, floppy) and its SDRAM backend (64 MB on the R6's
  IS42S16320F, with DQM) as `z486_mister.sv` does on MiSTer, plus the SVGA
  framebuffer descriptor, the SB Pro mix, and a video stream for M2M
  (positive syncs, separate blanks).
- `CORE/vhdl/mega65.vhd` maps z486's MiSTer DDR3 port into HyperRAM:
  DDR3 `0x3F800000` (the SVGA framebuffer, 4 MB) to HyperRAM `0x400000`, the
  rest (the boot image at `0x300C0000`) into `0x300000`-`0x3FFFFF`, through
  `avm_fifo` and `avm_decrease` (64 to 16 bits). The reset button resets
  HyperRAM with the core (M2M's `hr_rst`), and ascal with it. ascal's write
  request had no reset (`--avl_write_i<='0'` in M2M's ascal.vhd): a reset
  during one of its input write bursts left it high, the HyperRAM side took
  it for a new burst and waited for its beats for good. HyperRAM stopped (0
  transactions a second), the screen repeated one line, z486's boot loader
  waited for its first read (stage 2), and a long press did not help: the
  next reset caught ascal writing again. It resets now (M2M-UPSTREAM
  reset-write; `tb_ascal.vhd`'s G_RST replays it, the old ascal fails). The
  bridge's z486 side resets with HyperRAM too, and the PC waits for it.
  ascal shows the framebuffer
  from HyperRAM (M2M-UPSTREAM rtg-framebuffer). Below `0x300000` ascal keeps
  three frames of the VGA picture (triple buffering): the PC's frames (60 Hz
  but not locked to the HDMI output's, or 70 Hz text with "Refresh: Original")
  otherwise showed half-old, half-new frames where the screen
  changed (a flickering clock, stray lines, the cursor). The scaler
  interpolates sharp bilinear by default: the 720x400 text mode scales by 1.2
  (480p, 720x480) or 1.8 (720p), and nearest-neighbour made diagonal strokes
  uneven. The menu's "Filter" switches it (Sharp, Smooth = bilinear, Pixels =
  nearest neighbour). The CRT emulation is a stage behind ascal
  (`crt_post.vhd`, M2M-UPSTREAM crt-post, `digital_pipeline.vhd`), one HDMI
  pixel a clock: CRT colours (gamma 1.15 and 1/8 less saturation), scanlines,
  a soft beam ([1 4 6 4 1] / 16 across), a phosphor mask by output pixel
  (MiSTer's shadowmask.sv way, at half strength) and glow (what is above 96,
  blurred over 7 pixels and this and two lines up, half of it added back). The
  scanlines sit on the PC's own lines at any scale: ascal passes each output
  line's place between two input lines (its vertical fraction, `o_vline_frac`)
  and the input line's lowest bit (`o_vline_odd`) with the pixels, and the
  stage weights the line by an electron beam's profile across the gap, wider
  on bright pixels (a table of curves by place and brightness). For the TV
  scanlines the beam is a pair of input lines high, but only while the VGA
  repeats each row (CR09 bit 7 or maximum scan line 1: vga.v's
  `vertical_doublescan`, brought out by `tools/z486_sources.py`): 320x200 gets
  200 scanlines, text and 640x480 one a line. The menu's "CRT" picks a set:
  VGA monitor, TV (200 lines), Trinitron. The old "Scanlines" (every second
  output line darker) lined up with the PC's lines only in 1280x1024; in the
  other modes the dark lines beat into bands.
  `CORE/sim/run_crt_post.sh` runs the stage (everything off passes the picture
  through); `run_ascal.sh` run 6 checks ascal's line position and pair bit
  against the pixels.
  ascal's bilinear path (Smooth, Sharp) left one clock before the nearest one
  and wrote every pixel one output pixel to the left: the picture moved left,
  at 800x600 the PC's first column was gone, and thin strokes broke (the top
  of a "6"). It now runs one stage later (M2M-UPSTREAM filter-align); Smooth
  matches a centre-aligned bilinear exactly, Sharp's edges sit where Pixels'
  do (`CORE/sim/tb_ascal.vhd` with `G_PAT=1`: "68" text at 720x400 into
  1280x960 and 800x600).
- Clocks (`CORE/vhdl/clk.vhd`): 66 MHz for the PC and the video, 24.558 MHz
  for OPL3/SB (MiSTer uses 24.576 MHz; 0.07 % slow, about 1.3 cents), one
  MMCM at VCO 660 MHz.
- The SDRAM clock is a third output of that MMCM at 292.5 degrees, through an
  ODDR (see [SDRAM clock](sdram-clock.md)). `sdram.v`'s shortcut below 75 MHz
  (one cycle for tRCD and tRP, 15.2 ns at 66 MHz, under the chip's 18 ns) is
  patched out in the build copy (`tools/z486_sources.py`): two cycles each.
- BIOS: at startup the firmware (`CORE/m2m-rom/m2m-rom.asm`, `PREP_START`)
  loads `boot1.rom` (VGA BIOS, to `0xC0000`) and `boot0.rom` (system BIOS, to
  `0xF0000`, or `0xE0000` if above 64 KB) from the SD card into the HyperRAM
  window z486's boot loader copies from (`0x3C0000`, 256 KB, cleared first).
  The PC stays in reset until they are in (QNICE device `C_DEV_PC_CTL`,
  `mega65.vhd`). A missing or unreadable ROM stops with a message on screen.
  The framework's own ROM auto-loader is not used: it writes one byte per
  HyperRAM word, and z486 reads the ROMs packed.
- Firmware space: the QNICE ROM holds 28,286 of its 32,768 words. The FAT32
  write layer (the Shell's settings file) lives in code banks 0 and 1, 4K-word
  banks behind the window 0x9000-0x9FFF (Megamiga's code-banks, as in MegaMac),
  called through `FAR_CALL` stubs; six banks are free.
- Keyboard: the MEGA65 keyboard is the PC's PS/2 keyboard
  (`CORE/vhdl/pc_keyboard.vhd`, `ps2_device.vhd`): scan code set 2, which the
  PC's 8042 translates to set 1, typematic repeat, and the replies to the
  BIOS's keyboard commands, which MiSTer's ARM side gives there. See
  [Keyboard](../README.md#keyboard).
- Mouse: an Amiga mouse on joystick port 1, or a USB mouse behind a mouSTer in
  Amiga mode, is the PC's PS/2 mouse (`CORE/vhdl/pc_mouse.vhd`): its
  quadrature lines as MegaMac decodes them, the left button on pin 6. The
  right button (pin 9) is invisible to the MEGA65's paddle circuit (Megamiga
  measured it, and the R6 is no different), so F13 stands in for it. A mouSTer
  (firmware 3.23.5313 on) with `activepotlines=true` drives pins 9 and 5 high
  while its right and middle buttons are up: they read as a SID value of 0,
  and 255 (open) while held, nothing in between (measured 2026-11-07). A line
  that has read driven is a button from then on; both open for 2 s (unplugged)
  drops that. Such lines used to make the core take the mouse for a 1351
  (driven = under 254) and stop counting its quadrature; a 1351 is now only
  mid-range values (4..251, as `mouse_input.vhdl` takes it), and a step on pins
  2..4, which a 1351 never moves, makes it an Amiga mouse at once
  (`CORE/sim/run_pc_mouse.sh`). For a
  real right button, use a Commodore 1351 or a mouSTer in its C64 mode
  (`c1351`, `mode=mouse` in its INI): its position on the paddle lines, the
  right button on pin 1. The core finds a 1351 by itself (its paddle lines
  read driven for 0.1 s) and goes back to Amiga mode half a second after
  they read open. Its x is on POT X (pin 9), its y on POT Y (pin 5), as on a
  C64; `qmon.py c1351` shows the mode and reverses or swaps axes that run the
  wrong way. The mouse answers the BIOS's and the
  drivers' commands (reset, identify, sample rate, status, ...) like a
  standard PS/2 mouse, also when nothing is plugged in: the BIOS's mouse
  functions, which CuteMouse calls, wait for good for a mouse that does not
  answer. After any byte from the PC it sends no packets for 300 ms (the
  motion waits): the Bochs BIOS's mouse functions take the byte after their
  command as its answer and leave the mouse port off when it was no FA, so
  a packet in the middle of CuteMouse's set-up (F4, then F3 and its byte)
  left the mouse dead, or its packets read a byte off (the pointer jumping
  from edge to edge). The 7th Guest hit it at its start, in native mode
  nearly every time; the debug log showed it. `CORE/sim/run_ps2.sh`
  simulates the keyboard and the mouse against z486's 8042 (`ps2.v`;
  `tb_pc_mouse` has a packet in the middle of F3, which fails without the
  quiet time), and the PIC patch below (`tb_pic.sv`). The 8042 (`ps2.v`
  patched by `tools/z486_sources.py`) keeps the mouse's bytes in a FIFO,
  which an 8042 does not have: they wait there while the mouse port is off
  and from a D4 byte until it has gone out, and a D4 byte drops them
  (Windows, quitting, turns the port off, sends D4 F4 and wants FA next). A
  D3 byte (the PC's own, as if from the mouse) drops them as well and comes
  out at once, also while the port is off: Linux's probe (i8042_check_aux)
  loops 5Ah back with the port off, and when that byte waited with the
  others, Linux took the port for absent (TinyCore's X without a pointer;
  `tb_i8042_aux` runs the probe, 251290e).
- The BIOS's mouse packets: the Bochs BIOS files the mouse's bytes by
  position (its IRQ12 handler, F000:51B8; the position in EBDA 26h) and never
  checks a packet's first byte, so one lost byte puts every packet after it
  a byte off until the driver initialises the mouse again (INT 15h C205):
  the pointer jumps between the screen edges. A program that resets the
  mouse driver (INT 33h 0) while a packet is on its way loses the rest of
  it: the driver's commands (C200 enable, C202 sample rate) drop it, as
  they would on a real PC. The I/O trace showed both programs' resets and
  the packets aligned on the 8042 (Phantasmagoria and EDIT, about one start
  in five while the mouse moved). The firmware gives z486_MiSTer's
  `boot0.rom` (64 KB, two checksums) the check other BIOSes and mouse
  drivers have, in its HyperRAM copy before the PC starts: at F000:5209 the
  handler calls F000:E000 (filler before the POST entry), which drops a byte
  at position 0 without bit 3 (`CORE/m2m-rom/bios_patch.asm`). Another
  BIOS file stays as it is. `tools/bios_patch.py` makes the patch from the
  file and checks the original code; `CORE/m2m-rom/test/bios_run.sh` runs
  the firmware's part in the QNICE emulator; `qmon.py bios` reads the
  patched words back from the board.
- Joystick: a joystick on port 2 is the PC's game port joystick at 201h
  (z486_MiSTer's `joystick.v`, as a 4-button joystick; the second joystick
  absent). The directions put the axes at their ends, fire is button 1. A
  second and third fire button on the paddle lines (the C64 two- and
  three-button joysticks, which connect them to +5 V) are buttons 2 and 3:
  the second on pin 9 (POT X, as the C64GS's), or on pin 5 for sticks that
  have it there ("Joystick fire 2" in the menu); the third on the other one.
  A button that grounds pin 9 (Amiga style) is invisible, like the Amiga
  mouse's right button. `qmon.py status` shows what is held, `qmon.py joy`
  every change. The menu's joystick "Timing" sets `joystick.v`'s `timed`
  input (2026-11-18): "Timed" (0, the default) counts the axes down by the
  IBM formula in 1.1 us steps (centre ~0.58 ms); "Count" (3, MiSTer's "Count
  6+256") one step per read of 201h. Jazz Jackrabbit counts its reads up to
  about 1000 (a note in `joystick.v`), and this port answers faster than an
  ISA card: with "Timed" its count ran out before the centre, and the
  calibration stayed at the lower right; with "Count" any loop speed works.
  TIE Fighter, which with "Timed" saw the stick only when it was held to the
  upper left while the game started (on ao486 on MiSTer too), finds it with
  "Count" (on the board, 2026-11-19).
  Port 2's directions and fire are debounced in `mega65.vhd`'s `p_main_joy`
  (2026-11-18): the framework passes the DB9 lines raw (`M2M/vhdl/debouncer.vhd`
  is two flip-flops, since its 1 ms filter swallowed the Amiga mouse's
  quadrature on port 1), so a switch's bounce reached the game port as extra
  presses. A line's new state counts once it has differed for 5 millisecond
  ticks in a row (4 to 5 ms late), a blip back restarts the count; port 1
  stays raw. Jazz Jackrabbit's menus still step about every 30 ms while the
  stick is held: that is the game's own repeat.
- Disks (`CORE/vhdl/disk_sd.vhd`, `pc_mgmt.vhd`): MiSTer's ARM side, which
  serves z486's floppy and IDE controllers and fills the CMOS through the
  management bus, is in hardware (`pc_mgmt`): at power-up the CMOS
  (registers A = 26h and B = 02h as x86_init writes them: the Bochs BIOS
  never sets them at POST, rtc.v's start at 00h, and register B's 12-hour
  mode made Linux's rtc_cmos refuse the clock, 02665f7;
  equipment, base memory, checksum, the date and time from the MEGA65's RTC,
  again when the RTC's first read arrives and whenever the PC restarts: the reset
  button, "Reset the PC", and the keyboard controller's reset, port 64h <- FEh,
  which Bochs' BIOS uses for Ctrl+Alt+Del and Windows for a restart; the PC's
  CMOS clock otherwise runs on from whatever it was set to);
  then floppy drives A: and B: (`floppy.v`: insert/eject, the sector
  requests) and the hard disk, the master of the first IDE channel (`ide.v`:
  IDENTIFY, reads and writes, one sector per block; 16 heads x 63 sectors,
  the cylinders the size / 1008, at most 16383, and CHS addresses by that
  geometry: Main_MiSTer's `ide.cpp` says 256 sectors a track for a raw image,
  which Linux 2.0-2.4 keep in a byte, so DSL 4.4.10's kernel divided by 0 in
  `init_idedisk_capacity`; the BIOS's LBA translation takes the capacity
  only, so partitions stay where they were), with the CMOS's drive
  types following the images; the CD-ROM drive, an ATAPI device on the second
  channel (`pc_cdrom.vhd`, what Main_MiSTer's `ide_cdrom.cpp` does, with
  `cd_audio.vhd` for CD audio and the firmware's `cdimage.asm` for cue sheets),
  which `pc_mgmt` lets onto the management bus when it is idle. Windows 95's
  own driver for the channel, `esdi_506.pdr`, hung in its init of the CD-ROM's
  channel (normal boot only: no disk I/O, the VMM on the timer; with the
  controller removed it used OAKCDROM/MSCDEX). Every good status the drive gave
  had bit 4 set (58h, 5Ch, 5Eh, 54h), which is DSC on a hard disk but SERVICE
  on a packet device: an overlapped command wanting service. Main_MiSTer found
  `esdi_506` rejects the channel then (its #1221 and #1224, Code 10 there);
  bit 4 is now 0 (48h, 4Ch, 4Eh, 44h), except DSC when SEEK is done, which
  VIDE-CDD.SYS waits for (#1239). Windows 95 then finds the drive: AutoRun,
  AVIs from the CD, CD Player (`z486-R6-cdsvc`, 2026-11-08). The rest of what
  the drive answers matches Main_MiSTer's choices (DEVICE RESET status 00h,
  the diagnostic code 01h after a reset, INQUIRY and REQUEST SENSE exempt from
  a pending UNIT ATTENTION); Main_MiSTer's `ide.cpp`/`ide_cdrom.cpp` are the
  reference for these. `disk_sd` reads and writes straight in the
  image file through the SD host controller's engine port (Megamiga's
  sd-host), with the file's extent map from the firmware (fragmented files are
  fine); reads come in runs of one SD command each through a 32-sector ring
  in LUT RAM, every copy out of it checked against the checksum of what went
  in (a sector that does not match comes again, fresh from the card); the
  write buffer is LUT RAM too. See [Disks](disks.md). `CORE/sim/run_disks.sh` simulates them against z486's
  `floppy.v`, `ide.v` and `rtc.v` (`tb_cdrom.sv`: both IDE channels, the
  packets a DOS CD-ROM driver sends, an ISO and a disc with data and audio
  tracks: raw reads, the TOC, PLAY sample by sample); `CORE/m2m-rom/test/run.sh`
  runs `cdimage.asm` in the QNICE emulator on FAT32 images (mtools) with ISO,
  BIN and cue sheets, checked against its own layout of the disc.
- Menu: floppy A:, floppy B:, the internal drive (off, sounds, drive A: or
  drive B:), hard disk, CD-ROM, real floppy speed, HDMI mode, filter, CRT
  (off, VGA monitor, TV, Trinitron), refresh ("60 Hz (HDMI)" or "Original (VGA)"), the joystick's fire 2 (pin 9 or pin 5),
  help, "Reset the PC".
  The internal drive's Sounds is only available with "Real floppy speed" (the
  Megamiga fork's menu-rows rule, config.vhd `OPTM_AVAIL`, served through
  `SEL_OPTM_ROWS`; for a single-select mother `menu.asm` takes mask 1 as "while
  it is on" and mask 0 as "while it is off", and switching one off now also
  deselects and redraws); a greyed-out selection moves to the group's first
  available item, which is why Off comes first, and mega65.vhd treats Sounds
  as Off without real speed.
- The hard disk the menu mounted last comes back at the next start: the
  settings file's text (cfg-strings) keeps `hdd=<path>`, `hdd=none` after
  "<No Disk>"; without the key (or when that file is gone) `/z486/hdd.img`.
  The FAT32 handle only knows a directory's cluster, so the file browser now
  tracks its directory as a path (M2M-UPSTREAM fb-path: `FB_PATH`, `FBP_SET`
  and `FBP_CD` in `selectfile.asm`; `LOAD_IMAGE` hands the file's name over in
  `LI_FNAME`). It is opened from the card of the settings file. An image
  mounted at start-up
  (`/z486/hdd.img`, `/z486/cdrom.cue` or `.iso`, `/z486/floppy.img`) shows its name
  once the menu opens (`DAN_FLUSH`): the
  menu has no memory before that, and the line read "Hard disk:  Hard
  dis..." (the line's own text taken for the name).
- HDMI modes: 720p 60 Hz (the PC's 4:3 picture between bars), 480p, 800x600,
  1024x768, 1280x960 and 1280x1024 at 60 Hz, and "Native resolution": the HDMI output
  follows the PC's own picture size and the monitor does the only scaling
  (M2M-UPSTREAM native, `digital_pipeline.vhd`: ascal's window is the
  picture's size in the middle of the output). `mega65.vhd` measures the
  picture as ascal sees it (the widest line's pixels, the lines of a frame;
  a size counts once it held for eight frames) and picks the smallest mode it
  fits into: 720x400 text in 720x480 (40 lines of bars), 640x480 and 640x400
  in 640x480, SVGA 800x600 and 1024x768 in their own modes; 320- and
  360-pixel lines and 200-line modes come doubled (the core gives them
  without the VGA's doubling), so 320x200 is 640x400. Native uses nearest
  neighbour and no scanlines, and the monitor resyncs when the PC changes
  mode, as a real VGA monitor does. On an R6 with a 1280x1024 monitor the DOS
  prompt came out as 720x480 and The 7th Guest's VESA screens as 640x480,
  switching by themselves. The HDMI modes all exist already; the
  PC's frames go out at the HDMI mode's 60 Hz (ascal's triple buffering).
  With "Refresh: Original (VGA)" the PC runs its 400- and 350-line modes at
  70 Hz, and native mode follows with a VGA card's own 640x400 or 720x400 at
  70 Hz (M2M-UPSTREAM vga70: new modes in `video_modes_pkg.vhd`; `mega65.vhd`
  counts main_clk's clocks from one vblank to the next and calls a frame
  shorter than 1/65 s "70 Hz", held for the same eight frames as the size),
  instead of 640x480 or 720x480 at 60 Hz, which dropped one PC frame in
  seven. 720x400 at 70 Hz is an EDID established timing, so VGA-era monitors
  list it; TVs may refuse both. The PC's and the HDMI's 70 Hz come from
  different clocks, so the scaler still repeats or drops a frame about once a
  minute. 640x400 uses the HDMI clock's 25.175 MHz entry and 720x400 a new
  28.333 MHz one (28.322 MHz on a VGA card, +0.04 %) in place of 27.027 MHz,
  which no mode used. Both unused entries had the NO_COUNT bit set on the
  serialiser clock's divider, which made it the VCO's 881 or 1081 MHz
  instead of five times the pixel clock: `CORE/sim/run_video_clock.sh`
  programs every entry into Vivado's MMCME2_ADV model and measures both
  clocks (all eight right now; the six the modes used already were).
  1280x960 runs on the same 90 MHz and 63.2 kHz lines with 1053 lines a frame
  (60.02 Hz, CVT-RB's 4:3 sync width): the 4:3 picture fills it, 640x480
  doubled exactly, for a monitor that scales a 4:3 input to its height (a
  1440-line ultrawide in its 4:3 setting scales it 1.5x).
  1280x1024 is a 5:4 monitor's own resolution: the picture is 1280x960 between bars and the monitor scales
  nothing, where 480p or 720p are scaled twice (by the core and by the
  monitor). It uses reduced blanking (the 63.2 kHz / 59.79 Hz of VESA's
  CVT-RB) at 90 MHz: VESA's DMT timing needs 108 MHz, at which the HDMI
  domain misses timing (the menu overlay's blending). The 90 MHz is a new
  entry in the framework's HDMI clock (M2M-UPSTREAM sxga-mode:
  `video_out_clock.vhd`, values from Xilinx's MMCM functions; the HDMI
  domain is timed at it), and the scaler is built without its bicubic and
  polyphase interpolators (`ASCAL_MASK` in `globals.vhd`), whose DSP paths
  were the slowest of that domain. Its 15.8 µs lines are shorter than the
  scaler's fetch of a 640-pixel line from the HyperRAM (15 bursts, ~13-20
  µs with the input's writes in between); ascal's line accounting waited for
  each fetch, fell behind, missed the start of the frame and showed noise.
  The fetches now run on their own from a queue (M2M-UPSTREAM late-fetch,
  `ascal.vhd`), so the accounting keeps the display's time;
  `CORE/sim/run_ascal.sh` compares ascal with a slow memory against a fast
  one. On a 5:4 monitor 1280x1024 is the sharpest mode by far: 800x600 is
  1.25x (every fourth pixel doubled, then smoothed) and the monitor scales
  it again.
- The scaler's own HyperRAM traffic: the PC's VGA picture (text, VGA and the
  planar Super VGA modes; the 256-colour and HiColor modes are a framebuffer
  ascal reads directly) is written into ascal's buffer and read back for
  HDMI, at 24 bit. 800x600 at 60 Hz is 86 MB/s each way, 172 MB/s, where the
  HyperRAM gives about 160 MB/s (100 MHz, 16 bit, 128-byte bursts): Windows
  3.11's "Super VGA (800x600, 16 colors)" flickered, jumped and drew stray
  lines (on v0.1 too), though the PC drew it right (the full-system
  simulation and QEMU agree). Pictures wider than 720 pixels now go through
  at 16 bit, 565 (`scaler_16bpp` in `z486_mega65.sv`, M2M-UPSTREAM
  scaler-16bpp): 115 MB/s at 800x600, and red and blue at 5 bits leave the
  16 colours at most 3/255 off. 640x480 and text stay at 24 bit (110 MB/s).
  ascal's 16-bit mode had a bug of its own: at the end of a line its burst
  count's step and the next line's reset came in the same clock, so every
  other line was never written (M2M-UPSTREAM 16bpp-eol). `scaler_16bpp`
  changes only with the PC's mode; `CORE.xdc` cuts its crossing into
  hdmi_clk as it does the framebuffer descriptor's.
- The HiColor DAC. Tseng's VGA BIOS (V8.00N) sets HiColor and TrueColor modes
  through the DAC's registers (int 10h AX=10F0h) and reads the mode back
  (10F2h), which the VESA call 4F03h (the current mode) asks. vga.v had no DAC
  registers: after 4F02h set 110h or 111h (640x480, 15 or 16 bit) 4F03h said
  101h (256 colours), and every 16-bit picture went out as 555, red and green
  ramps restarting halfway. vga.v now has the command register behind four
  reads of 3C6h and the extended registers its bit 4 opens, as the BIOS
  programs them for its DAC type 20h (Sierra SC1502x-like; 86Box pairs
  Tseng's V8 BIOS with that DAC), patched in by `tools/z486_sources.py`; the
  framebuffer format follows it, 565 for 16 bit, 1555 for 15 bit. Register
  index 8 bits, only 0..7 kept: at power-on the BIOS loads 34 bytes from
  index 20h, which a 3-bit index wrapped onto register 1, and the BIOS then
  took the DAC for type 24h and offered 800x600 at 24 bit (115h), which the
  display (24-bit pictures 640 wide) cannot show. `CORE/sim/build/vbe/` (not
  in git) has the checks: VBEPROBE.COM (what the VESA BIOS offers and reads
  back), HICOL.COM (ramps in any 15/16/24-bit mode), GRAD.BMP.
- VGA connector: the PC's own picture (the framework's analog pipeline, not
  the scaler). An analog monitor has to work out each line's pixel count from
  the timing, and a VGA card helps it with the sync polarity (the misc output
  register, port 3C2h: +/- 350 lines, -/+ 400, -/- 480). Two things broke
  that: MiSTer's `video_cleaner` makes both syncs active-high (as the scaler
  wants), and z486's `video_f60` retimes every mode to 60 Hz, so DOS text had
  26.9 kHz lines instead of 31.5 kHz. A Dell called it "640x350 at 60 Hz",
  sampled the 720-pixel lines with the wrong clock (strokes of uneven width,
  a shimmer, edges cut off) and its auto adjust could not fix it. The menu's
  "Refresh" now chooses: "60 Hz (HDMI)" (the default, as before) or
  "Original (VGA)" (`video_f60` off: the VGA's own timing, DOS text at 70 Hz),
  and the connector carried the polarity the PC wrote to 3C2h (M2M-UPSTREAM
  vga-polarity: `mega65.vhd` takes the bits from the PC's I/O writes,
  `analog_pipeline.vhd` turned the connector's syncs). On the board
  (`z486-R6-vgasdb`) the Dell and an Eizo both took it as 70 Hz text, and
  both still shimmered, flickered and cut the first column. The analog
  pipeline runs on the PC's video clock, main_clk (64 MHz then), with z486's
  clock enable: a 28.322 MHz pixel lasts 2 or 3 of its clocks (31.3 or 46.9
  ns, not 35.3), so every pixel edge, and the syncs, land up to 15.6 ns (half
  a pixel) off, differently on each line. A CRT barely shows it; an LCD
  samples each pixel at a fixed time after the sync, sometimes on an edge.
  So the connector now shows the HDMI picture (M2M-UPSTREAM vga-from-hdmi,
  `digital_pipeline.vhd`): the scaler's output with the menu on it, on the
  HDMI clock (an MMCM's), black outside the picture, the syncs in the mode's
  polarity, the DAC clocked by the HDMI clock (`pblock_vga` in
  `MEGA65-R6.xdc` keeps the output registers by the pins). In native mode
  with "Original (VGA)" that is what a VGA card sends (720x400 or 640x400 at
  70 Hz; 640x480, 800x600 and 1024x768 at 60 Hz; their polarities) on a
  steady clock; in the other HDMI modes the VGA connector carries those
  (720p, 480p, ...). The analog pipeline's VGA outputs are unused. On the
  board (`z486-R6-vga70b`) the Dell shows DOS text as 720x400 at 70 Hz, clean,
  the first column whole; HDMI is at 70 Hz in DOS too.
- The MEGA65's clock: the framework reads the RTC once when it starts and
  keeps a running copy, which the core copies into the PC's CMOS. Straight
  after power-on, on an R6, that read came back as junk twice (day 00, month
  06, year B1/E1, time 00:00) while a read a minute later was right, and
  `rtc_master.vhd`'s check (day and month both 00) let it through: DOS started
  at midnight. Every field is checked now (BCD, in range), a bad read is tried
  again every 20 ms, and after 100 (2 s) it starts from 2000-01-01
  (M2M-UPSTREAM rtc-verify; `CORE/sim/run_rtc_master.sh` feeds it that junk).
- Drive LED (`mega65.vhd`): the PC's disk accesses, as a case LED shows a
  drive's activity line: amber while the hard disk or the CD-ROM drive has a
  command or a block in hand, green for the floppies, at least 40 ms each.
- Drive sounds (`fdd_sound.vhd`): the MEGA65's internal floppy drive follows
  the PC's floppy drives, which are images on the SD card. `floppy.v` (a patch
  in `tools/z486_sources.py`) says which drive is selected, whose motor is on
  and which cylinder each one's head is on (SEEK, RECALIBRATE, a read's or
  write's implied seek). The drive is selected while the PC has a floppy motor
  on (its own LED lights, as a PC drive's does) and while its head moves; its
  motor runs with the PC's; its head steps after the selected drive's
  cylinder, one step every 4 ms (a 3.5" drive takes 3), DIR set 10 us before
  each 4 us STEP pulse, at most to cylinder 79. Going out to cylinder 0 it
  steps until TRACK0 shows (up to 10 steps more, for a lost step), and TRACK0
  seen anywhere sets the head to 0. At the start (power-up, the menu's "On")
  it steps in once and then out to TRACK0, at most 90 steps; a drive that
  never shows TRACK0 is left alone. WGATE, WDATA, SIDE1 and DENSITY stay high:
  it never writes.
  A disk in the drive keeps the motor off (only the head moves), so a real
  disk doesn't spin under its heads for nothing. DSKCHG latches when a disk
  comes out and clears on a step with one in, as on a PC: every step's end
  reads it. A disk put in while the head stands still leaves DSKCHG latched
  until the next step, so INDEX tells it: two index pulses while the motor
  runs stop the motor (after about 200-400 ms of spinning) and a step away and
  back asks DSKCHG. If DSKCHG then says there is no disk, the mechanism sends
  INDEX without one, and INDEX is not used again until the next start.
  DSKCHG going active while the drive is selected means the disk came out.
  The menu's "Internal drive" (Off, the default; Sounds) switches it; Sounds
  only with "Real floppy speed".
- Real floppy speed (`floppy.v`'s `real_speed`, a patch in
  `tools/z486_sources.py`; off by default): without it an image's sector
  costs 62 us, the SD card's speed, and only SEEK and RECALIBRATE step at the
  SPECIFY rate. With it, each sector of a read, write or FORMAT waits in
  `S_PREPARE` until it has passed under the head of a simulated disk: 300 rpm
  (360 rpm at 15 sectors per track, a 1.2 MB disk), sector R in slot R-1 of a
  turn, so a track takes one turn and a sector one slot (11 ms at 18 sectors).
  A read's or write's implied seek (the Bochs BIOS never sends SEEK) waits
  first: (16 - SRT) units a step, as an 82077 steps, and 15 units to settle,
  in floppy.v's SEEK units (1 ms at 500 kbit/s, 2 ms at 250). The internal
  drive (`ext_chg_en`) is a real one and never waits. Not modelled: the
  motor's spin-up and READ ID's wait for an ID field.
  `CORE/sim/run_floppy_err.sh` checks the slots, a seek and the internal
  drive's exemption.
  `CORE/sim/run_fdd_sound.sh` runs it against a model of the drive (TRACK0,
  DSKCHG, INDEX, a drive with INDEX without a disk, one without TRACK0) and
  checks every step pulse's timing.
- Sound Blaster pops: z486's DSP holds its last sample when it stops (a DMA
  pause, the end of a transfer) and drops to 0 when it mutes (speaker off in
  SB Pro mode, the 80h silence), so a level a sound ends on stays until the
  next sound jumps away from it, or a mute steps from it (King's Quest VI's
  speech: the driver pauses with D0h after the last block; the end of a WAV in
  an editor). The I/O trace now also logs the DSP's own output jumps and why
  (`qmon.py iotrace`), and an output stage (`CORE/sv/sb_soft.sv`, before the
  mix) passes samples as they are while the DSP plays, lets a level held 20 ms
  glide to 0 (21 ms time constant) and fades a mute (2.7 ms). DOOM's stream,
  back-to-back effects with gaps under 20 ms, a sharp attack and a 10 ms pause
  come out sample for sample unchanged (`CORE/sim/run_sb_soft.sh`);
  `qmon.py sbsoft off` turns it off on the board, to listen both ways. Not on
  the board yet.
- L2 cache (`CORE/sv/guest_l2.sv`, after MegaMac's): 256 KB of block RAM
  between the CPU's memory port and the SDRAM, as on a 486 board:
  direct-mapped, 16-byte lines, write-through. A line fill that hits is
  answered from the cache; stores update cached lines; floppy and Sound
  Blaster DMA (the SDRAM's second port) drop their lines before the CPU's
  next lookup. `tools/qmon.py l2` shows the fills from the cache and from the
  SDRAM, `l2 off` / `l2 on` switch it for comparisons (`l1 off` / `l1 on`
  z486's own L1 caches: off, every access goes uncached; after on, reset the
  PC). `CORE/sim/run_l2.sh`
  checks it against a memory model with DMA writes and switching. Measured
  (2026-10-31, the same build): Doom's `-timedemo demo3` 35.7 fps without,
  36.9 fps with it (+3.5%), 76% of the line fills from the cache: Doom's hot
  data mostly fits z486's own 8 + 8 KB. Dr. Hardware: average RAM throughput
  24.5 -> 31.4 MB/s (+28%; blocks between the L1's 16 KB and 256 KB), the
  minimum (beyond 256 KB) and maximum (within the L1) unchanged, Hardstones
  26345 -> 27418 (+4%). Off since the 512 KB Ultrasound (2026-11-17,
  `L2_IDX` 0 in `z486_mega65.sv`: its enable tied off, 4 index bits left):
  its 69 block RAMs hold the sample RAM's second half, and 64 KB of L2 beside
  the 512 KB didn't route (the CPU's area congested). Without it (Dr.
  Hardware, the same setup): Hardstones 27832 -> 27273 (-2%), Softstones
  8612 the same, RAM minimum -15%, standard -22%, Memory Performance -15%;
  Quake's `timedemo demo1` 7.9 -> 7.8 fps. z486's L1 caches doubled to
  16 KB + 16 KB (`DCACHE_SET_BITS` / `ICACHE_SET_BITS` 8 in `z486_mega65.sv`;
  z486_MiSTer's build has 7, 8 KB + 8 KB) more than make up for it
  (2026-11-18, v022l1v, 2 more block RAM tiles): Hardstones 28426 (+2% over
  the L2 build, +4% over 8 + 8 KB without it), Softstones 8612, RAM maximum
  42.1, minimum 27.2 (+19% / +40%), standard 41.8 (+29% / +65%), Memory
  Performance 113.3 (80.6 without the L2); Quake's `timedemo demo1` 8.0 fps
  (7.9 with the L2, 7.8 without it). Placed on the 8 + 8 KB layout
  (incremental) it met the real 66 MHz by only 0.083 ns, its slowest paths the
  address unit's as ever; placed fresh, 0.471 ns.
- Gravis Ultrasound (`CORE/sv/gus.sv`, 2026-11-16): nukeykt's LPC-GUS GF1
  model (`CORE/sv/gus/gf1.v`, unchanged, GPL-2.0-or-later; built from a die
  shot) with the card around it, as its `gf1_lpc.v` is for a PC's LPC bus:
  ports at 240h (the GF1 at 2x6, 2x8, 2x9, 2xA, 2xC, 2xE, 3x2-3x5, 3x7; the mix
  control 2x0 and the IRQ/DMA latch 2xB; no MIDI; base+106h reads FFh, a
  classic card before rev 3.7; the writes to AdLib's 388/389 too, as the
  GF1's 2x8/2x9, the reads there staying the OPL3's: Gravis' CARDCHK.EXE,
  run by INSTALL 4.11, finds the card by 55h/AAh to 388 read back at 2xA, and
  reports "cannot determine card type" without it), 512 KB of sample DRAM in
  block RAM (banks 0 and 1; banks 2-3 read FFh, so the size test finds 512 KB;
  `RAM_KB` 256 keeps bank 0 alone), the
  DAC's serial words as 16-bit samples, the GF1's 9.8784 MHz as a phase
  accumulator on main_clk. A GF1 access is an ISA-like cycle (IOR/IOW, DACK1
  for the DMA, at least 150 ns and while the GF1 holds WAIT, the byte taken
  3 clocks after); the CPU waits in `iobus_adapter.sv`, which got an
  `io_hold` for it (`tools/z486_sources.py`; nothing else holds a byte
  cycle). DMA channel 3 only: dma.v acknowledges a byte for one clock and
  gives its TC the clock after, so the wrapper takes byte and TC then (taking
  TC with the acknowledge missed it: on the board XTC-Play's first upload
  never ended, no TC IRQ). The DRAM DMA also goes the other way (41h bit 1,
  the DRAM to the PC: Gravis Setup's playback DMA test reads back): dma.v
  takes a device's byte as it starts the transfer, so the wrapper fetches
  the GF1's byte first (DACK1 + IOR when it asks) and then asks the 8237;
  TC comes after the byte, so one more DACK1 + IOR carries it to the GF1
  (that byte is dropped), which ends the DMA and raises its IRQ. The
  wrapper sees the direction in the CPU's 41h writes. Sampling (48h, 49h;
  the GF1 model has none, its DRQ2 is 0) is the wrapper's: silence (80h,
  00h with the MSB inverted) every 16 x (48h + 2) GF1 clocks, two bytes in
  stereo, on the record DMA (the latch's second channel or the first
  combined: DMA 3 only); its TC ends it, sets 49h bit 6 (read clears it)
  and with 49h bit 5 raises the GF1's IRQ and 2x6 bit 7. The sample RAM
  answers each CAS's address until the next CAS: the GF1's DMA read latch
  stays open to the end of its slot, after the refresh's RAS (row 0) that
  follows, and with the RAM read at the current row the DMA brought back
  DRAM 0's bytes. The IRQ goes where the latch puts it, ORed into
  the PICs' inputs. It starts as after ULTRINIT with
  `ULTRASND=240,3,3,11,11` (latches on, line out on). Its samples are added
  after the SB Pro mixer, at their own level: the SB's volumes don't touch
  it. The menu's "Sound" submenu (SB16, GUS, SB16 + GUS: the default)
  chooses the cards: `gus_enable` removes the GUS, `sb_enable` the SB16's
  ports at 220-22F (its `sb_cs`; the DSP then never starts). AdLib's OPL3 at
  388h (`fm_cs`) and the CD audio stay in every mode, through the SB16
  mixer's last levels. The summary line is cut at 22 characters (options.asm,
  OPTM_DX - 2): hence the short names.
  Out of context the GF1 is 1,191 LUTs, 1,873 FFs, 2.5 block RAMs and a DSP;
  the sample RAM is 128 block RAMs at 512 KB. `CORE/sim/run_gus.sh` (iverilog; `run_gus.sh 256`
  for the small RAM) runs the
  GUS SDK's steps through the adapter: reset, active voices, the size test,
  poke/peek, a DMA upload through system.sv's dma.v (the 8237 set up as the
  SDK does; `CORE/sim/hoist_decls.py` makes an iverilog copy of dma.v) with
  its TC IRQ, a looping voice at the DAC (one
  sample a frame at 44.1 kHz with 14 voices), a voice register read back,
  the wave-end IRQ, timer 1 on IRQ 7 through the latch, the menu's off, and
  CARDCHK's search (it fails without the 388 writes), the DMA from the
  DRAM back to memory (256 bytes, its TC IRQ) and sampling (64 bytes of
  silence mono at 308.7 kHz and stereo inverted at 205.8 kHz, its TC IRQ,
  49h's pending). v022snd (without
  them) ran on the board: Windows 95's Gravis driver gets past its
  card check with its resources set to 240h, IRQ 11, DMA 3 (then wants
  ULTRADIR); INSTALL couldn't find the card. v022dma (the 388 writes, the
  TC fix): XTC-Play plays 4- to 20-channel modules, CONSCAN and INSTALL
  find the card, Gravis Setup's IRQ and memory tests pass, its DMA tests
  failed (no DMA to the PC, no sampling then). v022rec (both added): all
  of Custom Setup's tests pass (IRQ 11 for both lines, playback and record
  DMA 3); DMA 6 and 7 fail there, as only DMA 3 is wired.
  Since (2026-11-17/18): 16-bit voices played their samples byte-swapped
  (Quake's sound "just a mess"): gf1.v latches a voice's first CAS (the even
  byte) as the high byte, while its DMA stores 16-bit data low byte first;
  gf1.v now swaps the two at `mul_val_a_l` for 16-bit voices (its header
  notes the change). The sample RAM holds 16-bit words, so a 16-bit voice's
  second CAS reads the word its first one fetched, a clock after its CAS (at
  512 KB, with one more output register, the second byte otherwise missed
  the GF1's latch now and then). 2xF (register controls, rev 3.4 cards):
  a 2xB write reaches the latches only with 2xF bits 2..0 at 0 (ULTRINIT
  writes the board's jumpers to 2xB with 2xF = 6, which had set the DMA latch
  to 6: no DMA after ULTRINIT), and the IRQ latch keeps 7 bits: channel 1,
  channel 2 and bit 6 (combine), as Gravis' Windows driver sets it (68h:
  channel 2 on IRQ 11, combined; with bits 2..0 alone that was "none", and
  Windows 3.11 hung at exit waiting for the end of the exit sound's IRQ).
  The menu's "GUS volume" (Full, -6 dB: the default, -12 dB) shifts the
  card's samples before the mix (`gus_vol`, synchronized into clk_audio):
  at full scale the GUS is far louder than the SB16, whose mixer starts at
  -14 dB.
  Reading 8Fh (the IRQ source) now clears the pending IRQ of the voice it
  reports (2026-11-19, gf1.v's second change): the model's delayed clear
  (`wave/ramp_irq_clear_l5`) reached the voice write-back two slots after the
  compare stage, i.e. the voice below, so a voice whose handler only reads
  8Fh interrupted again every ~80 us. Gabriel Knight's speech (Sierra's
  GUSDAC.DRV for its 32-bit games) streams through a looping 16-bit voice with
  its IRQ on and a silent non-looping timer voice that ends 99 samples before
  the loop; the storm restarted the timer voice without end and the speech
  stopped after a syllable. Every other driver here rewrites the voice in its
  handler, which hid it. `tb_gus` checks the voice numbers with 25, 32 and 14
  voices and one IRQ per pass of a looping voice (109 in 10 ms before).
- Debug: `C_DEV_PC_CTL` also holds the SDRAM clock's fine phase, a snapshot
  of the PC's state (boot stage, POST code, CS:EIP, VGA frame count, the L2's
  counters) and a 4096-entry log of the BIOS's debug port 0x402, z486's
  stall watchdog, POST code changes and the PS/2 keyboard's and mouse's bytes
  both ways (`qmon.py status`: `>kbd`/`>mou` to the device, `<` from it);
  `mega65.vhd` has the map. `tools/qmon.py` reads them over the JTAG
  adapter's serial port (115200 baud) while the PC and the menu run: the
  firmware answers serial commands in the Shell's background (`R`/`W` QNICE
  memory, `D`/`P` a device's registers, as MegaMac does), no debug mode
  needed. `qmon.py status` (`disks` the mounted images, the sector counts and
  times, the ring's checksums; `boot` and `sweep` reset the PC at other SDRAM
  clock phases; `xadc` the FPGA's temperature, VCCINT, VCCAUX and VCCBRAM,
  now and their lowest and highest since the core was loaded,
  `xadc_mon.vhd`).
  `qmon.py ide [N]` prints the last N of 512 events of the IDE trace
  (`pc_mgmt.vhd`, `pc_cdrom.vhd`; window 2 of `C_DEV_PC_CTL`): every command
  of both channels with its task file, every status the controllers set,
  every block done, reset, floppy request and SD answer, with milliseconds
  before the newest. It is not cleared by a PC reset, so it shows what led up
  to a hang.
  `QMON_MONITOR=1` talks to the M2M debug monitor instead (hold Run/Stop +
  Cursor Up, then press Help).

## The internal floppy drive as a PC drive

The menu's "Internal drive: Drive A:" (or B:) makes the MEGA65's floppy drive
that PC drive: it reads and writes real disks. z486's `floppy.v` stays the
PC's controller; what changes is where a sector comes from and goes to:

- `pc_mgmt.vhd` mounts the drive with 84 cylinders, 2 heads and 36 sectors a
  track, so that `floppy.v` takes any request a real disk can answer (the
  disk says which sectors it has), and the CMOS says 1.44 MB. The image of
  that drive is put aside until the menu gives the drive back.
- A request for that drive goes to `fdd_phys.vhd` by cylinder, head and sector
  (`floppy.v`'s register 1, a patch in `tools/z486_sources.py`). Its answer is
  the sector, read out of `fdd_phys`'s track buffer into `floppy.v`'s FIFO as
  an image's is (checked on the way, asked again fresh if the copy does not
  match), or an error: ST2:ST1 into `floppy.v`'s register 6 (also a patch)
  ends the command with an 82077's result bytes, as a real controller ends it
  for a sector it cannot read. `CORE/sim/run_floppy_err.sh` checks the patch.
- `fdd_sound.vhd` positions the head: it follows `floppy.v`'s cylinder of that
  drive, runs the motor with the PC's (a disk in it or not), says when the head
  has settled (18 ms after the last step), and recalibrates on request.
- `fdd_mfm_rx.vhd` turns RDATA into bytes: a digital PLL data separator (AExp's
  design, which replaced a gap classifier there on old media) at the PC's
  clock (66 MHz), a cell of 2 us at 250 kbit/s or 1 us at 500 kbit/s, +/-10 %; the
  16-bit pattern 0x4489 (an A1 with a missing clock bit) frames the bytes.
- `fdd_phys.vhd` parses ID fields (FE: C, H, R, N, CRC) and data fields (FB or
  F8, CRC), the CRC-CCITT over the three A1s, the mark and the field, and keeps
  the sectors of the track under the head in a 32-slot buffer (16 KB of block
  RAM), filled whenever the head is on that track: one revolution reads the
  whole track, and the PC's next sectors come out of the buffer. Only sectors
  whose CRC is right count, only into empty slots. A request: the buffer moves
  to its track, the head is positioned, the motor spun up (an index pulse),
  then it waits until the second index pulse (a whole revolution) for the
  sector. No ID field at the rate tried: the other rate (500 or 250 kbit/s),
  once. ID fields of another cylinder: a recalibration, once. Then an error:
  no ID field (MA), the ID but no data field (MA, MD), a data CRC error (DE,
  DD), the sector not on the track (ND, with WC if another cylinder's IDs
  came). The BIOS gives a command about 2 s (its motor-off count).
- A write: `pc_mgmt` pops the PC's 512 bytes into `fdd_phys`'s write buffer
  and asks; the head is positioned as for a read, then `fdd_phys` waits for
  the sector's ID field (at the rate the disk has, found as for a read),
  counts out 22 bytes of gap 2 and `fdd_mfm_tx.vhd` writes the data field over
  the old one, as a PC's controller does: 12 x 00, three A1 syncs, FB, the
  data, the CRC, 2 x 4E, a WDATA pulse of a quarter cell in the middle of each
  '1' cell, with an 82077's write precompensation (125 ns early or late by
  the neighbouring transitions). `floppy.v` (a patch) holds the PC's command
  until the sector is on the disk: `pc_mgmt` writes its register 7 then, or
  the error into register 6. (Without the hold, `floppy.v` went on as soon as
  its FIFO was empty: the PC's next command could move the head before the
  last sector was written, and that sector's error landed on the next
  command. The Bochs BIOS stops with "int13_diskette_function: write error"
  on any write error.) The buffer's copy of the sector is dropped,
  so the next read comes from the disk. The write protect tab is read while
  the drive is selected and goes to `floppy.v`'s wp input (the PC's write is
  refused at once, as by a real controller); the select, the motor, the tab
  or the head going away mid-write closes WGATE at once (0010, OR, for the
  PC). `C_FDD_WRITE` in `mega65.vhd` makes a read-only build.
- FORMAT writes the whole track, as a PC's controller does:
  - **The hand-over:** `floppy.v` (a patch) accepts any sector count on the
    internal drive, while the mount says 36. It hands each ID over as it
    comes from the PC:
    - register 8: FORMAT running, the data rate, the head's cylinder;
    - register 9: sectors per track and gap 3;
    - registers 10 and 11: the ID field (C, H, R, N);
    - register 12: the IDs left and the filler.

    `pc_mgmt` passes them to `fdd_phys`, which collects the IDs and answers
    each at once.
  - **Writing the track:** with the last ID, `fdd_phys` positions the head,
    picks the rate by the sector count (12 or more: 500 kbit/s; fewer: 250),
    and from the index pulse writes the 82077's IBM MFM
    layout: gap 4a, the index address mark (C2 sync), gap 1, then per sector
    the ID field, gap 2, a data field of 512 filler bytes and gap 3, then 4E
    until the index comes round. `fdd_mfm_tx` writes it in a track mode from
    `fdd_phys`'s generator (`p_gen`, with the CRCs).
  - **Two things the Bochs BIOS relies on:**
    - It never sends SEEK: its FORMAT expects the controller to take the
      cylinder from the IDs, as Bochs's emulated one does. So for the
      internal drive `floppy.v`'s `head_pcn` takes the IDs' cylinder (an
      implied seek).
    - It sends gap 3 as 0, which `fdd_phys` replaces with the standard 84
      (HD) or 80 (DD) bytes, shortened until the track fits a turn with 2 %
      to spare.
    - It never sets the data rate (no write to 3F7h or 3F4h), so `floppy.v`'s
      stays at its reset value, 250 kbit/s. The first board test formatted
      18 sectors at that rate: the track overran itself, and DOS's first
      write afterwards stopped the BIOS. Hence the sector-count rule.
  - **Afterwards:** the track buffer empties, so DOS's verify reads come
    from the disk.
- The head follows `floppy.v`'s present cylinder number (`drv_cyl`, a patch:
  RECALIBRATE, SEEK and a read's or write's implied seek), not its
  `cylinder` register, which also takes the C+1 an 82077 reports when a
  multi-track read ends at the end of the track on head 1 (the BIOS's reads
  do): following that stepped the drive out after every read on side 1, and
  the next sector cost a turn of the disk.
- The disk change line the PC reads (DIR bit 7, a patch) is the drive's
  DSKCHG, read while it is selected, as a PC's controller passes it on: a
  disk taken out makes it active, and the PC's next seek (a step with a disk
  in) clears it. `qmon.py fdd` shows the drive's state: requests, errors, ID
  and data fields, CRC errors, the track buffer, the head, the PLL's cell and
  the disk's speed.

`CORE/sim/run_fdd_phys.sh` runs `fdd_phys` and `fdd_sound` against a model of
a drive turning HD (18 sectors) and DD (9 sectors) disks, with jitter and
+/-2 % speed: whole tracks, a data CRC error, a missing sector, lost steps
(the recalibration), a disk taken out and another put in (the rate found),
and writes: the model decodes what WDATA wrote (and where: in the sector's
gap 2), the following turns carry it, and it reads back while its
neighbours stay intact; the write protect tab; a write at DD found by
itself. FORMAT:
- the model decodes the whole written track (the index address mark, every
  ID and data field with its CRC, the filler, gap 3, and where it began and
  ended relative to the index);
- the formatted sectors read back as filler;
- a sector written into the formatted track reads back;
- gap 3 0 becomes 84 at HD, and shorter for 10 DD sectors;
- the tab gives NW.

`CORE/sim/run_floppy_err.sh` checks `floppy.v`'s side: registers 8-12, the
hold until register 7, and the implied seek.

## Keyboard after a warm reset

After Ctrl+Alt+Del, or Enter at a "restart" prompt, the keyboard could stay
dead until a full reset. The Bochs BIOS sets up the keyboard (POST 77) before
the interrupt controllers; a key released in between raises IRQ1, ICW1 then
clears the request, and an 8259 waits for a new rising edge, which never
comes while nobody reads port 60h. `tools/z486_sources.py` patches `pic.v`:
after ICW1 an input that is already high counts as a new edge, so it is
served once (the same for the mouse's IRQ12). `tb_pic.sv` replays the race;
upstream's `pic.v` fails it.

## Shift lost for good (2026-11-07)

After tapping Shift+F7 (F8) at "Starting Windows 95…", Shift did nothing any
more, `:` came out as `;` and `*` as `8`, in DOS and Windows, across resets,
until F7 was pressed on its own. For F8 `pc_keyboard.vhd` releases the PC's
Shift and holds it back until F7 comes up; F7's release never arrived. Its
32-entry event FIFO waits while the PC does not take bytes (the 8042's FIFO
full at 60, typematic F8s filling it). When the FIFO was full, a release
overwrote the newest entry, so that entry's release was lost whenever it was
one. And nothing cleared it: the module is not reset with the PC, and the BIOS
sends the keyboard no command at all (the log of a whole boot). Now a change
the full FIFO cannot take stays out of the module's matrix copy and is seen at
the key's next scan; a sweep releases any key the module holds that the matrix
has up while no event waits; the module is reset with the PC; and `qmon.py
status` shows the key that holds Shift back and the sweep's releases.
`CORE/sim/run_kbd_stress.sh` (nvc) plays random presses of the keys that move
Shift while the PC stops reading; with long stops the old code failed half of
10 seeds (keys the PC kept down, `:` without Shift, Shift+A as `a`).
