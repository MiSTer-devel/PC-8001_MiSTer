// PC-8001 text screen: the uPD3301 CRT controller and the attribute/colour logic around it.
//
// Ports 50h (parameters, read: status) and 51h (commands, read: status).
//   commands (51h, bits 7-5): 0 reset (+5 parameters), 1 start display (bit 0 reverse), 2 set interrupt mask,
//   3 read light pen, 4 load cursor position (bit 0 cursor on, +2 parameters x, y), 5 reset interrupt,
//   6 reset counters.
//   reset parameters: P0 7 DMA character mode, 6-0 characters/row - 2; P1 7-6 blink rate, 5-0 rows - 1;
//   P2 7 skip line, 6-5 cursor type, 4-0 lines/character - 1; P3 7-5 vertical retrace rows - 1, 4-0 horizontal
//   retrace characters - 2; P4 7-5 attribute mode (bit 2 non-transparent, 1 colour, 0 no attributes),
//   4-0 attributes/row - 1.
//   status: 7 (set by reset, as CSCP), 4 VE display on, 3 U DMA underrun, 2 N, 1 E end of frame, 0 LP.
//
// The picture timing comes from the parameters, as on the chip: a line is (H + Z) characters of 8 dots at
// 14.318 MHz, a frame (L + V) rows of R lines. The ROM's 80x20 setting gives MAME's 896 x 260.
//
// Rows: the chip has a double row buffer and attribute FIFO; the next row is read by DMA (uPD8257 channel 2)
// while this row shows. Here row k+1 is fetched in the horizontal blank of the first line of row k (row 0 in
// the last retrace row): H character bytes, then the attribute pairs (position, code), then the pairs are
// expanded to one attribute per column. The expansion and the attribute bits follow CSCP (pc88.cpp
// pc88_crtc_t::expand_buffer, set_attrib, PC88::draw_text), the reference for this core:
//   internal attribute: 7-5 colour (G R B), 4 semigraphics, 3 underline, 2 overline, 1 secret, 0 reverse
//   colour mode, code bit 3 = 1: colour = code 7-5, semigraphics = code 4; bit 3 = 0: decoration
//   black/white mode: semigraphics = code 7, colour white
//   decoration: code 5 underline, 4 overline, 2 reverse, 0 secret, 1 blink (with bit 0 = 0: secret while the
//   blink is off)
// The attribute state carries from row to row (lines cleared at each row) and starts each frame as white.
// 40 columns (port 30h bit 0 = 0): each character takes two cells, the even byte, 16 dots wide.

module pc8001_crtc
(
	input             clk,          // 28.636 MHz
	input             reset,
	input             ce_pix,       // 14.318 MHz, every other clock

	input             io_sel,       // 50h-51h
	input             io_a0,
	input             io_wr,        // one clock per access
	input             io_rd,
	input       [7:0] din,
	output      [7:0] dout,

	input             w80,          // port 30h bit 0
	input             mono,         // port 30h bit 1: all characters white

	output reg [10:0] font_a,
	input       [7:0] font_q,       // one clock after font_a

	// DMA (rtl/i8257.sv channel 2) and the RAM port it reads (data one clock after the address)
	input             dma_ready,
	output            dma_adv,      // read the byte at the channel's address now
	input       [7:0] dma_q,

	// PC-8001mkII graphics (CSCP PC88::draw_screen): 640x200, 80 bytes a line, MSB on the left
	input             mk2,
	input       [7:0] gmode,        // port 31h: 2 mono 640 (320: blue), 3 graphics on, 4 320x200, 7-5 background G R B
	input       [6:0] dmask,        // port 53h: 0 text off, 1 graphics off (SR N80SR mode: 1-6 planes)
	output reg [13:0] gv_addr,
	input      [23:0] gv_q,         // one clock after gv_addr: {G, R, B} planes (the mkII: B)

	// PC-8001mkIISR in N80SR mode (CSCP boot mode V2; SR_NOTES.md): 31h bit 4 colour (else attribute), bit 2
	// 320 wide (40 bytes a line, page 1 at +2000h); palette 54h-5Bh; 33h bit 2 page 1 in front, bit 3 graphics
	// over text (all SR modes)
	input             sr,
	input             srv2,
	input       [1:0] prio,         // 33h bits 3-2
	input      [23:0] pal,          // 54h-5Bh: {G, R, B} of colour 7..0

	output            vrtc,
	output reg  [2:0] rgb,          // G R B... as {G, R, B}
	output            hblank,
	output            vblank,
	output            hsync,
	output            vsync
);

