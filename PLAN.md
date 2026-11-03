# Plan: PC-8000 series core for MiSTer

Goal: one core with a Machine > Model option (PC-8001, PC-8001mkII, PC-8001mkIISR), built the way the PC-6001
core was (/Users/alans/dev2/PC-6001_MiSTer): the base machine first, checked against MAME frame by frame in a
Verilator simulator, then each later model added as a Model option.

## Why a separate core, not PC88_MiSTer's N mode

PC88_MiSTer (refs/hdl/PC88_MiSTer) is a PC-8801mkIISR. Its N mode is the 8801's PC-8001 compatibility mode:
the 8801's own N-BASIC, its video and timing, no PCG-8100, no mkII graphics or memory map and no SR. The PC-8001
is a much smaller machine, so a separate core is simpler than adding three models to the 8801 design. It can
still borrow PC88_MiSTer's pieces (same author family: Puu-san's design, ported with alanswx's help):

| From PC88_MiSTer | For |
|---|---|
| rtl/cmt_* (.t88/.cmt playback, 8251 serial path) | cassette |
| rtl/SUBunit, rtl/FDC, diskemu_mister | PC-80S31 disk unit (sub Z80 + 8255 + uPD765) |
| text VRAM / CRTC / DMA blocks (TEXTRAM, TDMAREGS, trammaps) | the uPD3301 + uPD8257 text screen |
| RTC (uPD1990), beeper (beeposc, singspk), PS2KB | ports 10h/40h, sound, keyboard |
| sound/jt12 (jt03) | the SR's YM2203 |

Check PC88_MiSTer's license per file before copying (its readme states none overall; it is GPL-style MiSTer
code). From the PC-6001 core: the OSD and tape standards (~/dev2/osd-standard.md, ~/dev2/tape-standard.md),
the tape status overlay, rtl/d88_media.sv (D88 in DDR3), rtl/upd765_lite.sv, the ROM store in DDR3 for several
models, the Verilator harness (verilator/sim_headless.cpp, run_tests.sh, frame hashes) and the Quartus container
build (~/dev2/apple-containers-example/scripts/quartus-core-apple.sh).

The only PC-8001 HDL, radiojunkbox/pc8001m with chiqlappe's fixes (refs/hdl/pc8001m, PC-8001_FPGA), is a
DE0-CV/DE10-Lite board design with a simplified CRTC/DMA and no license; use it as a reading reference (its
PCG-8100 and attribute handling especially), not as code to copy.

## References and how to check against them

- MAME 0.283 pc8001 / pc8001mk2 boot from refs/emulators/mame_roms (verified 2026-11-03). Use a Lua autoboot
  script (as runs/mame in the PC-6001 project: type keys, snapshot frames) to make reference frames.
