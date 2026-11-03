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
- [ ] MAME frames: boot screen, 40 columns (WIDTH 40), colour (CONSOLE/COLOR), semigraphics, 20-line mode.
- [x] Z80 + memory map: ROM 0000-5FFF, 6000-7FFF empty, RAM 16/32 KB (64 KB later). Boots to "Ver 1.1 / Ok"
      at frame ~165 in the sim with a stand-in text renderer (rtl/pc8001.sv; no attributes, 8 lines a row).
- [x] Ports 30h, 40h (VRTC = vertical blank, beeper), others read FFh.
- [ ] Disk-unit check: with FCh-FFh reading FFh the ROM waits ~2.7 s (4 x 65536 tries at 01C5h-0227h) before
      BASIC. MAME waits too (its frame 100 matches ours). Look at what a real PC-8001 with no unit reads there.
- [ ] uPD8257 DMA: channel 2 to the CRTC, 120 bytes/row from F300h, BUSREQ holds the Z80 (TC, autoload).
- [ ] uPD3301 CRTC: reset + 5 parameters, start display, cursor commands, status read, row buffers,
      VRTC interrupt line, 80/40 columns, 25/20 rows, lines per char.
- [ ] Attributes: transparent pairs (position, value), secret, blink, reverse, overline/underline,
      semigraphics 2x4, colour BRG vs B/W mode (30h bit 1).
- [ ] Font ROM rendering, cursor, video timing 896 x 260 (check against the datasheet; MAME's numbers).
- [ ] Keyboard: PS/2 to matrix 00h-09h, US and JIS layouts, KANA lock, F6-F10 as shift F1-F5.
- [x] Beeper: 40h bit 5 and 2.4 kHz, to audio out (not listened to yet).
- [ ] Sim: boot frame matches MAME ("NEC PC-8001 BASIC Ver 1.1").
- [ ] Sim: PRINT, LIST, a typed-in program; WIDTH 40; colour and semigraphics frames match MAME.
- [ ] Quartus build fits and meets timing; first try on Mister 126.

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