//----------------------------------------------------------------------------
// Registers
//----------------------------------------------------------------------------

reg  [6:0] H = 7'd80;       // characters/row
reg  [5:0] L = 6'd25;       // rows
reg  [4:0] R = 5'd8;        // lines/character
reg  [3:0] V = 4'd7;        // vertical retrace rows
reg  [5:0] Z = 6'd32;       // horizontal retrace characters
reg  [2:0] amode = 3'd0;    // attribute mode
reg  [4:0] anum = 5'd20;    // attributes/row
reg  [1:0] ctype = 2'd0;    // cursor type from P2
reg  [7:0] brate = 8'd24;   // blink period in frames (CSCP's reset value 24; P1: 32, 64, 96, 128)
reg  [7:0] status = 8'h00;
reg        rvv = 0;         // reverse display (start display bit 0)
reg  [1:0] imask = 2'b11;
reg        cur_on = 0;      // load cursor position bit 0
reg  [1:0] cur_type = 0;
reg  [6:0] cur_x = 7'h7F;
reg  [5:0] cur_y = 6'h3F;
reg  [2:0] cmd = 0;
reg  [2:0] pcnt = 0;

wire ve = status[4];

// mkII graphics mode, taken at each frame's end: {320x200, mono 640, graphics on, text off, blue}
reg  [4:0] gm = 0;
wire       g320 = mk2 & gm[4];
wire       gmono = mk2 & ~gm[4] & gm[3];
wire       gattr = mk2 & ~gm[4] & ~gm[3];      // 640x200 in the text's colours
// SR N80SR mode, taken with gm: {colour, 320 wide, graphics on, 53h bits 6-1, 33h bits 3-2}
reg [10:0] g2 = 0;
wire       g2_col = g2[10], g2_wide = g2[9], g2_on = g2[8];
wire [6:1] g2_m = g2[7:2];
wire       g2_pr1 = g2[0], g2_pr2 = g2[1];
wire       attr_rev = srv2 ? (g2_on & ~g2_col) : gattr;   // reverse cells: text black, graphics inverted

