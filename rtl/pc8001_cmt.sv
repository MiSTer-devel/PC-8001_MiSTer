// PC-8001 cassette deck: plays a .cmt or .t88 image into the 8251 (rtl/i8251.sv) a byte at a time while the
// motor relay (port 30h bit 3) is on.
//
// The PC-8001 reads the tape through the 8251 only (FSK demodulator -> RxD), so a byte stream is what the
// machine sees: .cmt is that stream; .t88 holds it in data tags (101h, 12-byte header) between carrier tags
// (102h space, 103h mark: start and length in 1/4800 s). Bytes come at the line's rate: 600 baud (1200 with
// port 30h bits 5-4 = 01) and the 8251 mode's bits per character (start, 5-8 data, parity, 1/1.5/2 stop).
// Carrier detect (port 40h bit 2, as CSCP's usart_dcd): set while a carrier tag plays and while the deck is
// stopped, clear while data plays. A .cmt has no carrier tags: it gets a 1 s leader (carrier) at the start and
// each time the motor starts again (a CLOAD, then MON L of the next block).
// The image is loaded whole (ioctl index 1; index bits 7-6 = 1 for .t88) into DDR3, up to 512 KB (Pac Land's
// sides are 104-126 KB): each byte written with its byte enable, the download waiting meanwhile (ioctl_wait).
// The player reads through one cached 64-bit word (q is byte ptr of it; ready when the word holds ptr), fetched
// while a character's time runs, so the bytes keep their timing.
// TURBO: tick rate multiplier while the deck plays (the CPU runs as many times faster; tape standard).
// Sources: CSCP pc88.cpp play_tape / EVENT_CMT_SEND; the T88 format notes in QUASI88 and CSCP.

module pc8001_cmt #(parameter [28:0] BASE = 29'h06040000,   // DDR3 word address: past the ROM store
                    parameter [24:0] CLK_HZ = 25'd28636364)   // clk (a testbench may use less)
(
	input             clk,            // 28.636 MHz
	input             reset,          // the image stays; the deck is not rewound
	input             rewind,

	input             ioctl_download,
	input       [7:0] ioctl_index,
	input             ioctl_wr,
	input      [24:0] ioctl_addr,
	input       [7:0] ioctl_dout,
	output            ioctl_wait,

	input             motor,
	input             baud1200,
	input       [7:0] usart_mode,
	input       [3:0] turbo,          // 1 = normal

	output reg        rx_stb = 0,
	output reg  [7:0] rx_byte = 0,
	output reg        dcd = 1,

	output reg        loaded = 0,
	output reg        too_big = 0,
	output     [19:0] position,
	output reg [19:0] length = 0,

	input             ddr_busy,
	output reg [28:0] ddr_addr,
	input      [63:0] ddr_dout,
	input             ddr_dout_ready,
	output reg        ddr_rd = 0,
	output reg [63:0] ddr_din,
	output reg  [7:0] ddr_be,
	output reg        ddr_we = 0
);

//----------------------------------------------------------------------------
// Image
//----------------------------------------------------------------------------

