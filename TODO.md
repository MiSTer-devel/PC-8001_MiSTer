# TODO

Working list for PLAN.md. Done items move to the readme's Status section. (Started 2026-11-03.)

## 0. Set up
- [x] git init; .gitignore (refs/, runs/, rom/, Quartus and Verilator outputs). Nothing committed yet.
- [x] Template: sys/, pll (28.636 MHz; dot clock /2, CPU 4 MHz by accumulator), T80_v350, dpram_tdp.sv from the
      PC-6001 core; PC8001.sv (OSD: Load ROM, Memory, Aspect ratio), PC8001.qpf/.qsf/.sdc, files.qip.
- [x] boot.rom: tools/make_boot_rom.sh DIR (= cat n80v110.rom font.rom, SHA1 checked) -> rom/boot.rom.
- [x] Verilator harness: verilator/ (make; Vtop --rom-dir, --type, --screenshot, --trace-io ...), run_tests.sh
      (boot, boot16k hashes at frame 250).
- [x] MAME reference: tools/mame_ref.sh MACHINE OUTDIR FRAMES ['AT:TEXT'] -> runs/mame/.
- [x] CSCP reference: prebuilt apps boot all three models headless (refs/emulators/cscp_roms, README).
- [x] Quartus container build (quartus-core-apple.sh . , ~8 min): fits, 20% ALMs, 116 RAM blocks, all clocks
      meet timing (worst +0.557 ns, HDMI PLL; core clock +18.5 ns). Not tried on a MiSTer yet.
- [ ] rom_store.sv / DDR3 ROM store: not needed until the mkII (boot.rom fits block RAM).

## 1. PC-8001 boots to BASIC
Reference: CSCP (tools/cscp_cmp.sh NAME FRAME 'TEXT': types into the sim and CSCP, diffs the frames).
- [x] Z80 + memory map: ROM 0000-5FFF, 6000-7FFF empty, RAM 16/32 KB (64 KB later). M1 wait state (CSCP).
- [x] Ports 30h, 40h (VRTC, beeper), others read FFh.
- [x] uPD8257 DMA (rtl/i8257.sv): registers, TC, autoload, TC stop; channel 2 feeds the CRTC. BUSREQ holds the
      Z80 for 5.95 CPU clocks a byte (CSCP/XM8), taken per row as a burst.
- [x] uPD3301 CRTC (rtl/pc8001_crtc.sv): commands, parameters, status; timing from the parameters; double row
      buffer fetched one row ahead; transparent / non-transparent / no attributes; colour and B/W; semigraphics;
      secret, blink, reverse, over/underline; cursor; 40 columns. Attribute rules from CSCP.
- [x] Keyboard (rtl/pc8001_kbd.sv): PS/2 to the 00h-09h matrix by JIS position; KANA lock; F6-F10, Down,
      Left, Insert with SHIFT.
- [x] Identical to CSCP pixel for pixel: boot (40x20), PRINT, a program with LIST/RUN, WIDTH 80,25 / 80,20 /
      40,25, COLOR in colour mode, PSET semigraphics, CHR$(0-255) in 40 and 80 columns.
- [ ] Not compared yet: blinking (attribute and cursor phase), reverse display (start display bit 0), DMA
      underrun, non-transparent mode, a running game's timing (BUSREQ per row vs CSCP's per line).
- [ ] US keyboard layout option (symbols as printed), as the PC-6001 core.
- [ ] Disk-unit check: with FCh-FFh reading FFh the ROM waits ~2.7 s before BASIC (CSCP, with an 8255
      always present, does not). Settled by the disk unit (phase 3) or by what a bare PC-8001 reads there.
- [ ] Read the schematic (refs/docs/incoming/pc8001re_sch_PC-8001_IO_bessatsu.pdf) for the dot clock, the
      WAIT circuit and the DMA/BUSREQ timing.
- [x] Quartus build: 21% ALMs, 120 RAM blocks, all clocks meet timing, no critical warnings.
- [ ] First try on Mister 126.

## 2. Cassette
- [ ] 8251 at 20h/21h (receive path, then transmit), motor on 30h bit 3 (check polarity: sources disagree).
- [ ] .cmt / .t88 playback from DDR3 (PC88_MiSTer cmt_*, PC-6001 tape standard): turbo while the motor runs,
      status overlay. .n80 direct memory load.
- [ ] CLOAD and MON L of Galaxian, Slot Machine, Dig Dug (Year-Based .cmt).
- [ ] CSAVE to a file (later).

## 3. Disk unit (PC-80S31)
- [ ] 8255 link at FCh-FFh to the sub system: Z80 + 8255 + uPD765 + disk.rom (from pc6031.sv / PC88 SUBunit).
- [ ] d88_media.sv in DDR3, 2D images, two drives.
- [ ] N-BASIC system disk, Block Kuzushi, Heiankyo Alien boot.

## 4. PC-8001 options
- [ ] PCG-8100: programmable characters and its sound (Galaxian PCG, The Dusty World).
- [ ] uPD1990 RTC (10h/40h), printer stub, expansion ROM at 6000h from the OSD.

## 5. PC-8001mkII (Model option)
- [ ] boot.rom layout per model (as the PC-6001's boot1-3.rom); mkII ROM n80_2.rom; MAME mkII frames.
- [ ] 64 KB RAM, ROM/RAM switching (31h, E2h), N/N80 DIP on the OSD, 31h bit 0 sense (sources disagree).
- [ ] GVRAM 16 KB at 8000-BFFF (5Ch/5Fh): 640x200 mono / attribute colour, 320x200 4 colours, over the text.
- [ ] IM2 interrupts (E4h, E6h: RTC, VRTC, 8251), kanji ROM E8h-EBh in DDR3.
- [ ] Boot screen Ver 1.3 matches MAME; Monster House, Mario Bros. Special.

## 6. PC-8001mkIISR (Model option)
- [ ] MAME SR reference frames (fonthira.rom found 2026-11-03; MAME boots to Ver 1.6).
- [ ] 3-plane GVRAM (5Ch-5Eh), 640x200 8 colours, palette 54h-5Bh, N80SR-BASIC bank (33h, 71h).
- [ ] YM2203 (jt03 at 44h/45h) and its interrupt; SR fonts.
- [ ] SR boot screen; F2 Grand Prix, Type Game, Nuts and Milk.

## 7. Release
- [ ] Hardware test on Mister 126; tester zip under 20 MB (core, boot.rom recipe, curated software).
- [ ] Public repo.

## Open questions (from PLAN.md)
- Uncertain hardware (HARDWARE_NOTES.md section 10): uPD3301 retrace fields, 30h motor polarity, 31h bit 0,
  the dot clock, the cassette block format, the SR ports.
- PC-8001A (US) font/ROM as an option?
