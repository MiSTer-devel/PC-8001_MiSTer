// NEC PC-8001: Z80 at 4 MHz, N-BASIC ROM, 16/32 KB RAM, text screen.
//
// The text screen: the uPD8257 DMA (rtl/i8257.sv) copies each row of the text VRAM into the uPD3301 CRTC
// (rtl/pc8001_crtc.sv), holding the Z80 with BUSREQ for the bytes it reads, as CSCP models it: 5.95 CPU clocks
// a byte (XM8's measurement on a PC-8801MA2 in its 4 MHz mode). The Z80's M1 cycles get one wait state (CSCP
// PC88::get_m1_wait at 4 MHz).
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
	input         ram16k,         // 16 KB at C000-FFFF instead of 32 KB at 8000-FFFF

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

	// the disk image (hps_io S0) and DDR3 for it
	input         img_mounted,
	input         img_readonly,
	input  [63:0] img_size,
	output [31:0] sd_lba,
	output        sd_rd,
	output        sd_wr,
	input         sd_ack,
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
	output        disk_ready,
	output        disk_too_big,
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
	output  [7:0] dbg_io_data
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

wire rom_dl = ioctl_download & (ioctl_index[5:0] == 6'd0);

// M1 wait: one wait state in each opcode fetch (T80 samples WAIT_n in T2)
reg  m1_waited = 0;
wire wait_n = ~(~m1_n & ~mreq_n & ~m1_waited);
always @(posedge clk_sys) begin
	if (m1_n) m1_waited <= 0;
	else if (ce_cpu & ~mreq_n) m1_waited <= 1;
end

// DMA bus steal: 5.95 CPU clocks for each byte the CRTC reads (1523/256)
reg  [15:0] steal = 0;
wire        busrq = steal >= 16'd256;
wire        dma_adv;
always @(posedge clk_sys) begin
	if (cpu_reset) steal <= 0;
	else if (tape_turbo_on) steal <= 0;
	else steal <= steal + (dma_adv ? 16'd1523 : 16'd0) - ((ce_cpu & busrq) ? 16'd256 : 16'd0);
end
wire cpu_reset = reset | rom_dl;

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
	.INT_n(1'b1),
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

// N-BASIC, 0000-5FFF
reg  [7:0] rom[0:24575];
reg  [7:0] rom_q;
wire       rom_we = rom_dl & ioctl_wr & (ioctl_addr < 25'h6000);
always @(posedge clk_sys) begin
	if (rom_we) rom[ioctl_addr[14:0]] <= ioctl_dout;
	rom_q <= rom[A[14:0]];
end

// font.rom, 8x8 characters, bit 7 on the left
reg  [7:0] font[0:2047];
reg  [7:0] font_q;
wire [10:0] font_a;
wire       font_we = rom_dl & ioctl_wr & (ioctl_addr[24:11] == 14'h0C);   // 6000h-67FFh
always @(posedge clk_sys) begin
	if (font_we) font[ioctl_addr[10:0]] <= ioctl_dout;
	font_q <= font[font_a];
end

// RAM: 32 KB at 8000-FFFF (16 KB: C000-FFFF). Port b is the display's.
wire        is_ram = A[15] & (~ram16k | A[14]);
wire        ram_we = ~mreq_n & ~wr_n & is_ram;
wire  [7:0] ram_q, vram_q;
wire [15:0] dma_addr;
wire        dma_ready;

dpram_tdp #(.WORDS(32768), .AW(15)) ram
(
	.clk(clk_sys),
	.addr_a(A[14:0]), .we_a(ram_we), .d_a(cpu_dout), .q_a(ram_q),
	.addr_b(dma_addr[14:0]), .we_b(1'b0), .d_b(8'h00), .q_b(vram_q)
);

wire [7:0] mem_dout = A[15] ? (is_ram ? ram_q : 8'hFF) :
                      (A[14:13] == 2'b11) ? 8'hFF :   // 6000-7FFF: expansion ROM, none
                      rom_q;

//----------------------------------------------------------------------------
// I/O
//----------------------------------------------------------------------------

wire io_rd = ~iorq_n & ~rd_n & m1_n;
wire io_wr = ~iorq_n & ~wr_n & m1_n;

reg  [7:0] port30 = 0;     // bit 0: 80 columns, 1: mono, 2: CDS, 3: motor, 5-4: 8251 rate / RS-232C
reg        beep_on = 0;    // port 40h bit 5
wire       vrtc;
wire [7:0] crtc_dout, dma_dout, kbd_dout, usart_dout, disk_dout;
wire       cmt_dcd;

reg old_io_wr = 0;
always @(posedge clk_sys) begin
	old_io_wr <= io_wr;
	if (cpu_reset) begin
		port30 <= 0;
		beep_on <= 0;
	end
	else if (io_wr & ~old_io_wr) begin
		case (A[7:4])
		4'h3: port30 <= cpu_dout;
		4'h4: beep_on <= cpu_dout[5];
		default: ;
		endcase
	end
end

reg [7:0] io_dout;
always @(*) begin
	casez (A[7:0])
	8'h0?:   io_dout = kbd_dout;                     // keyboard rows 00h-09h
	8'h2?:   io_dout = usart_dout;                   // 8251
	8'h4?:   io_dout = {2'b00, vrtc, 2'b00, cmt_dcd, 2'b00};   // 5 VRTC, 2 CMT carrier (4 RTC, 3 /EXTON, 1 ACK, 0 BUSY)
	8'h50, 8'h51: io_dout = crtc_dout;
	8'h6?:   io_dout = dma_dout;
	8'hFC, 8'hFD, 8'hFE, 8'hFF: io_dout = disk_dout;   // the disk unit's 8255 (FFh without DISK.ROM)
	default: io_dout = 8'hFF;
	endcase
end

always @(*) cpu_din = ~mreq_n ? mem_dout : io_dout;

assign dbg_io_wr = io_wr & ~old_io_wr;
reg old_io_rd = 0;
always @(posedge clk_sys) old_io_rd <= io_rd;
assign dbg_io_rd = io_rd & ~old_io_rd;
assign dbg_io_port = A[7:0];
assign dbg_io_data = io_wr ? cpu_dout : io_dout;

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
assign audio = (beep_on & beep_sq) ? 16'h2000 : 16'h0000;

//----------------------------------------------------------------------------
// Keyboard, DMA, CRTC
//----------------------------------------------------------------------------

pc8001_kbd kbd
(
	.clk(clk_sys),
	.reset(reset),
	.ps2_key(ps2_key),
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
	.tx_byte()
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
	.ddr_busy(ddr_busy),
	.ddr_burstcnt(ddr_burstcnt),
	.ddr_addr(ddr_addr),
	.ddr_dout(ddr_dout),
	.ddr_dout_ready(ddr_dout_ready),
	.ddr_rd(ddr_rd),
	.ddr_din(ddr_din),
	.ddr_be(ddr_be),
	.ddr_we(ddr_we),
	.ext_sel(1'b0),
	.ext_m_addr(20'd0),
	.ext_m_rd(1'b0),
	.ext_m_we(1'b0),
	.ext_m_d(8'd0),
	.ext_m_q(),
	.ext_m_done(),
	.ext_m_ready(),
	.ext_m_wprot(),
	.disk_ready(disk_ready),
	.disk_too_big(disk_too_big),
	.motor(disk_motor)
);

// colour index bits: 0 blue, 1 red, 2 green
assign B = {8{rgb[0]}};
assign R = {8{rgb[1]}};
assign G = {8{rgb[2]}};

endmodule