reg [19:0] ptr = 0;
wire       tape_dl = ioctl_download & (ioctl_index[5:0] == 6'd1);
reg        is_t88 = 0;
reg        old_dl = 0;

reg        wr_pend = 0;          // a download byte not yet taken by DDR3 (the download waits)
reg        wq = 0;               // ... still to be issued (a read is out)
reg [15:0] wa;
reg  [7:0] wd;
reg  [2:0] wl;
assign ioctl_wait = wr_pend;

reg [63:0] cw;                    // the cached word, word address cw_a
reg [15:0] cw_a;
reg        cw_ok = 0, rd_out = 0, rd_stale = 0;   // stale: a download began while the read was out
reg [15:0] rd_a;
wire       ready = cw_ok & (cw_a == ptr[18:3]);
wire [7:0] q = cw[{ptr[2:0], 3'b000} +: 8];

always @(posedge clk) begin
	if (!ddr_busy) begin ddr_rd <= 0; ddr_we <= 0; end

	// a read's word: kept unless a download overlapped it
	if (rd_out & ddr_dout_ready) begin
		rd_out <= 0;
		rd_stale <= 0;
		if (~rd_stale & ~tape_dl) begin cw <= ddr_dout; cw_a <= rd_a; cw_ok <= 1'b1; end
	end

	if (tape_dl) begin
		cw_ok <= 0;
		if (rd_out) rd_stale <= 1'b1;
	end

	if (tape_dl & ioctl_wr & ~ioctl_addr[24:19]) begin
		wa <= ioctl_addr[18:3]; wd <= ioctl_dout; wl <= ioctl_addr[2:0];
		wq <= 1'b1;
		wr_pend <= 1'b1;
	end
	else if (wq) begin
		if (!rd_out && !ddr_rd) begin
			ddr_addr <= BASE + {13'd0, wa};
			ddr_din <= {8{wd}};
			ddr_be <= 8'h01 << wl;
			ddr_we <= 1'b1;
			wq <= 0;
		end
	end
	else if (wr_pend) begin
		if (!ddr_we || !ddr_busy) wr_pend <= 0;
	end
	else if (!tape_dl && !rd_out && !ready && !ddr_rd) begin
		ddr_addr <= BASE + {13'd0, ptr[18:3]};
		rd_a <= ptr[18:3];
		ddr_rd <= 1'b1;
		rd_out <= 1'b1;
	end
end

//----------------------------------------------------------------------------
// 4800 Hz x turbo ticks; a bit is 8 (600 baud) or 4 (1200) ticks
//----------------------------------------------------------------------------

reg [24:0] tacc = 0;
reg        tick = 0;
wire [24:0] tstep = 25'd4800 * turbo;
always @(posedge clk) begin
	if (tacc + tstep >= CLK_HZ) begin
		tacc <= tacc + tstep - CLK_HZ;
		tick <= 1;
	end
	else begin
		tacc <= tacc + tstep;
		tick <= 0;
	end
end

// ticks per character: 8 or 4 per bit; start + data + parity + stop (1.5 stop = 1.5 bits)
wire [3:0] dbits = 4'd5 + usart_mode[3:2];
wire [4:0] half_bits = {1'b0, (4'd1 + dbits + usart_mode[4]), 1'b0} +
                       ((usart_mode[7:6] == 2'b10) ? 5'd3 : (usart_mode[7:6] == 2'b11) ? 5'd4 : 5'd2);
wire [4:0] hb = (usart_mode[1:0] == 2'b00) ? 5'd22 : half_bits;     // no mode yet: 8N2
wire [7:0] char_ticks = baud1200 ? {1'b0, hb, 1'b0} : {hb, 2'b00};  // half bit = 2 or 4 ticks

//----------------------------------------------------------------------------
// Player
//----------------------------------------------------------------------------

localparam P_START = 4'd0, P_TAG = 4'd1, P_TAG2 = 4'd2, P_DECIDE = 4'd3, P_CLEN = 4'd4, P_CARRIER = 4'd5,
           P_DATA = 4'd6, P_EMIT = 4'd7, P_END = 4'd8, P_SKIP = 4'd9;

reg  [3:0] st = P_END;
reg  [2:0] k = 0;               // byte of the tag header being read
reg [15:0] tag = 0, tlen = 0;
reg [31:0] cwait = 0;           // carrier ticks
reg [15:0] left = 0;            // data bytes left in the tag
reg  [7:0] tcnt = 0;
reg        rd_wait = 0;
reg        old_motor = 0;

assign position = ptr;

always @(posedge clk) begin
	rx_stb <= 0;
	old_dl <= tape_dl;
	old_motor <= motor;

	if (tape_dl) begin
		loaded <= 0;
		st <= P_END;
	end
	else if (old_dl) begin
		// download finished
		length <= (ioctl_addr[24:19] != 0) ? 20'h80000 : {1'b0, ioctl_addr[18:0]} + 1'd1;
		too_big <= ioctl_addr[24:19] != 0;
		is_t88 <= ioctl_index[7:6] == 2'd1;
		loaded <= 1;
		st <= P_START;
	end
	else if (rewind) st <= P_START;
	else if (motor & ~old_motor & loaded & ~is_t88 & (st == P_DATA)) begin
		// .cmt, the motor starting again between blocks: a leader before the next block
		st <= P_CARRIER;
		cwait <= 32'd4800;
	end
	else if (motor & loaded) begin
		case (st)
		P_START: begin
			ptr <= is_t88 ? 20'd24 : 20'd0;
			tcnt <= 0;
			// .cmt has no carrier: play a 1 s leader first (the ROM waits for carrier detect, 0C02h)
			st <= is_t88 ? P_TAG : P_CARRIER;
			cwait <= 32'd4800;
			left <= 16'hFFFF;
			k <= 0;
			rd_wait <= 0;
		end

		// T88 tag header: tag (2), length (2)
		P_TAG: begin
			if (ptr >= length) st <= P_END;
			else begin
				rd_wait <= 1;
				if (rd_wait & ready) begin
					rd_wait <= 0;
					case (k)
					3'd0: tag[7:0] <= q;
					3'd1: tag[15:8] <= q;
					3'd2: tlen[7:0] <= q;
					3'd3: tlen[15:8] <= q;
					default: ;
					endcase
					ptr <= ptr + 1'd1;
					k <= k + 1'd1;
					if (k == 3'd3) st <= P_DECIDE;
				end
			end
		end
		P_DECIDE: begin
			k <= 0;
			if (tag == 16'h0000 && tlen == 16'h0000) st <= P_END;
			else if (tag == 16'h0101 && tlen > 16'd12) begin
				ptr <= ptr + 5'd12;
				left <= tlen - 16'd12;
				tcnt <= 0;
				st <= P_DATA;
			end
			else if ((tag == 16'h0102 || tag == 16'h0103) && tlen >= 16'd8) begin
				// carrier: its length is bytes 4-7 of the body
				ptr <= ptr + 3'd4;
				st <= P_CLEN;
				cwait <= 0;
			end
			else begin
				ptr <= ptr + tlen;
				st <= P_TAG;
			end
		end
		P_CLEN: begin
			rd_wait <= 1;
			if (rd_wait & ready) begin
				rd_wait <= 0;
				cwait <= {q, cwait[31:8]};
				ptr <= ptr + 1'd1;
				k <= k + 1'd1;
				if (k == 3'd3) begin
					k <= 0;
					ptr <= ptr + tlen - 16'd7;   // past the rest of the body
					st <= P_CARRIER;
				end
			end
		end
		P_CARRIER: begin
			dcd <= 1;
			if (cwait == 0) st <= is_t88 ? P_TAG : P_DATA;
			else if (tick) cwait <= cwait - 1'd1;
		end

		// data bytes: one character time, then the byte to the 8251
		P_DATA: begin
			if (ptr >= length) st <= P_END;
			else if (left == 0) st <= P_TAG;
			else begin
				dcd <= 0;
				if (tick) begin
					if (tcnt >= char_ticks - 1'd1) begin
						tcnt <= 0;
						st <= P_EMIT;
					end
					else tcnt <= tcnt + 1'd1;
				end
			end
		end
		P_EMIT: if (ready) begin
			rx_byte <= q;
			rx_stb <= 1;
			ptr <= ptr + 1'd1;
			if (is_t88) left <= left - 1'd1;
			st <= P_DATA;
		end

		P_END: dcd <= 1;
		default: st <= P_END;
		endcase
	end
	else dcd <= 1;
end

endmodule
