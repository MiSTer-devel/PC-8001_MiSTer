// NEC PC-8001: Z80 at 4 MHz, N-BASIC ROM, 16/32 KB RAM, text screen.
//
// Phase 0 skeleton (TODO.md). The text screen here is a stand-in: it reads the text VRAM (F300h, 120 bytes a
// row) straight from RAM with no attributes, where the real machine has the uPD8257 DMA copy each row into the
// uPD3301 CRTC while holding the Z80 with BUSREQ. Phase 1 replaces it with the two chips.
//
// boot.rom (ioctl index 0): N-BASIC (24 KB) at 0000h, font.rom (2 KB) at 6000h.
// Video: 14.318 MHz dot clock (clk_sys / 2), 896 x 260, 640 x 200 visible (MAME's numbers; HARDWARE_NOTES 4.1).

module pc8001
(
	input         clk_sys,        // 28.636 MHz
	input         reset,
	input         ram16k,         // 16 KB at C000-FFFF instead of 32 KB at 8000-FFFF

	input  [10:0] ps2_key,

	input         ioctl_download,
	input   [7:0] ioctl_index,
	input         ioctl_wr,
	input  [24:0] ioctl_addr,
	input   [7:0] ioctl_dout,

	output        ce_pix,
	output  [7:0] R, G, B,
	output reg    HSync, VSync,
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
// Clock enables: pixel 14.318 MHz, CPU 4.000 MHz (28.636364 * 40000 / 286364)
//----------------------------------------------------------------------------

reg ph = 0;
always @(posedge clk_sys) ph <= ~ph;
assign ce_pix = ph;

reg [18:0] cpu_acc = 0;
reg        ce_cpu = 0;
always @(posedge clk_sys) begin
	if (cpu_acc + 19'd40000 >= 19'd286364) begin
		cpu_acc <= cpu_acc + 19'd40000 - 19'd286364;
		ce_cpu <= 1'b1;
	end
	else begin
		cpu_acc <= cpu_acc + 19'd40000;
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
	.WAIT_n(1'b1),
	.INT_n(1'b1),
	.NMI_n(1'b1),
	.BUSRQ_n(1'b1),
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
reg [10:0] font_a;
wire       font_we = rom_dl & ioctl_wr & (ioctl_addr[24:11] == 14'h0C);   // 6000h-67FFh
always @(posedge clk_sys) begin
	if (font_we) font[ioctl_addr[10:0]] <= ioctl_dout;
	font_q <= font[font_a];
end

// RAM: 32 KB at 8000-FFFF (16 KB: C000-FFFF). Port b is the display's.
wire        is_ram = A[15] & (~ram16k | A[14]);
wire        ram_we = ~mreq_n & ~wr_n & is_ram;
wire  [7:0] ram_q, vram_q;
reg  [14:0] vram_a;

dpram_tdp #(.WORDS(32768), .AW(15)) ram
(
	.clk(clk_sys),
	.addr_a(A[14:0]), .we_a(ram_we), .d_a(cpu_dout), .q_a(ram_q),
	.addr_b(vram_a), .we_b(1'b0), .d_b(8'h00), .q_b(vram_q)
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

// TODO (phase 1): the keyboard matrix (00h-09h), uPD3301 (50h-51h), uPD8257 (60h-68h)
reg [7:0] io_dout;
always @(*) begin
	casez (A[7:0])
	8'h0?:   io_dout = 8'hFF;                        // keyboard rows: nothing pressed
	8'h4?:   io_dout = {2'b00, vrtc, 5'b00000};      // 5 VRTC (4 RTC data, 3 /EXTON, 2 CMT, 1 ACK, 0 BUSY)
	8'h5?:   io_dout = 8'h00;
	8'h6?:   io_dout = 8'h00;
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
// Video timing: 896 x 260 dots, 640 x 200 visible
//----------------------------------------------------------------------------

reg [9:0] hc = 0;   // dot
reg [8:0] vc = 0;   // line
always @(posedge clk_sys) if (ce_pix) begin
	if (hc == 10'd895) begin
		hc <= 0;
		vc <= (vc == 9'd259) ? 9'd0 : vc + 1'd1;
	end
	else hc <= hc + 1'd1;
	HSync <= (hc >= 10'd704) & (hc < 10'd768);
	if (hc == 10'd704) VSync <= (vc >= 9'd224) & (vc < 9'd227);
end

assign HBlank = hc >= 10'd640;
assign VBlank = vc >= 9'd200;
assign vrtc = VBlank;

//----------------------------------------------------------------------------
// Stand-in text screen (see the header): 80 x 25 or 40 x 25, characters only
//----------------------------------------------------------------------------

// Per 8-dot cur_cell (16 clocks): fetch the next cur_cell's character, then its font line. In 40 columns a cur_cell is
// 16 dots and takes the even bytes.
wire       w80 = port30[0];
wire [6:0] cur_cell = w80 ? hc[9:3] : hc[9:4];               // cur_cell on this line
wire [3:0] sub  = w80 ? {hc[2:0], ph} : hc[3:0];          // clock within the cur_cell (40 col: dot pairs)
wire [6:0] next_cell = (w80 ? (cur_cell == 7'd111) : (cur_cell == 7'd55)) ? 7'd0 : cur_cell + 1'd1;
wire [8:0] nline = (next_cell == 0) ? ((vc == 9'd259) ? 9'd0 : vc + 1'd1) : vc;
wire [4:0] nrow  = nline[7:3];

reg [7:0] shifter = 0, next_bits = 0;
reg       next_vis = 0, vis = 0;
always @(posedge clk_sys) begin
	case (sub)
	4'd0: vram_a <= 15'h7300 + nrow * 7'd120 + (w80 ? next_cell : {next_cell[5:0], 1'b0});
	4'd2: font_a <= {vram_q, nline[2:0]};
	4'd4: begin
		next_bits <= font_q;
		next_vis <= (w80 ? (next_cell < 7'd80) : (next_cell < 7'd40)) & (nline < 9'd200);
	end
	default: ;
	endcase
	if (ce_pix) begin
		if (w80 ? (hc[2:0] == 3'd7) : (hc[3:0] == 4'd15)) begin
			shifter <= next_bits;
			vis <= next_vis;
		end
		else if (w80 | hc[0]) shifter <= {shifter[6:0], 1'b0};
	end
end

wire dot = vis & shifter[7] & ~HBlank & ~VBlank;
assign R = {8{dot}};
assign G = {8{dot}};
assign B = {8{dot}};

endmodule
