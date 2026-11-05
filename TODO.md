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
- [x] Z80 + memory map: ROM 0000-5FFF, 6000-7FFF empty, RAM 16/32 KB (64 KB later). One wait in each memory read (CSCP: memory wait on).
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
- [x] US keyboard layout option (OSD Keyboard = US, sim --kbd-us): identical to CSCP (kbdus). A symbol whose
      SHIFT differs from the held SHIFT waits 50 ms for BASIC to see the new SHIFT (else US ^ @ : were lost).
- [ ] Disk-unit check: with FCh-FFh reading FFh the ROM waits ~2.7 s before BASIC (CSCP, with an 8255
      always present, does not). Settled by the disk unit (phase 3) or by what a bare PC-8001 reads there.
- [x] Clocks: CPU 3.9936 MHz (15.9744 MHz / 4: PC-8001B manual, parts list), dot 14.31818 MHz
      (HARDWARE_NOTES 11).
- [ ] Schematic: work out the WAIT circuit (IC47/IC9) and the DMA/BUSREQ timing.
- [x] CPU speed against CSCP (2026-11-03): DMA steal counter overflowed (16 bits; a row's burst is 182760),
      so the Z80 ran 26 % fast; memory waits were M1 only (CSCP: every read). Now per-instruction clocks match
      CSCP; a BASIC loop is 3.4 % slower than CSCP, from CSCP's steal overlapping execution (HARDWARE_NOTES 11).
- [x] Cursor and attribute blink: identical to CSCP over 121 frames (frame 0 now starts at reset).
- [x] Quartus build: 21% ALMs, 120 RAM blocks, all clocks meet timing, no critical warnings.
- [ ] First try on Mister 126.

## 2. Cassette
- [x] 8251 (rtl/i8251.sv): mode, command, status, receive from the deck; transmit accepted and dropped.
- [x] Deck (rtl/pc8001_cmt.sv): .cmt / .t88 in 64 KB block RAM (F1 CMTT88), bytes at the line rate from the
      8251 mode and 30h's baud; T88 carrier tags for their length; carrier detect (40h bit 2) as CSCP; a 1 s
      leader for .cmt at start and at each motor restart.
- [x] Motor: 30h bit 3 = 1 is on (ROM 0BF3h/0C31h, MOTOR 1); the ROM leaves it on at idle with RS-232C
      selected (2Ah), so the deck plays only with bit 3 = 1 and the cassette selected (bit 5 = 0).
- [x] Turbo 5x while the deck plays (CPU 5x, no DMA steal), Tape speed / Rewind / Tape overlay on the OSD,
      tape status bar (rtl/tape_overlay.sv from the PC-6001 core), "Tape ready" / "too large" messages.
- [x] CLOAD of .t88 (River Patrol, runs) and .cmt (Kumo Vader), then LIST: identical to CSCP. MON L of the
      machine-code block after CLOAD works.
- [ ] Tapes over 64 KB (18 images in the sets, up to 512 KB): DDR3.
- [ ] .n80 (memory image at 8000h, start at FF3Dh with SP from FF3Eh): needs a CPU start path.
- [ ] Next-step hint (tape standard): read the name from the tape, "TYPE CLOAD"/"MON L".
- [ ] CSAVE to a file (8251 transmit to a .cmt).
- [ ] More titles: Galaxian, Slot Machine, Dig Dug (Year-Based .cmt); machine-code games started from MON.

## 3. Disk unit (PC-80S31)
- [x] rtl/pc80s31.sv (the PC-6001 core's pc6031.sv: Z80 + disk.rom, 16 KB, uPD765, two cross-wired 8255s) at
      FCh-FFh; upd765_lite.sv, d88_media.sv (DDR3, up to 512 KB: 2D), i8255_m0.sv. disk.rom at 6800h of
      boot.rom connects the unit (tools/make_boot_rom.sh adds it when present); without it FCh-FFh read FFh.
- [x] OSD Drive 1 / Drive 2 (S0, S1, D88, written back), LED, "Disk too large" / "No disk unit" messages;
      sim --disk, --disk2, --disk-unit, --swap-disk[2] F:FILE, --disk-out; tools/cscp_cmp.sh DISK=, DISK2=,
      SWAP=, SWAP2=. Two drives: upd765_lite per-drive cylinder and seek status, two d88_media (512 KB each in
      DDR3) sharing DDR3 through a grant.
- [x] N-BASIC system disk (PC-8034-2W) boots to "How many files": identical to CSCP. Block Kuzushi: boot
      the system disk, swap, MOUNT, RUN"BLOCK" plays.
- [ ] Heiankyo Alien: find how it starts (track 0 is blank like Block Kuzushi's?).
- [x] Second drive: Block Kuzushi from drive 2 (MOUNT 2, RUN"2:BLOCK") identical to CSCP at frames 6000 and
      9000 (block2); earlier frames differ while loading (seek/read timing).
- [ ] Disk swap in drive 1 then MOUNT: the sim reads the new disk; CSCP (--swap-disk) says "Bad allocation
      table" (runs/cmp/block_game). Find which is right (disk-change handling in the firmware / CSCP's swap).
- [ ] Boot time with the unit and no disk (CSCP ~1100 frames): compare.

## 4. PC-8001 options
- [x] PCG-8100 (OSD Machine > PCG-8100, sim --pcg), as CSCP: 1 KB RAM patterns for codes 80h-FFh (a copy
      of font.rom's at load), ports 00h-02h, 8253 at 0Ch-0Fh (rtl/pit8253.sv from the SharpMZ2500 core) at
      3.9936 MHz, three 1-bit channels switched by 02h bits 3, 6, 7.
- [ ] PCG games against CSCP (CSCP has the PCG-8100 on by default): PCG Dig Dug and The Dusty World (.d88,
      autostart) draw the same PCG characters, but the attract mode is at another phase (Dig Dug's sprites a
      few frames apart; Dusty World on another screen): load time. Galaxian PCG not tried.
- [x] uPD1990A (rtl/upd1990a.sv, as CSCP): 10h bits 0-3 C0-C2 / DIN, 40h bit 1 STB (falling), bit 2 CLK, 40h
      read bit 4 DOUT. Time from the MiSTer RTC (the sim: 2026-11-03 12:00:00).
- [x] TIME$ set and read: identical to CSCP (time).
- [x] Printer: data 10h, STROBE 40h bit 0 (byte taken as it falls), BUSY 40h bit 0 never set (as CSCP's
      PRNFILE); the bytes go nowhere on the MiSTer, sim --printer FILE saves them (LPRINT, LLIST checked).
      40h reads bits 7, 6, 1 high as CSCP.
- [x] Expansion ROM at 6000-7FFF from the OSD (F2, 8 KB, resets): N-BASIC calls 6002h when it starts "AB"
      (checked with a test ROM, sim --ext-rom).

## 5. PC-8001mkII (Model option)
Spec: refs/docs/MK2_NOTES.md (CSCP's model). CSCP comparisons: MODEL=mk2 tools/cscp_cmp.sh (build pc8001mk2).
- [x] boot1.rom (n80_2.rom + kanji1.rom, ioctl 40h) kept in DDR3 (rtl/rom_store.sv, rtl/ddr_arb.sv with the
      disk unit); the 32 KB main ROM copied in at a reset when the model changed. OSD Model, mkII mode N80/N.
      Boot (N80 and N) identical to CSCP.
- [x] 64 KB RAM: 0000-7FFF over the ROM by 31h bit 1 or E2h bits 0/4; 30h reads the N/N80 switch, 31h B9h,
      E2h inverted (as CSCP).
- [x] GVRAM 16 KB at 8000-BFFF (5Ch/5Fh); 640x200 in the text's colours, 640x200 mono, 320x200 4 colours,
      background colour (31h bits 7-5), 53h text / graphics off: identical to CSCP (mk2g09/1d/4d/29). 68-clock
      GVRAM wait with graphics on in the active display.
- [x] IM2 interrupts: RxRDY (0), VRTC (1), 600 Hz timer (2); E4h level mask, E6h source enables. Kanji ROM
      E8h/E9h from DDR3 (the CPU waits for it).
- [x] Interrupts and kanji reads identical to CSCP (mk2int, tools/mk2int_asm.py: 596 timer and 60 VRTC
      interrupts over 60 frames; kanji 0904h and 4321h).
- [ ] mkII software: Monster House, Mario Bros. Special; N80-BASIC graphics commands (SCREEN, LINE).
- [ ] Ver 1.3 boot screen (MAME) vs CSCP's Ver 1.0: which ROM.

## 6. PC-8001mkIISR (Model option)
Spec from CSCP's pc8001mk2sr build: refs/docs/SR_NOTES.md.
- [x] Model option, boot2.rom (tools/make_boot2_rom.sh; rtl/rom_store.sv set 2), N80 / N / N80SR modes (30h/31h
      reads), N80SR-BASIC's 40 KB ROM (33h bit 7, 71h bank), full port decode, SR waits (none in N80SR mode).
- [x] 3-plane GVRAM (5Ch-5Eh), the ALU (34h/35h), palette 54h-5Bh, N80SR video modes (640/320 colour, 640/320
      attribute, 320 pages, plane mask 53h, PR1/PR2), the hiragana font (33h bit 4). All match CSCP (srg_*, sralu).
- [x] YM2203 (jt03 at 44h/45h), its interrupt (level 4, 33h bit 1 mask), mixed into the audio. Timer A matches
      CSCP (sropn). Fixed with it: the 3.9936 MHz clock enable (pit_ce) ran at ~clk_sys (an 18-bit constant
      overflowed), so the PCG-8100's 8253 sound was ~7x too high until now.
- [x] SR boot screens (srboot, srn, srv2) match CSCP.
- [ ] MAME SR reference frames (fonthira.rom found 2026-11-03; MAME boots to Ver 1.6).
- [ ] Software: F2 Grand Prix, Type Game, Nuts and Milk; a hiragana test; keyboard row 0Ah.
- [ ] YM2203 busy flag: jt12's lasts 32 FM clocks after a data write; CSCP has none (sropn masks it).

## 7. Release
- [ ] Hardware test on Mister 126; tester zip under 20 MB (core, boot.rom recipe, curated software).
- [ ] Public repo.

## Open questions (from PLAN.md)
- Uncertain hardware (HARDWARE_NOTES.md section 10): uPD3301 retrace fields, 30h motor polarity, 31h bit 0,
  the dot clock, the cassette block format, the SR ports.
- PC-8001A (US) font/ROM as an option?
