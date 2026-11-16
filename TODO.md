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
- [x] rom_store.sv / DDR3 ROM store: not needed (all three boot ROMs fit block RAM; DDR3 is used for tapes).

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
- [x] Compared: attribute blink (cscp_suite blink, 9 frames); reverse display (out &h51,&h21, runs/cmp/rvv:
      identical; as in CSCP it only reverses where the attribute mode has no reverse bit of its own, so no
      change under BASIC's transparent attributes).
- [x] Cursor blink phase: from boot, frames 600-700 every 4 identical to CSCP (runs/cmp/curblink; 48 frames a
      cycle, 24 on). After a turbo tape the two run on different timelines, so phases there do not compare.
- [x] Non-transparent attributes (CRTC parameter 5 = 93h, attribute bytes at odd columns): identical to CSCP
      once the fill ends (cscp_suite nontrans, frame 6000; earlier frames differ only by the typing speed).
- [x] DMA underrun. Channel 2 off: blank, identical to CSCP (cscp_suite dmaoff). A DMA count of 10 rows (1200
      bytes, mode C4h = autoload + TC stop): the sim shows rows 0-9 twice, as MAME 0.283 (its 8257 reloads channel
      2 from 3 at TC and keeps going; autoload wins over TC stop); CSCP blanks the screen (it takes a frame's
      buffer as one block and stops at its end). Kept as MAME / the 8257 datasheet; hardware not checked.
      runs/cmp/dmashort, runs/mame/dmashort.
- [x] Running speed (2026-11-14): `print chr$(7);:for i=1 to 30000:next:print chr$(7);`, beep to beep in the
      recorded audio: Mister 126 39.437 s, the sim 39.437 s (the same to the millisecond), CSCP 38.204 s (the
      core 3.2 % slower: DMA steal of 5.95 clocks a byte, CSCP overlapping it; HARDWARE_NOTES 11). VRTC-paced games
      run at CSCP's rate (Galaxian: the same 7-frame step). CPU-bound code is 3.2 % slower than CSCP; which is
      nearer a real PC-8001 needs a measurement on one (see the WAIT item: the schematic suggests fewer waits).
      Experiment (sim only, not committed): with the schematic's waits (one on M1 and reads below 8000h, none on
      RAM data reads) the same loop takes 38.230 s, within 0.07 % of CSCP: the schematic reading plus the core's
      DMA steal lands where CSCP's every-read wait plus its overlapped steal does.
- [x] US keyboard layout option (OSD Keyboard = US, sim --kbd-us): identical to CSCP (kbdus). A symbol whose
      SHIFT differs from the held SHIFT waits 50 ms for BASIC to see the new SHIFT (else US ^ @ : were lost).
- [x] Disk-unit check: with FCh-FFh reading FFh the ROM waits ~2.7 s before BASIC (CSCP, with an 8255
      always present, does not). Settled by the disk unit (phase 3) or by what a bare PC-8001 reads there.
      2026-11-12: no unit, the sim and CSCP (pc8001_nodisk) change screen on the same frames (BASIC at 254-266,
      then the cursor at 290, 315 ...); with the unit and no disk, BASIC by 150 as MAME. A bare machine on
      hardware is not checked.
- [x] Clocks: CPU 3.9936 MHz (15.9744 MHz / 4: PC-8001B manual, parts list), dot 14.31818 MHz
      (HARDWARE_NOTES 11).
