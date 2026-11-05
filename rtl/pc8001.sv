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
	input   [1:0] model,          // 0 PC-8001, 1 PC-8001mkII (boot1.rom)
	input         n_mode,         // mkII: the N-BASIC (N) mode DIP switch, else N80 (30h bit 0)
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
	output [16:0] tape_position,
	output [16:0] tape_length,

	input         ioctl_download,
	input   [7:0] ioctl_index,
	input         ioctl_wr,
	input  [24:0] ioctl_addr,
	input   [7:0] ioctl_dout,
	output        ioctl_wait,     // boot1.rom going to DDR3 (rtl/rom_store.sv)

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
wire mk2 = model == 2'd1;
wire ext_dl = ioctl_download & (ioctl_index[5:0] == 6'd2);   // OSD Expansion ROM

// Memory wait: one wait state in each memory read, opcode fetches included, none in writes (CSCP on the
// PC-8001: mem_wait_on, PC88::get_main_wait). The T80 drives RD_n and MREQ_n low for T2 (and its waits) only,
// and samples WAIT_n in T2.
reg  rd_waited = 0;
wire gv_wait;
wire wait_n = ~(~mreq_n & ~rd_n & ~rd_waited) & ~(~iorq_n & ~rd_n & (A[7:1] == 7'h74) & kanji_busy) & ~gv_wait;
always @(posedge clk_sys) begin
	if (mreq_n | rd_n) rd_waited <= 0;
	else if (ce_cpu) rd_waited <= 1;
end

// DMA bus steal: 5.95 CPU clocks for each byte the CRTC reads (1523/256). A row (up to 120 bytes) comes in a
// burst, so the count needs 20 bits.
reg  [19:0] steal = 0;
wire        busrq = steal >= 20'd256;
wire        dma_adv;
always @(posedge clk_sys) begin
	if (cpu_reset) steal <= 0;
	else if (tape_turbo_on) steal <= 0;
	else steal <= steal + (dma_adv ? 20'd1523 : 20'd0) - ((ce_cpu & busrq) ? 20'd256 : 20'd0);
end
wire cpu_reset = reset | rom_dl | ext_dl | rs_busy;   // and while the ROM store copies the model's ROM

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
	.INT_n(~irq),
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
wire [14:0] rs_a;
wire  [7:0] rs_d;
always @(posedge clk_sys) begin
	if (rs_we) rom[rs_a] <= rs_d;
	else if (rom_we) rom[ioctl_addr[14:0]] <= ioctl_dout;
	rom_q <= rom[A[14:0]];
end

// mkII: 64 KB RAM (the low 32 KB here, 0000-7FFF over the ROM: 31h bit 1, or E2h bits 0 read / 4 write) and
// 16 KB graphics VRAM at 8000-BFFF while 5Ch selects it (5Fh: RAM). The CRTC's DMA reads the main RAM only.
reg  [7:0] port31 = 8'h01;   // 0 ROM 0000-7FFF (else 0000-5FFF), 1 64 KB RAM, 2 mono 640, 3 graphics, 4 320x200, 7-5 G R B
reg  [7:0] portE2 = 0;       // 0 read, 4 write the low RAM
reg        gv_sel = 0;       // 5Ch
reg  [7:0] port53 = 0;       // 0 text off, 1 graphics off
reg [15:0] kanji_a = 0;      // E8h, E9h: the kanji ROM's 16-bit word (rtl/rom_store.sv fetches it)
reg        kanji_rd = 0;
wire [15:0] kanji_q;
wire       lo_rd = mk2 & (portE2[0] | port31[1]);
wire       lo_wr = mk2 & (portE2[4] | port31[1]);
wire       gv_on = mk2 & gv_sel & (A[15:14] == 2'b10);
// GVRAM wait (CSCP PC88::update_gvram_wait): with graphics on, 68 clocks an access while the screen is drawn
// (set as the display starts, cleared at vblank); otherwise as RAM
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
		if (gw_cnt == 7'd67) gw_done <= 1'b1;
	end
end
assign gv_wait = ~mreq_n & (~rd_n | ~wr_n) & gv_on & gw_on & ~gw_done;

reg  [7:0] exram[0:32767];
reg  [7:0] exram_q;
always @(posedge clk_sys) begin
	if (~mreq_n & ~wr_n & ~A[15] & lo_wr) exram[A[14:0]] <= cpu_dout;
	exram_q <= exram[A[14:0]];
end
wire [7:0] gvram_q, gv_q;
wire [13:0] gv_addr;
dpram_tdp #(.WORDS(16384), .AW(14)) gvram
(
	.clk(clk_sys),
	.addr_a(A[13:0]), .we_a(~mreq_n & ~wr_n & gv_on), .d_a(cpu_dout), .q_a(gvram_q),
	.addr_b(gv_addr), .we_b(1'b0), .d_b(8'h00), .q_b(gv_q)
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
wire [7:0] font_q = pcg_sel ? pcg_q : font_rq;

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
	.addr_a(A[14:0]), .we_a(ram_we), .d_a(cpu_dout), .q_a(ram_q),
	.addr_b(dma_addr[14:0]), .we_b(1'b0), .d_b(8'h00), .q_b(vram_q)
);

wire [7:0] mem_dout = A[15] ? (gv_on ? gvram_q : is_ram ? ram_q : 8'hFF) :
                      lo_rd ? exram_q :
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
		gv_sel <= 0;
		port53 <= 0;
	end
	else if (io_wr & ~old_io_wr) begin
		case (A[7:4])
		4'h1: port10 <= cpu_dout;
		4'h3: if (mk2 & A[0]) port31 <= cpu_dout; else port30 <= cpu_dout;   // the mkII: odd ports 31h
		4'h5: if (mk2) case (A[3:0])
			4'h3: port53 <= cpu_dout;
			4'hC: gv_sel <= 1'b1;
			4'hF: gv_sel <= 1'b0;
			default: ;
			endcase
		4'hE: if (mk2) case (A[3:0])
			4'h2: portE2 <= cpu_dout;
			4'h8: kanji_a[7:0] <= cpu_dout;
			4'h9: kanji_a[15:8] <= cpu_dout;
			default: ;
			endcase
		4'h4: begin beep_on <= cpu_dout[5]; port40 <= cpu_dout[2:0]; end
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
	8'h0?:   io_dout = kbd_dout;                     // keyboard rows 00h-09h
	8'h2?:   io_dout = usart_dout;                   // 8251
	// 5 VRTC, 4 RTC DOUT, 2 CMT carrier, 0 printer BUSY (never: the printer takes every byte); 7, 6, 1 high,
	// 3 low, as CSCP
	8'h4?:   io_dout = {2'b11, vrtc, rtc_dout, 1'b0, cmt_dcd, 2'b10};
	8'h3?:   io_dout = ~mk2 ? 8'hFF : A[0] ? 8'hB9 : {7'h7F, ~n_mode};   // mkII: 30h the N80/N switch, 31h B9h (CSCP)
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
// (as it rises), 2 a timer at 600 Hz. E4h: levels below its value enabled (an acknowledge disables all until
// the next E4h write); E6h: bit 0 timer, 1 VRTC, 2 RxRDY, a source disabled loses its request.
//----------------------------------------------------------------------------

wire       rxrdy;
reg  [2:0] int_req = 0;
reg  [2:0] int_mask1 = 0;    // E4h
reg  [2:0] int_mask2 = 0;    // E6h, as {timer, VRTC, RxRDY} -> {level 2, 1, 0}
wire [2:0] int_act = int_req & int_mask1 & int_mask2;
assign     irq = mk2 & |int_act;
wire       inta = ~m1_n & ~iorq_n;
reg        inta_d = 0, vrtc_d = 0;
reg  [1:0] int_lvl = 0;
reg [15:0] tmr = 0;          // 28.636364 MHz / 47727 = 600.0 Hz
always @(posedge clk_sys) begin
	inta_d <= inta;
	vrtc_d <= vrtc;
	if (~inta) int_lvl <= int_act[0] ? 2'd0 : int_act[1] ? 2'd1 : 2'd2;
	tmr <= (tmr == 16'd47726) ? 16'd0 : tmr + 1'd1;
	if (cpu_reset | ~mk2) begin
		int_req <= 0; int_mask1 <= 0; int_mask2 <= 0;
	end
	else begin
		int_req[0] <= rxrdy & int_mask2[0];
		if (vrtc & ~vrtc_d & int_mask2[1]) int_req[1] <= 1'b1;
		if ((tmr == 0) & int_mask2[2]) int_req[2] <= 1'b1;
		if (inta & ~inta_d) begin
			if (int_lvl != 2'd0) int_req[int_lvl] <= 1'b0;
			int_mask1 <= 0;
		end
		if (io_wr & ~old_io_wr & (A[7:0] == 8'hE4))
			int_mask1 <= (cpu_dout >= 8'd3) ? 3'b111 : (cpu_dout == 8'd2) ? 3'b011 : (cpu_dout == 8'd1) ? 3'b001 : 3'b000;
		if (io_wr & ~old_io_wr & (A[7:0] == 8'hE6)) begin
			int_mask2 <= {cpu_dout[0], cpu_dout[1], cpu_dout[2]};
			if (~cpu_dout[0]) int_req[2] <= 1'b0;
			if (~cpu_dout[1]) int_req[1] <= 1'b0;
		end
	end
end

always @(*) cpu_din = ~mreq_n ? mem_dout : inta ? {5'd0, int_lvl, 1'b0} : io_dout;

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
reg  [17:0] pit_acc = 0;
reg         pit_ce = 0;
always @(posedge clk_sys) begin
	if (pit_acc + 18'd39936 >= 18'd286364) begin pit_acc <= pit_acc + 18'd39936 - 18'd286364; pit_ce <= 1'b1; end
	else begin pit_acc <= pit_acc + 18'd39936; pit_ce <= 1'b0; end
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
assign audio = ((beep_on & beep_sq) ? 16'h2000 : 16'h0000) + (pcg_snd[0] ? 16'h1800 : 16'h0000) +
               (pcg_snd[1] ? 16'h1800 : 16'h0000) + (pcg_snd[2] ? 16'h1800 : 16'h0000);

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
	.dmask(port53[1:0]),
	.gv_addr(gv_addr),
	.gv_q(gv_q),
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
	.length(tape_length)
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
// The models' ROMs (rtl/rom_store.sv) and DDR3: the disk unit and the ROM store share the port
//----------------------------------------------------------------------------

wire        da_busy, da_ready, da_rd, da_we, db_busy, db_ready, db_rd, db_we;
wire [28:0] da_addr, db_addr;
wire [63:0] da_din, db_din;
wire  [7:0] da_be, db_be;

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
	.ioctl_wait(ioctl_wait),
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
	.ddr_busy(ddr_busy), .ddr_dout_ready(ddr_dout_ready),
	.ddr_rd(ddr_rd), .ddr_we(ddr_we), .ddr_addr(ddr_addr), .ddr_din(ddr_din), .ddr_be(ddr_be)
);
assign ddr_burstcnt = 8'd1;

// colour index bits: 0 blue, 1 red, 2 green
assign B = {8{rgb[0]}};
assign R = {8{rgb[1]}};
assign G = {8{rgb[2]}};

endmodule
