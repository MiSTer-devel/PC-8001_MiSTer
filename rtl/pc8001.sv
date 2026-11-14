// NEC PC-8001: Z80 at 4 MHz, N-BASIC ROM, 16/32 KB RAM, text screen.
//
// The text screen: the uPD8257 DMA (rtl/i8257.sv) copies each row of the text VRAM into the uPD3301 CRTC
// (rtl/pc8001_crtc.sv), holding the Z80 with BUSREQ for the bytes it reads, as CSCP models it: 5.95 CPU clocks
// a byte (XM8's measurement on a PC-8801MA2 in its 4 MHz mode). Each memory read gets one wait state (CSCP's
// PC-8001: memory wait on).
//
// boot.rom (ioctl index 0): N-BASIC (24 KB) at 0000h, font.rom (2 KB) at 6000h, and optionally disk.rom (the
// PC-80S31's 2 KB firmware) at 6800h: with it the disk unit (rtl/pc80s31.sv) is connected at FCh-FFh.
// Video: 14.318 MHz dot clock (clk_sys / 2); the line and frame come from the CRTC's parameters.

module pc8001 #(
	parameter int TURBO = 5           // tape turbo: the Z80 and the deck run TURBO x while the motor runs
)
(
	input         clk_sys,        // 28.636 MHz
	input         reset,
	input   [1:0] model,          // 0 PC-8001, 1 PC-8001mkII (boot1.rom), 2 PC-8001mkIISR (boot2.rom)
	input         n_mode,         // mkII/SR: the N-BASIC (N) mode DIP switch, else N80 (30h bit 0)
	input         v2,             // SR: N80SR mode (30h bit 1 = 0; CSCP boot mode 1), else n_mode decides
	input         ram16k,         // 16 KB at C000-FFFF instead of 32 KB at 8000-FFFF (PC-8001)
	input         pcg_on,         // PCG-8100 connected
	input  [64:0] rtc,            // hps_io RTC, for the uPD1990A
	input         kbd_us,         // keyboard: US symbols (else JIS positions)

	input  [10:0] ps2_key,

	input         tape_turbo,     // OSD Tape speed: TURBO x while the motor runs (taken when the motor starts)
	input         tape_rewind,
	output        tape_motor,
	output        tape_loaded,
	output        tape_too_big,
	output        tape_turbo_on,
	output [19:0] tape_position,
	output [19:0] tape_length,

	input         ioctl_download,
	input   [7:0] ioctl_index,
	input         ioctl_wr,
	input  [24:0] ioctl_addr,
	input   [7:0] ioctl_dout,
	output        ioctl_wait,     // boot1.rom / boot2.rom / a tape going to DDR3 (rtl/rom_store.sv, rtl/pc8001_cmt.sv)

	// the disk images (hps_io S0, S1) and DDR3 for them
	input   [1:0] img_mounted,    // drives 0 and 1 (S0, S1)
	input         img_readonly,
	input  [63:0] img_size,
	output [63:0] sd_lba,         // {drive 1, drive 0}
	output  [1:0] sd_rd,
	output  [1:0] sd_wr,
	input   [1:0] sd_ack,
	input   [8:0] sd_buff_addr,
	input   [7:0] sd_buff_dout,
	output  [7:0] sd_buff_din,
	input         sd_buff_wr,
	input         ddr_busy,
	output  [7:0] ddr_burstcnt,
	output [28:0] ddr_addr,
	input  [63:0] ddr_dout,
	input         ddr_dout_ready,
	output        ddr_rd,
	output [63:0] ddr_din,
	output  [7:0] ddr_be,
	output        ddr_we,
	output        disk_unit,      // DISK.ROM loaded
	output  [1:0] disk_ready,
	output  [1:0] disk_too_big,
	output        disk_motor,

	output        ce_pix,
	output  [7:0] R, G, B,
	output        HSync, VSync,
	output        HBlank, VBlank,

	output [15:0] audio,

	// for the simulator
	output [15:0] cpu_addr,
	output        cpu_ce,
	output        cpu_m1_n,
	output        dbg_io_wr,
	output        dbg_io_rd,
	output  [7:0] dbg_io_port,
	output  [7:0] dbg_io_data,
	output reg    prn_wr = 0,     // a byte for the printer (one clock; data in prn_data)
	output  [7:0] prn_data
);

//----------------------------------------------------------------------------
// Clock enables: pixel 14.318 MHz (crystal 2, 14.31818 MHz), CPU 3.9936 MHz (crystal 1, 15.9744 MHz / 4;
// PC-8001B user's manual 1.4, the parts list in PC-8001 katsuyo kenkyu; CSCP 3993624 Hz): 28.636364 * 39936 / 286364
//----------------------------------------------------------------------------

reg ph = 0;
always @(posedge clk_sys) ph <= ~ph;
assign ce_pix = ph;