- [ ] Schematic: work out the WAIT circuit (IC47/IC9) and the DMA/BUSREQ timing. 2026-11-14: read at 400 dpi
      (HARDWARE_NOTES 11): WAIT = IC9 AND of the bus WAIT and a line from the counter area; that line's source is
      not readable in this scan. Needs a clearer schematic or a measurement on a real machine.
      Later the same day (web search, page 4): 1WAIT = IC43 flip-flop clocked by phi, D from a NOR of IC51
      (M1-bar AND A15) and its own Q, cleared outside reads: most likely one wait on opcode fetches and on reads
      below 8000h, none on RAM data reads or writes (CSCP and the core: one on every read). Medium confidence
      (a wire crossing at IC35). Not applied; HARDWARE_NOTES 11. Decided 2026-11-14: keep CSCP's waits, no OSD
      option unless software shows a speed problem (MAME's TODO notes some games run suspiciously fast there).
- [x] CPU speed against CSCP (2026-11-03): DMA steal counter overflowed (16 bits; a row's burst is 182760),
      so the Z80 ran 26 % fast; memory waits were M1 only (CSCP: every read). Now per-instruction clocks match
      CSCP; a BASIC loop is 3.4 % slower than CSCP, from CSCP's steal overlapping execution (HARDWARE_NOTES 11).
- [x] Cursor and attribute blink: identical to CSCP over 121 frames (frame 0 now starts at reset).
- [x] Quartus build: 21% ALMs, 120 RAM blocks, all clocks meet timing, no critical warnings.
- [x] First try on Mister 126 (2026-11-05; since then the routine test machine).

## 2. Cassette
- [x] 8251 (rtl/i8251.sv): mode, command, status, receive from the deck; transmit accepted and dropped.
- [x] Deck (rtl/pc8001_cmt.sv): .cmt / .t88 (F1 CMTT88; now in DDR3, see below), bytes at the line rate from the
      8251 mode and 30h's baud; T88 carrier tags for their length; carrier detect (40h bit 2) as CSCP; a 1 s
      leader for .cmt at start and at each motor restart.
- [x] Motor: 30h bit 3 = 1 is on (ROM 0BF3h/0C31h, MOTOR 1); the ROM leaves it on at idle with RS-232C
      selected (2Ah), so the deck plays only with bit 3 = 1 and the cassette selected (bit 5 = 0).
- [x] Turbo 5x while the deck plays (CPU 5x, no DMA steal), Tape speed / Rewind / Tape overlay on the OSD,
      tape status bar (rtl/tape_overlay.sv from the PC-6001 core), "Tape ready" / "too large" messages.
- [x] CLOAD of .t88 (River Patrol, runs) and .cmt (Kumo Vader), then LIST: identical to CSCP. MON L of the
      machine-code block after CLOAD works.
- [x] Tapes up to 512 KB in DDR3 (word 06040000h, a third client behind a second ddr_arb; one cached word,
      the next fetched during a character's time). Tester report: Pac Land (SR, 104-126 KB a side) stopped at the
      end of loading, the image cut at 64 KB. verilator/tb_cmt: every Pac Land side (both dumps), River Patrol and
      Kumo Vader play byte for byte. CSCP: side A reaches the title ("PUSH RETURN KEY TO LOAD START") at ~25000.
- [x] Pac Land on hardware (Mister 126): side A to the title, round 1 loads and plays. Sides B-D not tried.
- [x] .n80 (memory image at 8000h, start at FF3Dh with SP from FF3Eh): OSD Memory Image (F3), sim --n80 FRAME:FILE.
      The Z80 is held in an opcode fetch's wait while the image is written, then fed LD SP,nn / JP FF3Dh (no
      reset). Whole file loaded: 40 of 64 are 7F64h bytes with a register-restore stub at FF40h (CSCP loads to
      FF3Fh only, and its headless --tape rejects .n80, so no CSCP compare). Sim: Scramble, New Rally-X start;
      Double Rope, Galaxy Wars (RUN), Heavy Bomber (RETURN) reach their titles; Crazy Climber and Missile
      Commander (saved under BASIC 1.2/1.4) give Illegal function call on the PC-8001's 1.1, start on the mkII in
      Mode N (RUN), as do Lunar City SOS and Deep Scan; Space Mouse blank at 1500 there. Mister 126
      (465a701, setup slack 0.614 ns): Scramble's attract mode from an MGL (index 3, delay 5).
- [x] Next-step hint (tape standard): read the name from the tape, "TYPE CLOAD"/"MON L" (rtl/tape_hint.sv,
      6c7e556). TYPE CLOAD"name" / TYPE RUN for CSAVE tapes, TYPE MON L for monitor tapes, nothing otherwise.
      Model: 107 BASIC, 32 machine code, 6 none of 145 tapes; sim sweep of 14 (typing the hint loads each).
      Mister 126 (build of 6c7e556, slack 0.225 ns): River Patrol CLOAD"river" -> TYPE RUN -> gone once running.
      219f9ab: no RUN when a machine-code block follows the BASIC program (69 of 107: some load it themselves,
      others need MON L first, Neo Kobe's "{cload X mon L}"; the tape does not say which). Mister 126 (slack
      0.255 ns): Galaxian (1980) shows CLOAD"GXB", then nothing; River still shows RUN (sim).
- [x] More titles: Galaxian, Slot Machine, Dig Dug (Year-Based .cmt); machine-code games started from MON.
      Galaxian (1980)[a1] (cload"GXB", mon, L, Ctrl+B, run, then RETURN at a black screen: line 450 waits on
      INPUT$(1)) plays in the sim as in CSCP (runs/cmp/galaxian_c4); the black screen also on Mister 126. While
      it waits, both blink an 8x8 block (the cursor) at cell (1,1), 48 frames a cycle; the frames compared had
      caught them in opposite phases (the open cursor-blink-phase item, section 1).
      Slot Machine (1980) (cload"slot", run): identical to CSCP 300 and 1200 frames after RUN (runs/cmp/slot).
      Dig Dug (1983)(Dempa) (mon, L, G D670 from its .txt; tape_cmp START=D670): its KEY FUNCTION screen identical
      at +300; at +1200 only the flashing RET key differs (red vs white: the flash's phase) (runs/cmp/digdug).
- [x] Game Pack 2017 (Ishizu; 5 tapes from a tester, 2026-11-15): Galaxy Fly, Space Fighter, Submarine, Othello,
      Dot Eater, one monitor block each at 9000h (ends as the readme), started with G9000. tools/tape_cmp.sh: all
      five identical to CSCP 300 and 1200 frames after G9000 (runs/cmp/g17_*). The hint gets a table of known tapes
      (rtl/tape_hint.sv: first block's address, length, 16-bit sum; none of the corpus's 44 monitor tapes
      matches), which shows TYPE G9000 once the block has loaded, gone after Return. Sim --overlay: Dot Eater and
      Galaxy Fly show MON L, then G9000; Dot Eater plays after SPACE. Not checked on hardware (126 was in use).

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
- [x] Heiankyo Alien: starts by itself from drive 1 (title, then RETURN plays): sim and CSCP match except the
      aliens' positions (runs/cmp/heian_play, 2026-11-11).
- [x] Second drive: Block Kuzushi from drive 2 (MOUNT 2, RUN"2:BLOCK") identical to CSCP at frames 6000 and
      9000 (block2); earlier frames differ while loading (seek/read timing).
- [x] Disk swap in drive 1 then MOUNT: the sim reads the new disk; CSCP (--swap-disk) says "Bad allocation
      table" (runs/cmp/block_game). MAME (tools/mame_ref.sh with MAME_SWAP=2000:block disk, -ramsize 64K,
      runs/mame/swap) does as the sim: mount, run"BLOCK" plays. CSCP's swap is the odd one out.
- [x] Boot time with the unit and no disk (CSCP ~1100 frames): the sim and MAME (runs/mame/nodisk) both show the
      banner by frame 150 (the uPD765 says not ready); CSCP's uPD765 answers an empty drive with missing address
      mark (check_cond) and the unit retries. Same final screen (runs/cmp/nodisk_boot). Kept as MAME.

## 4. PC-8001 options
- [x] PCG-8100 (OSD Machine > PCG-8100, sim --pcg), as CSCP: 1 KB RAM patterns for codes 80h-FFh (a copy
      of font.rom's at load), ports 00h-02h, 8253 at 0Ch-0Fh (rtl/pit8253.sv from the SharpMZ2500 core) at
      3.9936 MHz, three 1-bit channels switched by 02h bits 3, 6, 7.
- [ ] PCG games against CSCP (CSCP has the PCG-8100 on by default): PCG Dig Dug and The Dusty World (.d88,
      autostart) draw the same PCG characters, but the attract mode is at another phase (Dig Dug's sprites a
      few frames apart; Dusty World on another screen): load time. Galaxian (Game Kyojin, PCG; .d88 from MAME's
      list): identical to CSCP through the title (900-4000); after RETURN at 2000 the same game state, the
      formation stepping every 7 frames in both, the sim 2 frames earlier (2286/2293/2300 vs 2288/2295/2302):
      a fixed phase, the same rate. runs/cmp/galgk, galgk3.
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
- [x] N80-BASIC graphics commands (runs/cmp/mk2cmd: CMD SCREEN 2, CMD LINE ,B, CMD CIRCLE, CMD PAINT, CMD LINE):
      frame 3500 identical to CSCP; at 2500 the sim's PAINT is further along (it runs a little faster there).
- [x] mkII software (sim, 5x tape): Mario Bros. Special (cload"*", run; its loader reads the rest, ~46 KB) has its
      title at frame 10500, identical to CSCP's (frame 16000, 200 bytes/s), and plays after SPACE (runs/mk2sw/mario2).
      Monster House (mon, L, Ctrl+B, cload"NO1", run; it loads NO2 itself; run) reaches its title
      (runs/mk2sw/monster2). The tape hint gives only its first step (MON L): the rest is not on the tape.
- [x] Ver 1.3 boot screen (MAME) vs CSCP's Ver 1.0: the same n80_2.rom (c12d34e4) holds both, N-BASIC Ver 1.3
      and N-80 BASIC Ver 1.0; MAME starts in N mode, CSCP in N80 mode (OSD mkII mode picks it here).

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
- [x] MAME SR reference frames (fonthira.rom found 2026-11-03; MAME boots to Ver 1.6): runs/mame/srboot, N mode,
      PRINT 1+2 at 300: frame 600 identical to the sim (--sr --n-mode); at 300 MAME has not drawn the function
      keys yet (its boot a few frames slower).
- [x] SR game disks with a blank boot sector (Golf, BurgerTime, Dig Dug, Dragon Slayer, Eggy, Excite Bike; the
      yearbased set) were split out of the neokobe "PC-8001mkIISR Game Pack" disks 1-3, which boot to a menu
      (Mode N80SR; number + RETURN; pack 2 also in N80). 9 of the 12 menu entries checked: packs 1 and 3 all start
      (sim; Excite Bike on Mister 126), pack 2's Golf (sim); pack 2's Dig Dug / Xevious / Nuts & Milk not tried; the split copies also start via the system disk (run"NAME"). Type Game is not
      in a pack: system disk, swap at "How many files", run"game.nsr". The tester zip now has the packs.
- [x] Keyboard row 0Ah (CSCP key_table): Tab, Down, Left, HELP = F11, COPY = Print Screen, pad - and /, CAPS =
      SHIFT + Caps Lock (a lock). Sim: Tab/Down/Left 254/253/251. Mister 192: Tab, Down, Left, F11, Print Screen
      (254 253 251 247 239) and CAPS (127); pad - and / not sent (KVMS has no names). Main keeps Scroll Lock and Num
      Lock (neither reaches the core), so CAPS is not on them.
- [x] Software hiragana: N80SR-BASIC's CONSOLE takes a 5th argument (0-3) into 33h bits 4-5 (ROM 1979h); 1 =
      hiragana for the kana codes. `console 0,25,0,1,1` then chr$(161-223): identical to CSCP (cscp_suite srhira)
      and hiragana on Mister 192.
- [x] cscp_suite mk2int: the sim counts 585 timer interrupts in 60 frames, CSCP 586. Bisected to 92eadc0 (ROM store
      download waits for the port): the sim's CPU starts 1733 clocks later (same code, first IN at cycle 133645 vs
      131912), so the BIOS programs the timer later and the window's count drops by one. A phase of the sim's boot,
      not the core; the suite reports it without failing.
- [x] YM2203 busy flag: jt12's lasts 32 FM clocks after a data write; CSCP has none (sropn masks it). Kept: the
      real chip has one; the SR games tried (Game Packs 1-3, Nuts & Milk) run with it.

## 7. Release
- [x] Hardware test on Mister 126 (2026-11-05): PC-8001 boot and BASIC, River Patrol from tape, the SR in N80SR
      mode (boot, 640x200 colour graphics), Nuts and Milk from disk on the SR. Timing met (setup slack 0.032 ns).
- [x] Audio on hardware (misterkvms-cli record x.wav): beep 2400 Hz; YM2203 FM 261 Hz / SSG 879 Hz as CSCP. The sim's
      --wav matches the hardware recording (levels within ~5%). The SR mix was rebalanced to CSCP's (beep and PCG
      halved on the SR, SSG x 11/16): FM/beep 0.78, SSG/beep 0.68 (CSCP 0.80, 0.68). tools/audio_tones.py.
- [x] PCG-8100 sound vs CSCP: 3994 Hz for count 1000 in both; a channel now as loud as the beep (CSCP 0.98).
- [x] Start freeze fix (92eadc0) on Mister 126 (2026-11-11): Model saved as SR, then as mkII, 3 core loads each
      boot to BASIC; Pause no longer holds STOP (a GOTO loop runs on, F9 still breaks). Setup slack 0.596 ns.
- [x] House standards (~/dev2/video-standard.md, osd-standard.md), on Mister 126 2026-11-11: video_mixer +
      video_freak on clk_vid 57.27 MHz (4x the dot clock; pixels handed over from clk_sys on ce_pix), gamma_bus,
      forced_scandoubler; P2 Scale and Scandoubler Fx (all four Fx checked; V-Integer 5x = 1000 lines, 2x with
      Fx), Original = 48:35 (640 x 200, PAR 3/7), aspect acting at once. OSD: Memory on the top page (hidden on
      the mkII/SR), Load ROM last, P3 Input (Keyboard, Swap Alt/Win: checked), Mode hidden on the PC-8001,
      SC0/SC1. Tape overlay checked through the mixer. Not checked: a VGA monitor, a 15 kHz CRT.
- [x] PCG-8100 sound on hardware (Mister 192, e940a28, 2026-11-13): PCG-8100 On, out 15,54 / out 12,232 /
      out 12,3 / out 2,8 (8253 ch 0 = 1000, mode 3; 02h bit 3): 3994 Hz, amplitude 5018; then beep 1 alone:
      2400 Hz, 5058. PCG/beep 0.99 (CSCP 0.98). misterkvms-cli record, tools/audio_tones.py.
- [x] Host-injected typing (KVMS) lost SHIFT: SHIFT and the key arrive together and BASIC reads SHIFT apart from
      the scan. pc8001_kbd delays a key pressed within 16 ms of a SHIFT change, and the events after it, by 16 ms
      (a queue, so each key keeps its own hold; SHIFT presses show at once). A first try that held the key back
      and then forced a 33 ms press dropped letters (the next key cut it short). Mister 192: ABCDEFGHIJ and
      AbCdEfGhIj exact with misterkvms-cli type --hold 50; at the default 30 ms hold shifted letters still drop
      (lowercase is fine), so type with --hold 50. The sim leads SHIFT by a frame, so the queue never engages there.
- [x] Tester zip under 20 MB: testers/PC8001_tester_20261105.zip (2.2 MB; rbf, the 3 boot ROMs, 11 tapes, 9 disks + 7 untested SR disks, README with how to start each). Not in git.
- [x] Tester zip 20261111: testers/PC8001_tester_20261111.zip (2.4 MB; cb921bb rbf, Pac Land added in 20261105b/c,
      README with the new OSD pages and fixes; the SR Game Pack disks 1-3 in place of Untested/). Not in git.
- [x] sys/ updated to Template_MiSTer e901a9f (2026-11-03; 4b14683): only hps_io.sv changed. Built, timing met,
      boot/OSD/beep checked on Mister 126 (~/dev2/sys-standard.md).
- [x] Tester request (Danjuro, 2026-11-12): right Alt as the KANA key. Right Alt now toggles the KANA lock (with
      Caps Lock and the JP kana key), left Alt stays GRPH, in both keyboard modes; Swap Alt/Win moves both to the
      Win keys. Sim: abc{RALT}abc{RALT}abc identical to the same with {CAPS} (abcチコソabc).
      Mister 192 (e940a28, slack 0.256 ns): the same abcチコソabc via KVMS ralt; left Alt+A / Alt+S still GRPH.
- [x] Tester zip 20261113: testers/PC8001_tester_20261113.zip (2.7 MB; e940a28 rbf: right Alt = KANA, Memory
      Image .n80 with 9 images, the tape hint, sys/ update; tapes + Galaxian 1980, Slot Machine, Dig Dug). Not in git.
- [x] Tester zip 20261114: testers/PC8001_tester_20261114.zip (2.7 MB; bdde72c rbf: SHIFT queue for host
      typing, SR row 0Ah keys; README: SR keys, hiragana via CONSOLE, PCG Galaxian (Game Kyojin) disk added and
      played on Mister 126 with the PCG-8100). Not in git.
- [x] Tester zip 20261116: testers/PC8001_tester_20261116.zip (2.7 MB; 3d02578 rbf = releases/PC8001_20261116.rbf:
      tape hint G9000 for the Game Pack 2017 tapes; the 5 tapes and their readme added). Not in git.
- [ ] Public repo.

## Open questions (from PLAN.md)
- Uncertain hardware (HARDWARE_NOTES.md section 10): uPD3301 retrace fields, 30h motor polarity, 31h bit 0,
  the dot clock, the cassette block format, the SR ports.
- PC-8001A (US) font/ROM as an option?

## Last
- [ ] CSAVE to a file (8251 transmit to a .cmt). Low value on MiSTer: the tape slot is load-only, and
      saving is covered by the disks (SC0/SC1, written back to the .d88).