assign dout = status[3] ? (status & 8'hEF) : status;

//----------------------------------------------------------------------------
// Timing
//----------------------------------------------------------------------------

reg [2:0] dot = 0;
reg [6:0] hc = 0;           // character in the line
reg [4:0] lc = 0;           // line in the row
reg [5:0] row = 0;

wire [7:0] ht = H + Z;
wire [6:0] lv = L + V;
wire       line_end = (dot == 3'd7) & ({1'b0, hc} >= ht - 1'd1);
wire       row_end  = line_end & (lc >= R - 1'd1);
wire       frame_end = row_end & ({1'b0, row} >= lv - 1'd1);

always @(posedge clk) if (reset) begin
	dot <= 0; hc <= 0; lc <= 0; row <= 0;     // a frame starts at reset, as CSCP's
end
else if (ce_pix) begin
	dot <= dot + 1'd1;
	if (dot == 3'd7) hc <= line_end ? 7'd0 : hc + 1'd1;
	if (line_end) lc <= row_end ? 5'd0 : lc + 1'd1;
	if (row_end) row <= frame_end ? 6'd0 : row + 1'd1;
end

assign vrtc   = row >= L;
assign vblank = vrtc;
assign hblank = (hc == 7'd0) | (hc > H);    // the picture is one character late (fetch pipeline)
wire [7:0] hs_start = H + 8'd7;
assign hsync  = ({1'b0, hc} >= hs_start) & ({1'b0, hc} < hs_start + 8'd8);
assign vsync  = (row == L + (V > 4'd1)) & (lc < 5'd3);

//----------------------------------------------------------------------------
// Blink (CSCP pc88_crtc_t::update_blink, once a frame)
//----------------------------------------------------------------------------

reg  [7:0] bcnt = 0;
wire [7:0] bq = {2'b00, brate[7:2]};
wire       blink_attr = bcnt < bq;                                       // secret while on
wire       blink_cur  = (bcnt <= bq) | ((bcnt >= {1'b0, brate[7:1]}) & (bcnt <= {1'b0, brate[7:1]} + bq));

//----------------------------------------------------------------------------
// Row buffers: codes and expanded attributes, two rows
//----------------------------------------------------------------------------

reg [7:0] code_buf[0:255];
reg [7:0] attr_buf[0:255];
reg [7:0] cb_q, ab_q;
reg [7:0] rb_ra;
reg [7:0] rb_wa;
reg [7:0] cb_d, ab_d;
reg       cb_we, ab_we;
always @(posedge clk) begin
	if (cb_we) code_buf[rb_wa] <= cb_d;
	if (ab_we) attr_buf[rb_wa] <= ab_d;
	cb_q <= code_buf[rb_ra];
	ab_q <= attr_buf[rb_ra];
end

reg  [1:0] row_ok = 0;        // per buffer: fetched without underrun

//----------------------------------------------------------------------------
// Row fetch and attribute expansion
//----------------------------------------------------------------------------

localparam F_IDLE = 2'd0, F_ADDR = 2'd1, F_DATA = 2'd2, F_EXP = 2'd3;
reg  [1:0] fst = F_IDLE;
reg  [6:0] fi = 0;            // byte in the row
reg  [6:0] fx = 0;            // column being expanded
reg        fb = 0;            // target buffer
reg        fail = 0;          // this row underran
reg        frame_fail = 0;
reg        frame_on = 0;      // the display was on when this frame began: its rows are read
reg  [7:0] araw[0:39];        // attribute pairs as fetched
reg  [7:0] odd_code[0:39];    // non-transparent mode: the attribute bytes at odd columns
reg [79:0] flags = 0;         // columns with an attribute change
reg  [4:0] aptr = 0;
reg  [7:0] ad = 8'hE0;        // the attribute state

wire [7:0] nbytes = H + {anum, 1'b0};
wire [6:0] fi_h = fi - H;
wire [5:0] nrow = (({1'b0, row} >= lv - 1'd1)) ? 6'd0 : row + 1'd1;

function [7:0] set_attrib(input [7:0] d, input [7:0] code);
	reg [7:0] r;
	begin
		if (amode[1]) begin
			if (code[3]) r = {code[7:4], d[3:0]};
			else r = {d[7:4], code[5], code[4], code[0], code[2]};
		end
		else r = {3'b111, code[7], code[5], code[4], code[0], code[2]};
		if (~(amode[1] & code[3])) begin
			r[0] = r[0] ^ (amode[0] & rvv);
			r[1] = r[1] ^ (code[1] & ~code[0] & blink_attr);
		end
		set_attrib = r;
	end
endfunction

assign dma_adv = (fst == F_ADDR) & ({1'b0, fi} != nbytes) & dma_ready & ~fail;

wire [7:0] adv_attr = amode[2] ? (fx[0] ? ad : set_attrib(ad, odd_code[fx[6:1]])) :
                      amode[0] ? 8'hE0 :
                      flags[fx] ? set_attrib(ad, araw[{aptr, 1'b1}]) : ad;

always @(posedge clk) begin
	cb_we <= 0;
	ab_we <= 0;

	// the first line of a row, at its horizontal blank: fetch the next row
	if (ce_pix & (dot == 3'd7) & (hc == H - 1'd1) & (lc == 5'd0) & (fst == F_IDLE)) begin
		if (nrow == 6'd0) begin
			// a new frame
			frame_fail <= 0;
			frame_on <= ve;
			ad <= {7'b1110000, rvv};
			bcnt <= (bcnt + 1'd1 > brate) ? 8'd0 : bcnt + 1'd1;
		end
		if (nrow < L & ve & (frame_on | nrow == 6'd0)) begin
			fst <= F_ADDR;
			fb <= nrow[0];
			fi <= 0;
			fail <= (nrow == 6'd0) ? 1'b0 : frame_fail;
			flags <= 0;
		end
	end

	case (fst)
	F_ADDR: begin
		if (fi == nbytes) begin
			fst <= F_EXP;
			fx <= 0;
			aptr <= 0;
			if (~amode[2] & ~amode[0]) ad <= ad & 8'hF3;
		end
		else if (~dma_ready | fail) begin
			// underrun: the rest of the frame is blank
			if (~fail) status[3] <= 1'b1;
			fail <= 1;
			frame_fail <= 1;
			fi <= fi + 1'd1;
		end
		else fst <= F_DATA;
	end
	F_DATA: begin
`ifdef CRTC_DEBUG
		if (fi < 3 || fi == 80 || fi == 81) $display("fetch buf %0d fi %0d q %02x row %0d nrow? frame_on %0d", fb, fi, dma_q, row, frame_on);
`endif
		if (fi < H) begin
			rb_wa <= {fb, fi};
			cb_d <= dma_q;
			cb_we <= 1;
			if (fi[0]) odd_code[fi[6:1]] <= dma_q;
		end
		else begin
			araw[fi - H] <= dma_q;
			if (~fi_h[0] & (dma_q[6:0] < 7'd80)) flags[dma_q[6:0]] <= 1'b1;
		end
		fi <= fi + 1'd1;
		fst <= F_ADDR;
	end
	F_EXP: begin
		rb_wa <= {fb, fx};
		ab_d <= adv_attr;
		ab_we <= 1;
		ad <= adv_attr;
		if (~amode[2] & ~amode[0] & flags[fx]) aptr <= aptr + 1'd1;
		if (fx == H - 1'd1) begin
			fst <= F_IDLE;
			row_ok[fb] <= ~fail;
		end
		fx <= fx + 1'd1;
	end
	default: ;
	endcase

	// CPU access
	if (io_sel & io_wr) begin
		if (io_a0) begin
			cmd <= din[7:5];
			pcnt <= 0;
			case (din[7:5])
			3'd0: begin status <= (status & 8'hE9) | 8'h80; cur_x <= 7'h7F; cur_y <= 6'h3F; frame_on <= 0; end
			3'd1: begin rvv <= din[0]; status <= (status | 8'h90) & 8'hF7; end
			3'd2: begin if (~din[0]) status <= 8'h80; imask <= din[1:0]; end
			3'd3: status[0] <= 1'b0;
			3'd4: begin cur_on <= din[0]; cur_type <= ctype; end
			3'd5, 3'd6: status[2:1] <= 2'b00;
			default: ;
			endcase
		end
		else begin
			pcnt <= pcnt + 1'd1;
			case (cmd)
			3'd0: case (pcnt)
				3'd0: H <= (din[6:0] > 7'd78) ? 7'd80 : din[6:0] + 2'd2;
				3'd1: begin L <= din[5:0] + 1'd1; brate <= {din[7:6] + 1'd1, 5'b00000}; end
				3'd2: begin R <= din[4:0] + 1'd1; ctype <= din[6:5]; end
				3'd3: begin V <= din[7:5] + 1'd1; Z <= din[4:0] + 2'd2; end
				3'd4: begin amode <= din[7:5]; anum <= din[5] ? 5'd0 : (din[4:0] > 5'd19) ? 5'd20 : din[4:0] + 1'd1; end
				default: ;
				endcase
			3'd4: case (pcnt)
				3'd0: cur_x <= din[6:0];
				3'd1: cur_y <= din[5:0];
				default: ;
				endcase
			3'd6: status <= 0;
			default: ;
			endcase
		end
	end

	// end of the displayed rows
	if (ce_pix & line_end & (lc >= R - 1'd1) & (row == L - 1'd1) & ve & ~imask[0]) status[1] <= 1'b1;

	if (reset) begin
		H <= 7'd80; L <= 6'd25; R <= 5'd8; V <= 4'd7; Z <= 6'd32;
		amode <= 0; anum <= 5'd20; ctype <= 0; brate <= 8'd24;
		status <= 0; rvv <= 0; imask <= 2'b11; cur_on <= 0; cur_x <= 7'h7F; cur_y <= 6'h3F;
		cmd <= 0; pcnt <= 0;
		fst <= F_IDLE; row_ok <= 0; frame_fail <= 0; frame_on <= 0;
		bcnt <= 8'd2;    // the blink phase at reset matches CSCP's frame numbering (measured; arbitrary on a real machine)
	end
end

//----------------------------------------------------------------------------
// Picture: per 8-dot cell (16 clocks) read the cell's code and attribute, then its font line; shown one cell
// later
//----------------------------------------------------------------------------

wire [3:0] sub = {dot, ce_pix};        // ce_pix is high on the second clock of each dot
wire [6:0] src = w80 ? hc : {hc[6:1], 1'b0};

reg  [7:0] cc, ca;
reg  [7:0] shifter = 0, next_pat = 0;
reg  [2:0] col = 0, next_col = 0;
reg        next_vis = 0;

wire [7:0] sg = {{4{cc[{1'b0, lc[2:1]}]}}, {4{cc[{1'b1, lc[2:1]}]}}};

reg  [7:0] pat;
always @(*) begin
	pat = (lc >= 5'd8) ? 8'h00 : ca[4] ? sg : font_q;
	if (~w80) pat = hc[0] ? {pat[3], pat[3], pat[2], pat[2], pat[1], pat[1], pat[0], pat[0]}
	                      : {pat[7], pat[7], pat[6], pat[6], pat[5], pat[5], pat[4], pat[4]};
	if ((ca[2] & lc == 5'd0) | (ca[3] & lc >= 5'd7)) pat = 8'hFF;
	if (ca[0] & ~attr_rev) pat = ~pat;
end

wire cur_hit = cur_on & (row == cur_y) & (src == cur_x) & ~(cur_type[0] & blink_cur);

always @(posedge clk) begin
	if (sub == 4'd0) rb_ra <= {row[0], src};
	if (sub == 4'd2) begin
		cc <= ab_q[1] ? 8'h00 : cb_q;
		ca <= ab_q ^ (cur_hit ? (cur_type[1] ? 8'h01 : 8'h08) : 8'h00);
		font_a <= {(ab_q[1] ? 8'h00 : cb_q), lc[2:0]};
	end
	if (sub == 4'd5) begin
		next_pat <= pat;
		next_col <= (ca[7:5] == 3'd0) ? 3'd0 : (ca[7:5] | {3{mono}});
		next_vis <= (row < L) & (hc < H) & ve & frame_on & row_ok[row[0]];
	end
	if (ce_pix) begin
		if (dot == 3'd7) begin
			shifter <= next_vis ? next_pat : 8'h00;
			col <= next_col;
		end
		else shifter <= {shifter[6:0], 1'b0};
	end
end

//----------------------------------------------------------------------------
// mkII graphics: the byte under each cell, fetched with it; the mode taken at each frame's end (CSCP's
// snapshot at vblank), the background colour and the SR's palette at each line (raster colour changes)
//----------------------------------------------------------------------------

reg  [7:0] gline = 0;               // displayed line, 0-199
reg  [2:0] bg = 0;
reg [23:0] pl = 24'hFAC688;         // the palette for this line
always @(posedge clk) if (ce_pix) begin
	if (frame_end) gline <= 0;
	else if (line_end & (row < L) & (gline != 8'd255)) gline <= gline + 1'd1;
	if (line_end) bg <= mk2 ? gmode[7:5] : 3'd0;
	if (line_end) pl <= pal;
	if (line_end & (row == L)) begin
		gm <= {gmode[4], gmode[2], gmode[3] & ~dmask[1], dmask[0], gmode[2]};
		g2 <= {gmode[4], gmode[2], gmode[3], dmask[6:1], prio};
	end
end

// fetch: page 0 (or the 640 line's byte) at sub 0, page 1 at sub 2
reg [23:0] gb = 0, gb1 = 0;
reg  [7:0] next_g = 0, gcur = 0;
reg        next_rev = 0, crev = 0;
reg  [2:0] next_acol = 0, acol = 0;   // the cell's own colour (attribute mode)
reg [47:0] next_e = 0, ecur = 0;      // SR: {G1, R1, B1, G0, R0, B0}, 8 dots each
wire       gvis = gline < 8'd200;
wire       wide = srv2 & g2_wide;

function [7:0] dbl(input [7:0] b, input lo);   // a 320 byte's half for this cell, each pixel two dots
	reg [3:0] n;
	begin
		n = lo ? b[3:0] : b[7:4];
		dbl = {n[3], n[3], n[2], n[2], n[1], n[1], n[0], n[0]};
	end
endfunction

always @(posedge clk) begin
	if (sub == 4'd0) gv_addr <= wide ? {gline[7:0], 5'd0} + {gline[7:0], 3'd0} + {8'd0, hc[6:1]}   // x 40
	                                 : {gline[7:0], 6'd0} + {gline[7:0], 4'd0} + {7'd0, hc};      // x 80
	if (sub == 4'd2) begin
		gb <= ((mk2 & gm[2] & ~srv2) | (srv2 & g2_on)) & gvis ? gv_q : 24'd0;
		gv_addr <= gv_addr + 14'h2000;
	end
	if (sub == 4'd4) gb1 <= (srv2 & g2_on & gvis) ? gv_q : 24'd0;
	if (sub == 4'd5) begin
		next_rev <= attr_rev & ca[0];
		next_acol <= ca[7:5] | {3{mono}};
		next_g <= (gattr & ca[0]) ? ~gb[7:0] : gb[7:0];
		next_e <= wide ? {dbl(gb1[23:16], hc[0]), dbl(gb1[15:8], hc[0]), dbl(gb1[7:0], hc[0]),
		                  dbl(gb[23:16], hc[0]), dbl(gb[15:8], hc[0]), dbl(gb[7:0], hc[0])}
		               : {24'd0, gb};
	end
	if (ce_pix & (dot == 3'd7)) begin
		gcur <= next_g;
		crev <= next_rev;
		acol <= next_acol;
		ecur <= next_e;
	end
end

// attribute mode, reverse cells: the character un-reversed in black, the graphics byte inverted (CSCP)
wire       tpix = shifter[7] & ~(mk2 & gm[1]);
wire       gpix = gcur[~dot];
wire [1:0] gi = gcur[{~dot[2:1], 1'b1} -: 2];

// the mkII (and the SR in N80/N mode): 33h bit 3 on the SR puts a lit graphics pixel over the text
reg  [2:0] pix1, gcol1;
reg        gnz1;
always @(*) begin
	gcol1 = g320 ? ((gi == 2'd3) ? bg : (~gm[2] & gi == 2'd0) ? 3'd0 : {gi[1], gi[0], gm[0]}) :
	        gmono ? (gpix ? bg : 3'd0) : (gpix ? ((acol == 3'd0) ? bg : acol) : bg);
	gnz1 = g320 ? (gi != 2'd0) : gpix;
	if (~mk2)          pix1 = shifter[7] ? col : 3'd0;
	else if (sr & g2_pr2 & gnz1) pix1 = gcol1;
	else if (g320)     pix1 = tpix ? col : gcol1;
	else if (gmono)    pix1 = tpix ? col : gcol1;
	else               pix1 = tpix ? (crev ? 3'd0 : col) : gcol1;
end

// the SR in N80SR mode (CSCP draw_screen, V2): graphics index 0-8 (8: the cell's colour 0), text index 0-8
wire [2:0] k = ~dot;
wire       B0 = ecur[k], R0 = ecur[8 + k], G0 = ecur[16 + k];
wire       B1 = ecur[24 + k], R1 = ecur[32 + k], G1 = ecur[40 + k];
reg  [3:0] gx, tx;
reg        goff;                     // colour graphics off: colour 0 black
reg  [2:0] p0, p1, front, back;
reg        lit;
function [2:0] palc(input [23:0] p, input [2:0] i);
	palc = p[{2'd0, i} * 5'd3 +: 3];
endfunction
always @(*) begin
	p0 = g2_m[1] ? 3'd0 : {G0, R0, B0};
	p1 = g2_m[2] ? 3'd0 : {G1, R1, B1};
	front = g2_pr1 ? p1 : p0;
	back = g2_pr1 ? p0 : p1;
	lit = 0;
	if (g2_col) begin
		if (~g2_wide) begin
			goff = ~g2_on | g2_m[1];
			gx = goff ? 4'd0 : {1'b0, G0, R0, B0};
		end
		else begin
			goff = ~g2_on | (g2_m[1] & g2_m[2]);
			gx = goff ? 4'd0 : {1'b0, (front != 3'd0) ? front : back};
		end
	end
	else begin
		goff = 0;
		if (~g2_wide) lit = g2_on & (crev ^ ((B0 & ~g2_m[1]) | (R0 & ~g2_m[2]) | (G0 & ~g2_m[3])));
		else lit = g2_on & ~(&g2_m) & ((crev & ~w80) ^ ((B0 & ~g2_m[1]) | (R0 & ~g2_m[2]) | (G0 & ~g2_m[3]) |
		                                                (B1 & ~g2_m[4]) | (R1 & ~g2_m[5]) | (G1 & ~g2_m[6])));
		gx = lit ? ((acol == 3'd0) ? 4'd8 : {1'b0, acol}) : 4'd0;
	end
	tx = ~tpix ? 4'd0 : (crev | col == 3'd0) ? 4'd8 : {1'b0, col};
end
wire [2:0] pg0 = goff ? 3'd0 : g2_col ? palc(pl, 3'd0) : bg;
wire [2:0] pgx = (gx == 4'd0 || gx == 4'd8) ? pg0 : palc(pl, gx[2:0]);
wire [2:0] ptx = (tx == 4'd8) ? 3'd0 : tx[2:0];
wire [2:0] pix2 = (tx != 4'd0 && (~g2_pr2 || gx == 4'd0)) ? ptx : pgx;

always @(*) rgb = (~hblank & ~vblank) ? (srv2 ? pix2 : pix1) : 3'd0;

endmodule
