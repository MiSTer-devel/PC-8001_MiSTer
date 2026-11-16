// SPDX-License-Identifier: GPL-2.0-only
// Next-step hint for the tape overlay (~/dev2/tape-standard.md rules 25-28): what to type to load and start
// the tape, read from the tape's own headers as the image downloads (never from the file name).
//
// The bytes the 8251 will see (a .cmt whole; a .t88's data tags, 101h, after their 12-byte header) are scanned
// for the first file and the start of the second:
//   BASIC (CSAVE): ten D3h, a 6-byte name (printable or 00h), the program, which ends with a line's 00h and a
//     0000h link: the first 00 00 00. Hint: TYPE CLOAD"name" <ret> at the tape's start, TYPE RUN <ret> once it
//     has loaded.
//   Machine code (monitor W): 3Ah, address hi, lo, checksum (the three add to 0), then records 3Ah, length,
//     data, checksum, up to a record of length 0. Hint: TYPE MON <ret> L <ret> at the start, nothing after:
//     the start address (G) is not on the tape, and "the first load address" fails for some tapes (Check
//     Point, Circuit), so it is not shown (rule 25). Nor is a second L for a second block: the monitor stops
//     the motor well after a block's end (Moon Alien at 5x: 55 bytes into the next block's header), so the
//     next L would not find that header.
//     Known tapes: a monitor tape in the table below (its first block's load address, length and 16-bit sum
//     of the bytes after the header, so the tape's content, not its name) shows TYPE G<start> <ret> once
//     that block has loaded, as RUN for BASIC. Ishizu's Game Pack 2017 (Galaxy Fly, Space Fighter, Submarine,
//     Othello, Dot Eater: MON, L, G9000 from its readme); none of the corpus's 44 monitor tapes matches.
// RUN is not shown when a machine-code block follows the BASIC program: some such programs load it themselves
// (Kumo Vader, Qix), others need MON, L, Ctrl+B first (Galaxian 1980, Marine Belt, Deep Scan: Neo Kobe's
// "{cload X mon L}"), and nothing on the tape tells them apart (69 of the 107 BASIC tapes).
// A first header that is neither (Pac Land's sides B-D, its own loader's blocks) gives no hint at all. RUN
// shows only while the tape sits past the BASIC program's end and no more than 64 bytes into the next file
// (CLOAD stops the motor a few bytes after the end: Kumo Vader 8, River Patrol 8, at 5x; rule 26), and is
// removed by Return; after that nothing more is shown until the tape is mounted again or rewound (a
// program that loads the rest of its tape itself, such as a BASIC loader, is not followed).
// Offsets are image offsets, as the player's position (rtl/pc8001_cmt.sv ptr).

module tape_hint
(
	input             clk,

	input             ioctl_download,
	input       [7:0] ioctl_index,
	input             ioctl_wr,
	input      [24:0] ioctl_addr,
	input       [7:0] ioctl_dout,

	input             loaded,
	input             motor,
	input             rewind,
	input      [19:0] position,
	input      [10:0] ps2_key,

	output            show,
	output    [175:0] text          // 22 characters, first in bits 175-168; 01h = Return
);