reg [18:0] cpu_acc = 0;
reg        ce_cpu = 0;
wire [18:0] cpu_step = tape_turbo_on ? 19'(39936 * TURBO) : 19'd39936;
always @(posedge clk_sys) begin
	if (cpu_acc + cpu_step >= 19'd286364) begin
		cpu_acc <= cpu_acc + cpu_step - 19'd286364;
		ce_cpu <= 1'b1;
	end
	else begin
		cpu_acc <= cpu_acc + cpu_step;
		ce_cpu <= 1'b0;
	end
end
assign cpu_ce = ce_cpu;

//----------------------------------------------------------------------------
// CPU
//----------------------------------------------------------------------------

wire        mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n;
wire [15:0] A;
wire  [7:0] cpu_dout;
reg   [7:0] cpu_din;

wire kanji_busy, rs_busy;
wire irq;                      // mkII interrupts (below)
wire vrtc;
wire rom_dl = ioctl_download & (ioctl_index == 8'd0);         // boot.rom
wire sr = model == 2'd2;
wire mk2 = model != 2'd0;      // the mkII's features (the SR has them all)
wire srv2 = sr & v2;           // the SR in N80SR mode: its video, palette and waits (CSCP boot mode V2)
wire ext_dl = ioctl_download & (ioctl_index[5:0] == 6'd2);   // OSD Expansion ROM

// Memory wait: one wait state in each memory read, opcode fetches included, none in writes (CSCP on the
// PC-8001 and mkII: mem_wait_on, PC88::get_main_wait). The SR (its MEMWAIT switch off, CSCP's default): one in
// each opcode fetch in N80/N mode, none in N80SR mode. The T80 drives RD_n and MREQ_n low for T2 (and its
// waits) only, and samples WAIT_n in T2.
reg  rd_waited = 0;
wire gv_wait;
wire mem_wait = sr ? (~m1_n & ~srv2) : 1'b1;
wire wait_n = ~(~mreq_n & ~rd_n & ~rd_waited & mem_wait) & ~(~iorq_n & ~rd_n & (A[7:1] == 7'h74) & kanji_busy) & ~gv_wait & ~(n80_catch | n80_hold);
always @(posedge clk_sys) begin
	if (mreq_n | rd_n) rd_waited <= 0;
	else if (ce_cpu) rd_waited <= 1;
end

// DMA bus steal: 5.95 CPU clocks for each byte the CRTC reads (1523/256). A row (up to 120 bytes) comes in a
// burst, so the count needs 20 bits. None in the SR's N80SR mode (CSCP).
reg  [19:0] steal = 0;
wire        busrq = steal >= 20'd256;
wire        dma_adv;
always @(posedge clk_sys) begin
	if (cpu_reset) steal <= 0;
	else if (tape_turbo_on | srv2) steal <= 0;
	else steal <= steal + (dma_adv ? 20'd1523 : 20'd0) - ((ce_cpu & busrq) ? 20'd256 : 20'd0);
end
wire cpu_reset = reset | rom_dl | ext_dl | rs_busy;   // and while the ROM store copies the model's ROM

// .n80 (OSD Memory Image, index 3): a memory image from 8000h, started as CSCP's PC88::play_tape does: SP from
// FF3Eh, PC = FF3Dh (a RET in every image seen), the rest of the machine as it was (no reset). All of the file is
// loaded (CSCP: 8000-FF3F only): 40 of the 64 seen are 7F64h bytes, their RET going to a register-restore stub at
// FF40h (POPs, EXX, LD SP, JP into the ROM). The Z80 is held in the
// wait state of an opcode fetch while the image is written (ioctl_wait until then: no half-done instruction
// writes into it), then fed LD SP,nn and JP FF3Dh in place of that fetch and the next five reads. Not a fetch
// after a prefix (CB, DD, ED, FD): 31h would be read as that instruction's. No interrupt is taken from the
// download's start until the JP.
wire        n80_dl = ioctl_download & (ioctl_index[5:0] == 6'd3);
wire        m1_rd = ~m1_n & ~mreq_n & ~rd_n;
reg         m1_rdq = 0, after_pfx = 0;
reg   [7:0] m1_byte = 0;
wire        n80_catch = n80_dl & m1_rd & ~after_pfx;
reg         n80_hold = 0;      // the CPU held in an opcode fetch
reg   [2:0] n80_feed = 0;      // reads still to feed after the hold
reg  [15:0] n80_sp = 0;
reg         n80_rdq = 0;
wire        n80_on = n80_hold | (n80_feed != 3'd0);
wire  [2:0] n80_i = n80_hold ? 3'd0 : 3'd6 - n80_feed;
wire  [7:0] n80_byte = n80_i == 3'd0 ? 8'h31 : n80_i == 3'd1 ? n80_sp[7:0] : n80_i == 3'd2 ? n80_sp[15:8] :
                       n80_i == 3'd3 ? 8'hC3 : n80_i == 3'd4 ? 8'h3D : 8'hFF;
wire        n80_we = n80_hold & n80_dl & ioctl_wr & (ioctl_addr < 25'h8000);
always @(posedge clk_sys) begin
	n80_rdq <= ~mreq_n & ~rd_n;
	m1_rdq <= m1_rd;
	if (m1_rd) m1_byte <= cpu_din;
	if (m1_rdq & ~m1_rd) after_pfx <= (m1_byte == 8'hCB) | (m1_byte == 8'hDD) | (m1_byte == 8'hED) | (m1_byte == 8'hFD);
	if (cpu_reset) begin n80_hold <= 0; n80_feed <= 0; end
	else begin
		if (n80_catch) n80_hold <= 1;
		if (n80_we & (ioctl_addr[14:0] == 15'h7F3E)) n80_sp[7:0] <= ioctl_dout;
		if (n80_we & (ioctl_addr[14:0] == 15'h7F3F)) n80_sp[15:8] <= ioctl_dout;
		if (n80_hold & ~n80_dl) begin n80_hold <= 0; n80_feed <= 3'd6; end
		else if ((n80_feed != 3'd0) & n80_rdq & (mreq_n | rd_n)) n80_feed <= n80_feed - 1'd1;
	end
end
wire n80_wait = n80_dl & ~n80_hold;

`ifdef VERILATOR
T80s cpu
`else
T80s #(.Mode(0), .T2Write(1), .IOWait(1)) cpu
`endif
(
	.RESET_n(~cpu_reset),
	.CLK(clk_sys),
	.CEN(ce_cpu),
	.OUT0(1'b0),
	.WAIT_n(wait_n),
	.INT_n(~(irq & ~n80_dl & ~n80_on)),
	.NMI_n(1'b1),
	.BUSRQ_n(~(busrq & ~tape_turbo_on)),   // in turbo the display does not slow the Z80
	.M1_n(m1_n),
	.MREQ_n(mreq_n),
	.IORQ_n(iorq_n),
	.RD_n(rd_n),
	.WR_n(wr_n),
	.RFSH_n(rfsh_n),
	.HALT_n(),
	.BUSAK_n(),
	.A(A),
	.DI(cpu_din),
	.DO(cpu_dout)
);

assign cpu_addr = A;
assign cpu_m1_n = m1_n;

//----------------------------------------------------------------------------
// Memory
//----------------------------------------------------------------------------

// Main ROM, 32 KB: the PC-8001's N-BASIC at 0000-5FFF (from boot.rom as it loads), or the model's ROM copied
// from DDR3 at reset (rtl/rom_store.sv): the mkII's N80-BASIC / N-BASIC 0000-7FFF.
reg  [7:0] rom[0:32767];
reg  [7:0] rom_q;
wire       rom_we = rom_dl & ioctl_wr & (ioctl_addr < 25'h6000);
wire       rs_we;
wire [16:0] rs_a;
wire  [7:0] rs_d;
always @(posedge clk_sys) begin
	if (rs_we & (rs_a[16:15] == 2'd0)) rom[rs_a[14:0]] <= rs_d;
	else if (rom_we) rom[ioctl_addr[14:0]] <= ioctl_dout;
	rom_q <= rom[A[14:0]];
end

// SR: N80SR-BASIC (n80_3.rom, 40 KB; boot2.rom 8000h-11FFFh) at 0000-7FFF while 33h bit 7 is set: 0000-5FFF
// its first 24 KB, 6000-7FFF its 6000h (71h bit 0 = 1) or 8000h (0) (CSCP update_n80_read)
reg  [7:0] srrom[0:40959];
reg  [7:0] srrom_q;
reg  [7:0] port71 = 8'hFF;
wire [16:0] srrom_wa = rs_a - 17'h08000;
wire [15:0] srrom_ra = (A[14:13] == 2'b11 && !port71[0]) ? {1'b0, A[14:0]} + 16'h2000 : {1'b0, A[14:0]};
always @(posedge clk_sys) begin
	if (rs_we & (rs_a >= 17'h08000) & (rs_a < 17'h12000)) srrom[srrom_wa[15:0]] <= rs_d;
	srrom_q <= srrom[srrom_ra];
end

// mkII: 64 KB RAM (the low 32 KB here, 0000-7FFF over the ROM: 31h bit 1, or E2h bits 0 read / 4 write) and
// 16 KB graphics VRAM at 8000-BFFF while 5Ch selects it (5Fh: RAM). The CRTC's DMA reads the main RAM only.
// SR: three 16 KB planes, 5Ch blue, 5Dh red, 5Eh green; with 33h bit 6 the window is the ALU's (35h bit 7) or
// RAM, and 5Ch-5Fh select nothing (CSCP update_gvram_sel).
reg  [7:0] port31 = 8'h01;   // 0 ROM 0000-7FFF (else 0000-5FFF), 1 64 KB RAM, 2 mono 640, 3 graphics, 4 320x200, 7-5 G R B
reg  [7:0] portE2 = 0;       // 0 read, 4 write the low RAM
reg  [2:0] gv_plane = 0;     // 5Ch-5Eh: {G, R, B} one-hot (the mkII: 5Ch B only); 5Fh none
reg  [7:0] port53 = 0;       // 0 text off, 1 graphics off (SR: 1-6 planes, per mode)
reg  [7:0] port32 = 8'h98;   // SR: stored
reg  [7:0] port33 = 0;       // SR: 1 OPN interrupt mask, 2 320 page 1 in front, 3 graphics over text, 4 hiragana,
                             // 6 ALU window, 7 N80SR ROM
reg  [7:0] port34 = 0;       // SR ALU: bits i, i+4 the write operation of plane i (B, R, G)
reg  [7:0] port35 = 0;       // SR ALU: 2-0 compare colour, 5-4 write mode, 7 ALU on (with 33h bit 6)
reg  [2:0] pal[0:7];         // SR 54h-5Bh: {G, R, B}
reg        ghsm = 0;         // 40h bit 4 (SR: GVRAM wait 2 in N80/N mode)
reg [15:0] kanji_a = 0;      // E8h, E9h: the kanji ROM's 16-bit word (rtl/rom_store.sv fetches it)
reg        kanji_rd = 0;
wire [15:0] kanji_q;
wire       lo_rd = mk2 & (portE2[0] | port31[1]);
wire       lo_wr = mk2 & (portE2[4] | port31[1]);
wire       alu_on = sr & port33[6] & port35[7];
wire       gv_on = mk2 & ((gv_plane != 3'd0) | alu_on) & (A[15:14] == 2'b10);
// GVRAM wait (CSCP PC88::update_gvram_wait): with graphics on, 68 clocks an access while the screen is drawn
// (set as the display starts, cleared at vblank); otherwise as RAM. SR: 2 in N80SR mode or with 40h bit 4.
reg        gw_on = 0, vrtc_q = 0;
reg  [6:0] gw_cnt = 0;
reg        gw_done = 0;
always @(posedge clk_sys) begin
	vrtc_q <= vrtc;
	if (vrtc & ~vrtc_q) gw_on <= 0;
	else if (~vrtc & vrtc_q) gw_on <= mk2 & port31[3];
	if (mreq_n | (rd_n & wr_n)) begin gw_cnt <= 0; gw_done <= 0; end
	else if (gv_on & gw_on & ce_cpu & ~gw_done) begin
		gw_cnt <= gw_cnt + 1'd1;
		if (gw_cnt == ((sr & (v2 | ghsm)) ? 7'd1 : 7'd67)) gw_done <= 1'b1;
	end
end
assign gv_wait = ~mreq_n & (~rd_n | ~wr_n) & gv_on & gw_on & ~gw_done;

reg  [7:0] exram[0:32767];
reg  [7:0] exram_q;
always @(posedge clk_sys) begin
	if (~mreq_n & ~wr_n & ~A[15] & lo_wr) exram[A[14:0]] <= cpu_dout;
	exram_q <= exram[A[14:0]];
end
// the planes: port a the CPU's, b the CRTC's. A write goes in once, at its first clock (the ALU's read-modify-
// write takes the plane's byte at that address, which q_a holds by then).
wire [7:0] gvb_q, gvr_q, gvg_q;
wire [23:0] gv_q;              // {G, R, B} for the CRTC
wire [13:0] gv_addr;
reg        gv_wr_d = 0;
wire       gv_wr = ~mreq_n & ~wr_n & gv_on & ~gv_wr_d;
always @(posedge clk_sys) gv_wr_d <= ~mreq_n & ~wr_n;
reg  [7:0] alu_b = 0, alu_r = 0, alu_g = 0;   // the bytes latched by an ALU read
function [7:0] alu_op(input [7:0] p, input [7:0] d, input set, input inv);
	alu_op = {inv, set} == 2'b00 ? (p & ~d) : {inv, set} == 2'b01 ? (p | d) : {inv, set} == 2'b10 ? (p ^ d) : p;
endfunction
reg  [7:0] wb_d, wr_d, wg_d;
reg  [2:0] gv_we;
always @(*) begin
	wb_d = cpu_dout; wr_d = cpu_dout; wg_d = cpu_dout;
	gv_we = alu_on ? 3'b111 : gv_plane;
	if (alu_on) case (port35[5:4])
		2'd0: begin
			wb_d = alu_op(gvb_q, cpu_dout, port34[0], port34[4]);
			wr_d = alu_op(gvr_q, cpu_dout, port34[1], port34[5]);
			wg_d = alu_op(gvg_q, cpu_dout, port34[2], port34[6]);
		end
		2'd1: begin wb_d = alu_b; wr_d = alu_r; wg_d = alu_g; end
		2'd2: begin wb_d = alu_r; gv_we = 3'b001; end
		2'd3: begin wr_d = alu_b; gv_we = 3'b010; end
	endcase
end
always @(posedge clk_sys) if (~mreq_n & ~rd_n & gv_on & alu_on) begin alu_b <= gvb_q; alu_r <= gvr_q; alu_g <= gvg_q; end
wire [7:0] alu_rd = (port35[0] ? gvb_q : ~gvb_q) & (port35[1] ? gvr_q : ~gvr_q) & (port35[2] ? gvg_q : ~gvg_q);
wire [7:0] gvram_q = alu_on ? alu_rd : gv_plane[1] ? gvr_q : gv_plane[2] ? gvg_q : gvb_q;
dpram_tdp #(.WORDS(16384), .AW(14)) gvram_b
(
	.clk(clk_sys),
	.addr_a(A[13:0]), .we_a(gv_wr & gv_we[0]), .d_a(wb_d), .q_a(gvb_q),
	.addr_b(gv_addr), .we_b(1'b0), .d_b(8'h00), .q_b(gv_q[7:0])
);
dpram_tdp #(.WORDS(16384), .AW(14)) gvram_r
(
	.clk(clk_sys),
	.addr_a(A[13:0]), .we_a(gv_wr & gv_we[1] & sr), .d_a(wr_d), .q_a(gvr_q),
	.addr_b(gv_addr), .we_b(1'b0), .d_b(8'h00), .q_b(gv_q[15:8])
);
dpram_tdp #(.WORDS(16384), .AW(14)) gvram_g
(
	.clk(clk_sys),
	.addr_a(A[13:0]), .we_a(gv_wr & gv_we[2] & sr), .d_a(wg_d), .q_a(gvg_q),
	.addr_b(gv_addr), .we_b(1'b0), .d_b(8'h00), .q_b(gv_q[23:16])
);

// font.rom, 8x8 characters, bit 7 on the left
reg  [7:0] font[0:2047];
reg  [7:0] font_rq, pcg_rom_q;
wire [10:0] font_a;
wire       font_we = rom_dl & ioctl_wr & (ioctl_addr[24:11] == 14'h0C);   // 6000h-67FFh
reg  [9:0] pcg_addr = 0;
always @(posedge clk_sys) begin
	if (font_we) font[ioctl_addr[10:0]] <= ioctl_dout;
	font_rq <= font[font_a];
	pcg_rom_q <= font[{1'b1, pcg_addr}];
end

// PCG-8100 (as CSCP): RAM patterns for codes 80h-FFh, a copy of the ROM's at load. Port 00h the data, 01h the
// address (low 8 bits), 02h: bits 1-0 the address's top bits, bit 4 writes on its fall (bit 5: the ROM's
// pattern instead of the data), bits 3, 6, 7 sound channels 0-2 on; 0Ch-0Fh an 8253 at 3.9936 MHz.
reg  [7:0] pcg[0:1023];
reg  [7:0] pcg_q, pcg_data = 0, pcg_ctrl = 0;
reg        pcg_wr;
reg  [7:0] pcg_wd;
reg        pcg_sel;
always @(posedge clk_sys) begin
	if (font_we & ioctl_addr[10]) pcg[ioctl_addr[9:0]] <= ioctl_dout;
	else if (pcg_wr) pcg[pcg_addr] <= pcg_wd;
	pcg_q <= pcg[font_a[9:0]];
	pcg_sel <= pcg_on & font_a[10];
end
// SR: font80sr.rom's second half (boot2.rom 12800h-12FFFh), the hiragana for codes A0h-DFh with 33h bit 4.
// Those codes always show the ROM's glyphs on the SR (CSCP copies them over the PCG's each frame).
reg  [7:0] hira[0:2047];
reg  [7:0] hira_q;
reg        hira_sel = 0, srkana = 0;
wire       kana_code = (font_a[10:8] == 3'b101) | (font_a[10:8] == 3'b110);   // A0h-DFh
always @(posedge clk_sys) begin
	if (rs_we & (rs_a[16:11] == 6'b100101)) hira[rs_a[10:0]] <= rs_d;
	hira_q <= hira[font_a];
	hira_sel <= sr & port33[4] & kana_code;
	srkana <= sr & kana_code;
end
wire [7:0] font_q = hira_sel ? hira_q : (pcg_sel & ~srkana) ? pcg_q : font_rq;

// Expansion ROM, 6000-7FFF (8 KB, from the OSD; N-BASIC starts it at reset when it begins "AB"). Reads FFh
// until one is loaded.
reg  [7:0] ext_rom[0:8191];
reg  [7:0] ext_q;
reg        ext_ok = 0, old_ext_dl = 0;
always @(posedge clk_sys) begin
	old_ext_dl <= ext_dl;
	if (ext_dl & ~old_ext_dl) ext_ok <= 0;
	if (ext_dl & ioctl_wr & (ioctl_addr < 25'h2000)) begin
		ext_rom[ioctl_addr[12:0]] <= ioctl_dout;
		ext_ok <= 1;
	end
	ext_q <= ext_rom[A[12:0]];
end

// RAM: 32 KB at 8000-FFFF (16 KB: C000-FFFF). Port b is the display's.
wire        is_ram = A[15] & (mk2 | ~ram16k | A[14]);
wire        ram_we = ~mreq_n & ~wr_n & is_ram & ~gv_on;
wire  [7:0] ram_q, vram_q;
wire [15:0] dma_addr;
wire        dma_ready;

dpram_tdp #(.WORDS(32768), .AW(15)) ram
(
	.clk(clk_sys),
	.addr_a(n80_hold ? ioctl_addr[14:0] : A[14:0]), .we_a(n80_hold ? n80_we : ram_we),
	.d_a(n80_hold ? ioctl_dout : cpu_dout), .q_a(ram_q),
	.addr_b(dma_addr[14:0]), .we_b(1'b0), .d_b(8'h00), .q_b(vram_q)
);

wire [7:0] mem_dout = A[15] ? (gv_on ? gvram_q : is_ram ? ram_q : 8'hFF) :
                      lo_rd ? exram_q :
                      (sr & port33[7]) ? srrom_q :
                      (A[14:13] == 2'b11) ? ((mk2 & port31[0]) ? rom_q : ext_ok ? ext_q : 8'hFF) :   // 6000-7FFF: expansion ROM
                      rom_q;

//----------------------------------------------------------------------------
// I/O
//----------------------------------------------------------------------------

wire io_rd = ~iorq_n & ~rd_n & m1_n;
wire io_wr = ~iorq_n & ~wr_n & m1_n;

reg  [7:0] port30 = 0;     // bit 0: 80 columns, 1: mono, 2: CDS, 3: motor, 5-4: 8251 rate / RS-232C
reg        beep_on = 0;    // port 40h bit 5
reg  [7:0] port10 = 0;     // printer data; bits 2-0 the RTC's command, bit 3 its DIN
reg  [2:0] port40 = 0;     // bit 0 printer STROBE (data taken as it falls), 1 the RTC's STB (falling), 2 its CLK
wire       rtc_dout;
wire [7:0] crtc_dout, dma_dout, kbd_dout, usart_dout, disk_dout;
wire       cmt_dcd;

reg old_io_wr = 0;
always @(posedge clk_sys) begin
	old_io_wr <= io_wr;
	if (cpu_reset) begin
		port30 <= 0;
		beep_on <= 0;
		port10 <= 0;
		port40 <= 0;
		pcg_ctrl <= 0;
		port31 <= 8'h01;
		portE2 <= 0;
		gv_plane <= 0;
		port53 <= 0;
		port32 <= 8'h98;
		port33 <= srv2 ? 8'h80 : 8'h00;   // CSCP: N80SR mode boots N80SR-BASIC
		port34 <= 0;
		port35 <= 0;
		port71 <= 8'hFF;
		ghsm <= 0;
		for (int i = 0; i < 8; i = i + 1) pal[i] <= 3'(i);
	end
	else if (io_wr & ~old_io_wr) begin
		case (A[7:4])
		4'h1: port10 <= cpu_dout;
		4'h3: if (sr) case (A[3:0])                   // the SR decodes every port
			4'h0: port30 <= cpu_dout;
			4'h1: port31 <= cpu_dout;
			4'h2: port32 <= cpu_dout;
			4'h3: begin
				port33 <= cpu_dout;
				if (cpu_dout[6]) gv_plane <= 0;
			end
			4'h4: port34 <= cpu_dout;
			4'h5: port35 <= cpu_dout;
			default: ;
			endcase
			else if (mk2 & A[0]) port31 <= cpu_dout; else port30 <= cpu_dout;   // the mkII: odd ports 31h
		4'h5: if (mk2) case (A[3:0])
			4'h3: port53 <= cpu_dout;
			4'h4, 4'h5, 4'h6, 4'h7, 4'h8, 4'h9, 4'hA, 4'hB: if (sr) pal[A[2:0] - 3'd4] <= {cpu_dout[2], cpu_dout[1], cpu_dout[0]};
			4'hC: gv_plane <= (sr & port33[6]) ? 3'd0 : 3'b001;
			4'hD: if (sr) gv_plane <= port33[6] ? 3'd0 : 3'b010;
			4'hE: if (sr) gv_plane <= port33[6] ? 3'd0 : 3'b100;
			4'hF: gv_plane <= 0;
			default: ;
			endcase
		4'h7: if (sr & (A[3:0] == 4'h1)) port71 <= cpu_dout;
		4'hE: if (mk2) case (A[3:0])
			4'h2: portE2 <= cpu_dout;
			4'h8: kanji_a[7:0] <= cpu_dout;
			4'h9: kanji_a[15:8] <= cpu_dout;
			default: ;
			endcase
		4'h4: if (~sr | (A[3:0] == 4'h0)) begin beep_on <= cpu_dout[5]; port40 <= cpu_dout[2:0]; ghsm <= cpu_dout[4]; end
		default: ;
		endcase
	end
	prn_wr <= io_wr & ~old_io_wr & (A[7:4] == 4'h4) & port40[0] & ~cpu_dout[0];
	kanji_rd <= io_wr & ~old_io_wr & mk2 & (A[7:1] == 7'h74);
	pcg_wr <= 0;
	if (io_wr & ~old_io_wr & pcg_on) begin
		case (A[7:0])
		8'h00: pcg_data <= cpu_dout;
		8'h01: pcg_addr[7:0] <= cpu_dout;
		8'h02: begin
			pcg_wr <= pcg_ctrl[4] & ~cpu_dout[4];
			pcg_wd <= pcg_ctrl[5] ? pcg_rom_q : pcg_data;
			pcg_addr[9:8] <= cpu_dout[1:0];
			pcg_ctrl <= cpu_dout;
		end
		default: ;
		endcase
	end
end

reg [7:0] io_dout;
always @(*) begin
	casez (A[7:0])
	8'h0?:   io_dout = kbd_dout;                     // keyboard rows 00h-09h (the SR: 0Ah)
	8'h2?:   io_dout = usart_dout;                   // 8251
	// 5 VRTC, 4 RTC DOUT, 2 CMT carrier, 0 printer BUSY (never: the printer takes every byte); 7, 6, 1 high,
	// 3 low, as CSCP
	8'h4?:   io_dout = ~sr ? {2'b11, vrtc, rtc_dout, 1'b0, cmt_dcd, 2'b10} :
	                   (A[3:0] == 4'h0) ? {2'b11, vrtc, rtc_dout, 1'b0, cmt_dcd, 2'b10} :
	                   (A[3:1] == 3'b010) ? opn_dout : 8'hFF;   // SR: 44h OPN status, 45h its register
	// mkII: 30h the N80/N switch, 31h B9h (CSCP); SR: 30h also N80SR (bit 1 = 0), 31h 39h in N80SR mode
	8'h3?:   io_dout = ~mk2 ? 8'hFF :
	                   ~sr ? (A[0] ? 8'hB9 : {7'h7F, ~n_mode}) :
	                   (A[3:0] == 4'h0) ? {6'h3F, ~v2, ~n_mode} :
	                   (A[3:0] == 4'h1) ? {~v2, 7'h39} :
	                   (A[3:0] == 4'h2) ? port32 :
	                   (A[3:0] == 4'h3) ? port33 : 8'hFF;
	8'h5C:   io_dout = sr ? {5'h1F, gv_plane} : 8'hFF;
	8'h71:   io_dout = sr ? port71 : 8'hFF;
	8'h50, 8'h51: io_dout = crtc_dout;
	8'hE2:   io_dout = mk2 ? (~portE2 | 8'hEE) : 8'hFF;
	8'hE8:   io_dout = mk2 ? kanji_q[7:0] : 8'hFF;
	8'hE9:   io_dout = mk2 ? kanji_q[15:8] : 8'hFF;
	8'h6?:   io_dout = dma_dout;
	8'hFC, 8'hFD, 8'hFE, 8'hFF: io_dout = disk_dout;   // the disk unit's 8255 (FFh without DISK.ROM)
	default: io_dout = 8'hFF;
	endcase
end

//----------------------------------------------------------------------------
// mkII interrupts (CSCP PC88): Z80 mode 2, vector = level x 2. Level 0 the 8251's RxRDY (its level), 1 VRTC
// (as it rises), 2 a timer at 600 Hz, 4 (SR) the OPN as its IRQ rises unless 33h bit 1 masks it (clearing the
// mask with IRQ high requests too). E4h: levels below its value enabled (an acknowledge disables all until
// the next E4h write); E6h: bit 0 timer, 1 VRTC, 2 RxRDY, a source disabled loses its request.
//----------------------------------------------------------------------------

wire       rxrdy;
wire       opn_irq_n;
reg  [4:0] int_req = 0;
reg  [4:0] int_mask1 = 0;    // E4h
reg  [2:0] int_mask2 = 0;    // E6h, as {timer, VRTC, RxRDY} -> {level 2, 1, 0}
wire [4:0] int_act = int_req & int_mask1 & {2'b11, int_mask2};
assign     irq = mk2 & |int_act;
wire       inta = ~m1_n & ~iorq_n;
reg        inta_d = 0, vrtc_d = 0, opn_irq_d = 0;
reg  [2:0] int_lvl = 0;
reg [15:0] tmr = 0;          // 28.636364 MHz / 47727 = 600.0 Hz
always @(posedge clk_sys) begin
	inta_d <= inta;
	vrtc_d <= vrtc;
	opn_irq_d <= ~opn_irq_n;
	if (~inta) int_lvl <= int_act[0] ? 3'd0 : int_act[1] ? 3'd1 : int_act[2] ? 3'd2 : int_act[3] ? 3'd3 : 3'd4;
	tmr <= (tmr == 16'd47726) ? 16'd0 : tmr + 1'd1;
	if (cpu_reset | ~mk2) begin
		int_req <= 0; int_mask1 <= 0; int_mask2 <= 0;
	end
	else begin
		int_req[0] <= rxrdy & int_mask2[0];
		if (vrtc & ~vrtc_d & int_mask2[1]) int_req[1] <= 1'b1;
		if ((tmr == 0) & int_mask2[2]) int_req[2] <= 1'b1;
		if (sr & ~opn_irq_n & ~opn_irq_d & ~port33[1]) int_req[4] <= 1'b1;
		if (sr & ~opn_irq_n & io_wr & ~old_io_wr & (A[7:0] == 8'h33) & port33[1] & ~cpu_dout[1]) int_req[4] <= 1'b1;
		if (inta & ~inta_d) begin
			if (int_lvl != 3'd0) int_req[int_lvl] <= 1'b0;
			int_mask1 <= 0;
		end
		if (io_wr & ~old_io_wr & (A[7:0] == 8'hE4))
			int_mask1 <= (cpu_dout >= 8'd5) ? 5'b11111 : (cpu_dout == 8'd4) ? 5'b01111 : (cpu_dout == 8'd3) ? 5'b00111 :
			             (cpu_dout == 8'd2) ? 5'b00011 : (cpu_dout == 8'd1) ? 5'b00001 : 5'b00000;
		if (io_wr & ~old_io_wr & (A[7:0] == 8'hE6)) begin
			int_mask2 <= {cpu_dout[0], cpu_dout[1], cpu_dout[2]};
			if (~cpu_dout[0]) int_req[2] <= 1'b0;
			if (~cpu_dout[1]) int_req[1] <= 1'b0;
		end
	end
end

always @(*) cpu_din = ~mreq_n ? (n80_on ? n80_byte : mem_dout) : inta ? {4'd0, int_lvl, 1'b0} : io_dout;

assign dbg_io_wr = io_wr & ~old_io_wr;
reg old_io_rd = 0;
always @(posedge clk_sys) old_io_rd <= io_rd;
assign dbg_io_rd = io_rd & ~old_io_rd;
assign dbg_io_port = A[7:0];
assign dbg_io_data = io_wr ? cpu_dout : io_dout;
assign prn_data = port10;

//----------------------------------------------------------------------------
// Beeper: 40h bit 5 gates 2.4 kHz (14.318 MHz / 5966)
//----------------------------------------------------------------------------

reg [12:0] beep_div = 0;
reg        beep_sq = 0;
always @(posedge clk_sys) if (ce_pix) begin
	if (beep_div == 13'd2982) begin
		beep_div <= 0;
		beep_sq <= ~beep_sq;
	end
	else beep_div <= beep_div + 1'd1;
end

// PCG-8100 sound: the 8253's outputs, each switched by a bit of port 02h
// 3.9936 MHz from clk_sys (28.6364 MHz): 39936/286364 (19 bits: 286364 does not fit in 18)
reg  [18:0] pit_acc = 0;
reg         pit_ce = 0;
always @(posedge clk_sys) begin
	if (pit_acc + 19'd39936 >= 19'd286364) begin pit_acc <= pit_acc + 19'd39936 - 19'd286364; pit_ce <= 1'b1; end
	else begin pit_acc <= pit_acc + 19'd39936; pit_ce <= 1'b0; end
end
wire [2:0] pit_out;
pit8253 pit
(
	.clk(clk_sys),
	.reset(cpu_reset),
	.addr(A[1:0]),
	.din(cpu_dout),
	.dout(),
	.wr_stb(io_wr & ~old_io_wr & pcg_on & (A[7:2] == 6'b000011)),
	.rd_stb(1'b0),
	.clk_ce({3{pit_ce}}),
	.gate(3'b111),
	.gate_trig(3'b000),
	.out(pit_out)
);
wire [2:0] pcg_snd = pcg_on ? (pit_out & {pcg_ctrl[7], pcg_ctrl[6], pcg_ctrl[3]}) : 3'b000;
// SR: the YM2203 (jt03) at 44h (address; read: status) / 45h (data; read: the register), clocked at 3.9936 MHz
// (CSCP 3993624 Hz); its SSG's ports read FFh (no joystick)
wire        [7:0] opn_dout;
wire        [9:0] opn_psg;
wire signed [15:0] opn_fm;
jt03 opn
(
	.rst(cpu_reset | ~sr),
	.clk(clk_sys),
	.cen(pit_ce),
	.din(cpu_dout),
	.addr(A[0]),
	.cs_n(1'b0),
	.wr_n(~(io_wr & ~old_io_wr & sr & (A[7:1] == 7'h22))),
	.dout(opn_dout),
	.irq_n(opn_irq_n),
	.IOA_in(8'hFF),
	.IOB_in(8'hFF),
	.IOA_out(),
	.IOB_out(),
	.IOA_oe(),
	.IOB_oe(),
	.psg_A(), .psg_B(), .psg_C(),
	.fm_snd(opn_fm),
	.psg_snd(opn_psg),
	.snd(),
	.snd_sample(),
	.debug_view()
);

// unsigned: the beeper, the PCG's three channels, and (SR) the SSG (0..1023 x 16) and FM (/ 4, centred 2000h)
// Mix balance as CSCP's SR (beep : FM : SSG amplitudes ~ 1 : 1.05 : 0.89, measured on the same tones): on the
// SR the beep and PCG are halved, SSG x 11/16. Unsigned sum (max ~64 K with all three PCG channels on).
wire [15:0] opn_mix = sr ? ({3'd0, opn_psg, 3'd0} + {5'd0, opn_psg, 1'd0} + {6'd0, opn_psg}) +
                           {2'b00, ~opn_fm[15], opn_fm[14:2]} : 16'd0;
wire [15:0] beep_lv = sr ? 16'h1000 : 16'h2000;
wire [15:0] pcg_lv  = sr ? 16'h1000 : 16'h2000;   // a PCG channel as loud as the beep (CSCP: 0.98)
assign audio = ((beep_on & beep_sq) ? beep_lv : 16'h0000) + (pcg_snd[0] ? pcg_lv : 16'h0000) +
               (pcg_snd[1] ? pcg_lv : 16'h0000) + (pcg_snd[2] ? pcg_lv : 16'h0000) + opn_mix;

//----------------------------------------------------------------------------
// uPD1990A calendar clock
//----------------------------------------------------------------------------

upd1990a rtc_chip
(
	.clk(clk_sys),
	.reset(cpu_reset),
	.rtc(rtc),
	.c(port10[2:0]),
	.din(port10[3]),
	.stb(~port40[1]),
	.clk_in(port40[2]),
	.dout(rtc_dout)
);

//----------------------------------------------------------------------------
// Keyboard, DMA, CRTC
//----------------------------------------------------------------------------

pc8001_kbd kbd
(
	.clk(clk_sys),
	.reset(reset),
	.ps2_key(ps2_key),
	.kbd_us(kbd_us),
	.sr(sr),
	.row(A[3:0]),
	.data(kbd_dout)
);

i8257 dma
(
	.clk(clk_sys),
	.reset(cpu_reset),
	.io_sel(A[7:4] == 4'h6),
	.io_a(A[3:0]),
	.io_wr(dbg_io_wr),
	.io_rd(dbg_io_rd),
	.din(cpu_dout),
	.dout(dma_dout),
	.ch2_addr(dma_addr),
	.ch2_ready(dma_ready),
	.ch2_adv(dma_adv)
);

wire [2:0] rgb;
pc8001_crtc crtc
(
	.clk(clk_sys),
	.reset(cpu_reset),
	.ce_pix(ce_pix),
	.io_sel(A[7:1] == 7'h28),
	.io_a0(A[0]),
	.io_wr(dbg_io_wr),
	.io_rd(dbg_io_rd),
	.din(cpu_dout),
	.dout(crtc_dout),
	.w80(port30[0]),
	.mono(port30[1]),
	.mk2(mk2),
	.gmode(port31),
	.dmask(port53[6:0]),
	.gv_addr(gv_addr),
	.gv_q(gv_q),
	.sr(sr),
	.srv2(srv2),
	.prio(port33[3:2]),
	.pal({pal[7], pal[6], pal[5], pal[4], pal[3], pal[2], pal[1], pal[0]}),
	.font_a(font_a),
	.font_q(font_q),
	.dma_ready(dma_ready),
	.dma_adv(dma_adv),
	.dma_q(vram_q),
	.vrtc(vrtc),
	.rgb(rgb),
	.hblank(HBlank),
	.vblank(VBlank),
	.hsync(HSync),
	.vsync(VSync)
);

//----------------------------------------------------------------------------
// Cassette: 8251 and the deck
//----------------------------------------------------------------------------

wire       rx_stb;
wire [7:0] rx_byte, usart_mode;
i8251 usart
(
	.clk(clk_sys),
	.reset(cpu_reset),
	.io_sel(A[7:4] == 4'h2),
	.io_a0(A[0]),
	.io_wr(dbg_io_wr),
	.io_rd(dbg_io_rd),
	.din(cpu_dout),
	.dout(usart_dout),
	.rx_stb(rx_stb),
	.rx_byte(rx_byte),
	.dsr(1'b0),
	.mode(usart_mode),
	.command(),
	.tx_stb(),
	.tx_byte(),
	.rxrdy(rxrdy)
);

// The deck plays while the relay is on (30h bit 3 = 1: the ROM's MOTOR 1 / cassette-in at 0BF3h set it, 0C31h
// clears it) and the 8251 listens to the cassette (bits 5-4 = 00 or 01; 10/11 is RS-232C). The ROM leaves the
// relay on at idle (30h = 2Ah, RS-232C), where a real deck waits for its PLAY key; CLOAD writes 0Ah.
assign tape_motor = port30[3] & ~port30[5];

reg turbo_l = 0;
always @(posedge clk_sys) if (~tape_motor) turbo_l <= tape_turbo;
assign tape_turbo_on = turbo_l & tape_motor & tape_loaded;

wire        dc_busy, dc_ready, dc_rd, dc_we, dab_busy, dab_ready, dab_rd, dab_we;
wire [28:0] dc_addr, dab_addr;
wire [63:0] dc_din, dab_din;
wire  [7:0] dc_be, dab_be;
wire        rs_wait, cmt_wait;

pc8001_cmt cmt
(
	.clk(clk_sys),
	.reset(cpu_reset),
	.rewind(tape_rewind),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(cmt_wait),
	.motor(tape_motor),
	.baud1200(port30[5:4] == 2'b01),
	.usart_mode(usart_mode),
	.turbo(tape_turbo_on ? 4'(TURBO) : 4'd1),
	.rx_stb(rx_stb),
	.rx_byte(rx_byte),
	.dcd(cmt_dcd),
	.loaded(tape_loaded),
	.too_big(tape_too_big),
	.position(tape_position),
	.length(tape_length),
	.ddr_busy(dc_busy),
	.ddr_addr(dc_addr),
	.ddr_dout(ddr_dout),
	.ddr_dout_ready(dc_ready),
	.ddr_rd(dc_rd),
	.ddr_din(dc_din),
	.ddr_be(dc_be),
	.ddr_we(dc_we)
);

//----------------------------------------------------------------------------
// PC-80S31 disk unit
//----------------------------------------------------------------------------

wire disk_rom_wr = rom_dl & ioctl_wr & (ioctl_addr[24:11] == 14'h0D);   // 6800h-6FFFh
reg  disk_rom_ok = 0;
reg  old_rom_dl = 0;
always @(posedge clk_sys) begin
	old_rom_dl <= rom_dl;
	if (rom_dl & ~old_rom_dl) disk_rom_ok <= 0;
	else if (disk_rom_wr) disk_rom_ok <= 1;
end
assign disk_unit = disk_rom_ok;

pc80s31 disk
(
	.clk(clk_sys),
	.reset(cpu_reset),
	.rom_wr(disk_rom_wr),
	.rom_addr(ioctl_addr[10:0]),
	.rom_d(ioctl_dout),
	.rom_ok(disk_rom_ok),
	.addr(A[1:0]),
	.rd(dbg_io_rd & (A[7:2] == 6'b111111)),
	.wr(dbg_io_wr & (A[7:2] == 6'b111111)),
	.din(cpu_dout),
	.dout(disk_dout),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.ddr_busy(da_busy),
	.ddr_burstcnt(),
	.ddr_addr(da_addr),
	.ddr_dout(ddr_dout),
	.ddr_dout_ready(da_ready),
	.ddr_rd(da_rd),
	.ddr_din(da_din),
	.ddr_be(da_be),
	.ddr_we(da_we),
	.disk_ready(disk_ready),
	.disk_too_big(disk_too_big),
	.motor(disk_motor)
);

//----------------------------------------------------------------------------
// The models' ROMs (rtl/rom_store.sv) and DDR3: the disk unit and the ROM store share one arbiter, which shares
// the port with the tape (rtl/pc8001_cmt.sv)
//----------------------------------------------------------------------------

wire        da_busy, da_ready, da_rd, da_we, db_busy, db_ready, db_rd, db_we;
wire [28:0] da_addr, db_addr;
wire [63:0] da_din, db_din;
wire  [7:0] da_be, db_be;
assign ioctl_wait = rs_wait | cmt_wait | n80_wait;

rom_store rom_store
(
	.clk(clk_sys),
	.reset(reset),
	.model(model),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(rs_wait),
	.busy(rs_busy),
	.rom_a(rs_a),
	.rom_d(rs_d),
	.rom_we(rs_we),
	.kanji_rd(kanji_rd),
	.kanji_a(kanji_a),
	.kanji_q(kanji_q),
	.kanji_busy(kanji_busy),
	.ddr_busy(db_busy),
	.ddr_burstcnt(),
	.ddr_addr(db_addr),
	.ddr_dout(ddr_dout),
	.ddr_dout_ready(db_ready),
	.ddr_rd(db_rd),
	.ddr_din(db_din),
	.ddr_be(db_be),
	.ddr_we(db_we)
);

ddr_arb ddr_arb
(
	.clk(clk_sys),
	.a_rd(da_rd), .a_we(da_we), .a_addr(da_addr), .a_din(da_din), .a_be(da_be),
	.a_busy(da_busy), .a_dout_ready(da_ready),
	.b_rd(db_rd), .b_we(db_we), .b_addr(db_addr), .b_din(db_din), .b_be(db_be),
	.b_busy(db_busy), .b_dout_ready(db_ready),
	.ddr_busy(dab_busy), .ddr_dout_ready(dab_ready),
	.ddr_rd(dab_rd), .ddr_we(dab_we), .ddr_addr(dab_addr), .ddr_din(dab_din), .ddr_be(dab_be)
);

ddr_arb ddr_arb2
(
	.clk(clk_sys),
	.a_rd(dab_rd), .a_we(dab_we), .a_addr(dab_addr), .a_din(dab_din), .a_be(dab_be),
	.a_busy(dab_busy), .a_dout_ready(dab_ready),
	.b_rd(dc_rd), .b_we(dc_we), .b_addr(dc_addr), .b_din(dc_din), .b_be(dc_be),
	.b_busy(dc_busy), .b_dout_ready(dc_ready),
	.ddr_busy(ddr_busy), .ddr_dout_ready(ddr_dout_ready),
	.ddr_rd(ddr_rd), .ddr_we(ddr_we), .ddr_addr(ddr_addr), .ddr_din(ddr_din), .ddr_be(ddr_be)
);
assign ddr_burstcnt = 8'd1;

// colour index bits: 0 blue, 1 red, 2 green
assign B = {8{rgb[0]}};
assign R = {8{rgb[1]}};
assign G = {8{rgb[2]}};

endmodule