- CSCP pc8001 / pc8001mk2 / pc8001mk2sr, `--headless` (CLI.md): a second opinion, and it has a real PC-80S31.
- Read X88000 and QUASI88 sources for details MAME leaves out (MAME's TODOs: DMA wait states, superimpose).
- Facts: refs/docs/HARDWARE_NOTES.md (with sources and UNCERTAIN marks), the mkII kaiseki I/II scans.

## Phases

### 0. Set up (small)
- Copy the MiSTer template (sys/, PC6001.sv as the pattern) and the Verilator harness; T80 from SharpMZ_MiSTer.
- boot.rom layout (one file, ioctl index 0): N-BASIC 24 KB + font 2 KB to start; later sets per model (as the
  PC-6001's boot1-3.rom). Write the `cat` recipe in the readme.
- Scripts that make MAME and CSCP reference frames for a given ROM, keys and frame number.

### 1. PC-8001 boots to BASIC (the main step)
- Z80 at 4 MHz, memory map (ROM 0000-5FFF, optional 6000-7FFF, RAM 16/32 KB, 8000-FFFF), port 30h/40h.
- uPD3301 CRTC + uPD8257 DMA: the DMA reads 120 bytes a row from F300h (80 characters + 20 attribute pairs)
  and holds the Z80 with BUSREQ, as the real machine does. Text 80/40 x 25/20, attributes (secret, blink,
  reverse, over/underline, semigraphics, colour BRG), 2x4 semigraphics (160x100), cursor, VRTC.
  Spec: the uPD3301 datasheet (refs/docs/datasheets) and MAME upd3301.cpp; the ROM's init (CE 98 67 DE 13).
  The video clock: 14.318 MHz, 896 x 260 (MAME's numbers; check them).
- Keyboard matrix 00h-09h from PS/2 (US and JIS layouts, as in the PC-6001 core).
- Beeper (40h bit 5 with 2.4 kHz).
- Done when: "NEC PC-8001 BASIC Ver 1.1" matches MAME's frame; PRINT, LIST, a type-in BASIC program run; the
  40-column and colour modes match MAME.

### 2. Cassette
- 8251 at 20h/21h, 600 baud (1200 on mkII), motor on 30h. Load .cmt and .t88 (PC88_MiSTer's cmt_* and the
  PC-6001 tape standard: turbo while the motor runs, status overlay). .n80 as a direct memory load.
- Done when: CLOAD and MON L load Year-Based .cmt titles (Galaxian, Slot Machine, Dig Dug); later CSAVE.

### 3. Disk unit (PC-80S31)
- Ports FCh-FFh 8255 link to a sub system: Z80 + 8255 + uPD765 + disk.rom (2 KB, have it). Reuse
  PC88_MiSTer's SUBunit/FDC or the PC-6001's PC-6031 design (same idea, 1D) with d88_media.sv in DDR3.
  2D images (the Year-Based set's 387 PC-8001 .d88 are mostly 2D).
- Done when: the N-BASIC system disks and Block Kuzushi / Heiankyo Alien boot from .d88.

### 4. PC-8001 options
- PCG-8100 (programmable characters, its PSG-like sound): Galaxian PCG, The Dusty World.
- uPD1990 RTC, printer port stub, 64 KB RAM (PC-8012 style), expansion ROM at 6000h (cartridge-like OSD load).

### 5. PC-8001mkII (Model option)
- 64 KB RAM with ROM/RAM switching (31h, E2h), N80-BASIC ROM at 6000-7FFF, DIP switch (N / N80) on the OSD.
- 16 KB GVRAM at 8000-BFFF via 5Ch/5Fh, 640x200 mono / attribute colour, 320x200 4 colours, over the text.
- Interrupts IM2 (E4h level, E6h mask: RTC, VRTC, 8251), kanji ROM (E8h-EBh, 128 KB, in DDR3/SDRAM).
- The internal disk interface (F3h-FBh) if software needs it; otherwise the PC-80S31 link first.
- Done when: the mkII boot screen (Ver 1.3) matches MAME; Monster House, Mario Bros. Special run.

### 6. PC-8001mkIISR (Model option)
- 48 KB 3-plane GVRAM (5Ch-5Eh planes), 640x200 8 colours, palette 54h-5Bh, N80SR-BASIC bank (33h, 71h),
  YM2203 (jt03, 44h/45h) and its interrupt, the SR font ROMs.
- fonthira.rom found 2026-11-03 (MAME pc8001mk2sr.zip); MAME boots the SR. The SR details are the weakest
  in the docs: use CSCP's pc88.cpp and the PC-8801 V1 docs (refs/docs/web/youkan) as the spec.
- Done when: SR boot screen matches; F2 Grand Prix, Type Game, Nuts and Milk run.

### 7. Release
- Hardware test on Mister 126 (misterkvms-cli), tester zip under 20 MB with the core, a boot.rom recipe (no NEC
  ROMs unless the user decides otherwise) and curated software from refs/software, then a public repo.

## Resources (DE10-nano)

Block RAM: 64 KB main RAM, 24-72 KB ROM, 3 KB text VRAM inside RAM, 48 KB SR GVRAM, font ROMs. The kanji ROM
(128 KB), D88 images and the extra ROM sets go to DDR3, as in the PC-6001 core (where block RAM ran out at the
mkII). Use explicit true dual-port RAM (dpram_tdp) for RAM/ROM that both the CPU and the video read: Quartus
duplicated inferred ones in the PC-6001 core.

## Open questions

1. Name: PC8001 core (rbf PC8001_YYYYMMDD.rbf, games/PC8001/)? Assumed here.
2. Uncertain hardware (HARDWARE_NOTES.md section 10): uPD3301 retrace fields, port 30h motor polarity and 31h
   bit 0 sense, the real dot clock, the cassette block format, all SR ports.
3. The PC-8001 service manual / schematics (not found).
4. The US PC-8001A (Greek characters, other font): include as a ROM option later?

## First steps

1. Phase 0 harness and boot.rom; MAME reference frames for the boot screen, 40 columns, colour and semigraphics.
2. Phase 1 CRTC/DMA: write it against the datasheet and MAME, then compare frames with MAME until they match.