wire tape_dl = ioctl_download & (ioctl_index[5:0] == 6'd1);
wire is_t88  = ioctl_index[7:6] == 2'd1;

//----------------------------------------------------------------------------
// .t88 tags -> data bytes
//----------------------------------------------------------------------------

reg  [2:0] tk = 0;              // tag header byte
reg [15:0] tid = 0, tln = 0;
reg [15:0] tleft = 0;           // body bytes left
reg        tbody = 0, tdata = 0;
reg        old_dl = 0;

wire       wr = tape_dl & ioctl_wr & (ioctl_addr[24:20] == 0);
wire       dbyte = wr & (is_t88 ? (tbody & tdata & (tln - tleft >= 16'd12)) : 1'b1);

always @(posedge clk) begin
	old_dl <= tape_dl;
	if (tape_dl & ~old_dl) begin tk <= 0; tbody <= 0; end
	else if (wr & is_t88 & (ioctl_addr >= 25'd24)) begin
		if (!tbody) begin
			case (tk)
			3'd0: tid[7:0]  <= ioctl_dout;
			3'd1: tid[15:8] <= ioctl_dout;
			3'd2: tln[7:0]  <= ioctl_dout;
			default: ;
			endcase
			tk <= tk + 1'd1;
			if (tk == 3'd3) begin
				tk <= 0;
				if ({ioctl_dout, tln[7:0]} != 0) begin
					tln[15:8] <= ioctl_dout;
					tleft <= {ioctl_dout, tln[7:0]};
					tbody <= 1;
					tdata <= tid == 16'h0101;
				end
			end
		end
		else begin
			tleft <= tleft - 1'd1;
			if (tleft == 16'd1) tbody <= 0;
		end
	end
end

//----------------------------------------------------------------------------
// Files
//----------------------------------------------------------------------------

localparam K_NONE = 2'd0, K_BASIC = 2'd1, K_MON = 2'd2;
localparam S_FIND = 3'd0, S_NAME = 3'd1, S_PROG = 3'd2, S_MHDR = 3'd3, S_REC = 3'd4, S_DONE = 3'd5;

reg  [2:0] s = S_DONE;
reg        second = 0;          // looking for the second file
reg  [1:0] k1 = K_NONE;
reg [19:0] f1_start = 0, f1_end = 0, f2_start = 0;
reg        f1_ok = 0;           // the first file decoded to its end
reg        f2_mc = 0;           // the second file is a machine-code block
reg  [7:0] name [0:5];
reg  [3:0] d3 = 0;              // D3h run (saturates at 10)
reg [19:0] d3_at = 0;
reg  [2:0] n = 0;
reg  [1:0] zeros = 0;
reg  [7:0] mh [0:3];            // machine-code header candidate
reg  [2:0] mk = 0;
reg [19:0] m_at = 0;
reg  [1:0] rp = 0;              // record part: 0 colon, 1 length, 2 data, 3 checksum
reg  [7:0] rlen = 0, rcnt = 0;
reg        rlast = 0;
reg [15:0] m_addr = 0;          // first file's load address (monitor)
reg [15:0] msum = 0;            // sum of the first monitor file's bytes after its header

// the data bytes, a clock late: the reset at the download's start comes first even if its first byte is
// written on the same clock
reg        pv = 0;
reg        fin = 0;             // the download has ended: close the file list once the last byte is in
reg  [7:0] pd = 0;
reg [19:0] at = 0;
always @(posedge clk) begin pv <= dbyte; pd <= ioctl_dout; at <= ioctl_addr[19:0]; end
wire       printable = (pd >= 8'h20 && pd < 8'h7F) || pd == 8'h00;

task found_mon;
	// the 3Ah that confirmed the header is the first record's colon
	if (!second) begin k1 <= K_MON; f1_start <= m_at; m_addr <= {mh[1], mh[2]}; msum <= 0; rp <= 1; s <= S_REC; end
	else begin f2_start <= m_at; f2_mc <= 1; s <= S_DONE; end
endtask

always @(posedge clk) begin
	if (~tape_dl & old_dl) fin <= 1;
	if (tape_dl & ~old_dl) begin
		s <= S_FIND; second <= 0; k1 <= K_NONE; f1_ok <= 0; f2_mc <= 0; d3 <= 0; mk <= 0; fin <= 0;
	end
	else if (fin & ~pv) begin
		fin <= 0;
		if (s != S_DONE) begin
			if (second) f2_start <= at + 1'd1;   // no second file: the end of the tape (the last byte's address)
			s <= S_DONE;
		end
	end
	else if (pv) begin
		// D3h runs and machine-code headers are watched while looking for a file
		if (s == S_FIND) begin
			if (pd == 8'hD3) begin
				if (d3 == 0) d3_at <= at;
				if (d3 != 4'd10) d3 <= d3 + 1'd1;
			end
			else d3 <= 0;
			if (d3 == 4'd10 && pd != 8'hD3) begin
				// the name's first byte
				if (!second) begin
					if (printable) begin k1 <= K_BASIC; f1_start <= d3_at; name[0] <= pd; n <= 1; s <= S_NAME; end
					else s <= S_DONE;   // not a CSAVE header: no hint for this tape
				end
				else begin f2_start <= d3_at; s <= S_DONE; end
				mk <= 0;
			end
			else begin
				// 3Ah hi lo sum 3Ah
				case (mk)
				3'd0: if (pd == 8'h3A) begin mk <= 1; m_at <= at; end
				3'd1, 3'd2, 3'd3: begin mh[mk] <= pd; mk <= mk + 1'd1; end
				default: begin
					mk <= 0;
					if (pd == 8'h3A && (mh[1] + mh[2] + mh[3]) == 8'd0) found_mon;
					else if (pd == 8'h3A) begin mk <= 1; m_at <= at; end
				end
				endcase
			end
		end
		else case (s)
		S_NAME: begin
			if (printable) begin
				name[n] <= pd;
				n <= n + 1'd1;
				if (n == 3'd5) begin s <= S_PROG; zeros <= 0; end
			end
			else begin k1 <= K_NONE; s <= S_DONE; end
		end
		S_PROG: begin
			if (pd == 8'h00) begin
				zeros <= zeros + 1'd1;
				if (zeros == 2'd2) begin f1_end <= at; f1_ok <= 1; second <= 1; d3 <= 0; mk <= 0; s <= S_FIND; end
			end
			else zeros <= 0;
		end
		S_REC: begin
			msum <= msum + {8'h00, pd};
			case (rp)
			2'd0: if (pd == 8'h3A) rp <= 1; else s <= S_DONE;
			2'd1: begin rlen <= pd; rcnt <= 0; rlast <= pd == 0; rp <= pd == 0 ? 2'd3 : 2'd2; end
			2'd2: begin rcnt <= rcnt + 1'd1; if (rcnt + 1'd1 == rlen) rp <= 3; end
			2'd3: begin
				rp <= 0;
				if (rlast) begin f1_end <= at; f1_ok <= 1; second <= 1; d3 <= 0; mk <= 0; s <= S_FIND; end
			end
			endcase
		end
		default: ;
		endcase
	end
end

//----------------------------------------------------------------------------
// When
//----------------------------------------------------------------------------

reg        fresh = 0;           // mounted or rewound, the motor not started since
reg        done = 0;            // Return pressed after the second step
reg        old_tog = 0, old_loaded = 0;
wire       ret = (ps2_key[10] != old_tog) & ps2_key[9] & (ps2_key[7:0] == 8'h5A);   // Return or keypad Enter

// known monitor tapes: start address
wire [19:0] f1_len = f1_end - f1_start;
reg        known;
reg [15:0] g_addr;
always @* begin
	known = 1;
	case ({m_addr, f1_len, msum})
	{16'h9000, 20'd7177, 16'hEE58}: g_addr = 16'h9000;   // Galaxy Fly (2017)(Ishizu)
	{16'h9000, 20'd7141, 16'h1358}: g_addr = 16'h9000;   // Space Fighter (2017)(Ishizu)
	{16'h9000, 20'd3394, 16'h902C}: g_addr = 16'h9000;   // Submarine (2017)(Ishizu)
	{16'h9000, 20'd4426, 16'h4E14}: g_addr = 16'h9000;   // Othello (2017)(Ishizu)
	{16'h9000, 20'd3330, 16'h6FF2}: g_addr = 16'h9000;   // Dot Eater (2017)(Ishizu)
	default: begin known = 0; g_addr = 0; end
	endcase
end

wire       at_start = fresh || position <= f1_start;
wire       after1 = !fresh && f1_ok && position > f1_end && position <= f2_start + 20'd64;
wire       step1 = at_start && k1 != K_NONE;
wire       step2 = after1 && !done && ((k1 == K_BASIC && !f2_mc) || (k1 == K_MON && known));

always @(posedge clk) begin
	old_tog <= ps2_key[10];
	old_loaded <= loaded;
	if ((loaded & ~old_loaded) | rewind | tape_dl) begin fresh <= 1; done <= 0; end
	else if (motor) fresh <= 0;
	if (ret & step2 & ~motor) done <= 1;
end

assign show = loaded && !motor && (step1 || step2);

//----------------------------------------------------------------------------
// What
//----------------------------------------------------------------------------

function automatic [7:0] hx(input [3:0] v);
	return v < 4'd10 ? 8'h30 + {4'h0, v} : 8'h37 + {4'h0, v};
endfunction

function automatic [7:0] nm(input [7:0] c);
	return c == 8'h00 ? 8'h20 : c;
endfunction

// name length without trailing spaces / 00h
reg [2:0] nlen;
always @* begin
	nlen = 0;
	for (int i = 0; i < 6; i++) if (name[i] != 8'h20 && name[i] != 8'h00) nlen = 3'(i + 1);
end

reg [7:0] t [0:21];
always @* begin
	for (int i = 0; i < 22; i++) t[i] = 8'h20;
	{t[0], t[1], t[2], t[3]} = "TYPE";
	if (step1 && k1 == K_BASIC) begin
		{t[5], t[6], t[7], t[8], t[9], t[10]} = "CLOAD\"";
		for (int i = 0; i < 6; i++) if (i < nlen) t[11 + i] = nm(name[i]);
		t[11 + nlen] = 8'h22;
		t[13 + nlen] = 8'h01;
	end
	else if (step1) begin
		{t[5], t[6], t[7]} = "MON";  t[9] = 8'h01;  t[11] = "L";  t[13] = 8'h01;
	end
	else if (k1 == K_MON) begin
		t[5] = "G";  t[6] = hx(g_addr[15:12]);  t[7] = hx(g_addr[11:8]);  t[8] = hx(g_addr[7:4]);  t[9] = hx(g_addr[3:0]);
		t[11] = 8'h01;
	end
	else begin
		{t[5], t[6], t[7]} = "RUN";  t[9] = 8'h01;
	end
end

genvar g;
generate for (g = 0; g < 22; g++) begin : pk
	assign text[175 - 8 * g -: 8] = t[g];
end endgenerate

endmodule
