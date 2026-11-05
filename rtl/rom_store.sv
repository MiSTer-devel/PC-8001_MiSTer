// Each model's ROMs, kept in DDR3 (as the PC-6001 core's rtl/rom_store.sv): Main loads boot.rom (ioctl index
// 00h: the PC-8001's) and boot1.rom (40h: the mkII's, n80_2.rom 32 KB then kanji1.rom 128 KB) at the core's
// start, but OSD Model can change at any reset. At the end of a reset, when the core's 32 KB main ROM (rom in
// rtl/pc8001.sv) holds another model's, the current model's is copied in, the machine held in reset meanwhile
// (busy; ~3 ms). boot.rom also goes straight into the core as it loads (rtl/pc8001.sv), so the PC-8001 needs
// no copy at power-on.
//
// The kanji ROM stays in DDR3: kanji_rd fetches the two bytes of character line kanji_a (E8h/E9h), kanji_busy
// until kanji_q has them.
//
// DDR3 (64-bit words): set n at BASE + n x 8000h words (256 KB), the byte at ioctl address a in word a / 8,
// lane a % 8.

module rom_store #(parameter [28:0] BASE = 29'h06020000)   // past the two disk images (rtl/pc80s31.sv)
(
	input             clk,
	input             reset,          // the machine's reset: a copy may follow its end
	input       [1:0] model,          // 0 the PC-8001 (set 0), 1 the mkII (set 1)

	input             ioctl_download,
	input       [7:0] ioctl_index,
	input             ioctl_wr,
	input      [24:0] ioctl_addr,
	input       [7:0] ioctl_dout,
	output            ioctl_wait,

	output            busy,
	output reg [14:0] rom_a,
	output reg  [7:0] rom_d,
	output reg        rom_we = 0,

	input             kanji_rd,       // one clock
	input      [15:0] kanji_a,
	output reg [15:0] kanji_q = 16'hFFFF,   // {E9h byte (even), E8h byte (odd)}
	output            kanji_busy,

	input             ddr_busy,
	output      [7:0] ddr_burstcnt,
	output reg [28:0] ddr_addr,
	input      [63:0] ddr_dout,
	input             ddr_dout_ready,
	output reg        ddr_rd = 0,
	output reg [63:0] ddr_din,
	output reg  [7:0] ddr_be,
	output reg        ddr_we = 0
);

assign ddr_burstcnt = 8'd1;

wire       dl_ours = ioctl_index[5:0] == 0 && ioctl_index[7:6] <= 2'd1;
wire [1:0] dl_set  = ioctl_index[7:6];

// downloads: each byte goes to DDR3 with its byte enable; the download waits while one is going out
reg        wr_pend = 0;
assign ioctl_wait = wr_pend;

reg        reset_d = 0, dl_d = 0, copy_req = 0;
reg  [1:0] loaded = 2'd0;                 // the set in the core's ROM (boot.rom goes there as it loads)
reg        copying = 0, rd_wait = 0;
reg [11:0] word;
reg  [2:0] lane;
reg [63:0] data;
reg        have = 0;                      // data holds a word still being copied out
reg        k_pend = 0, k_wait = 0;
reg [15:0] k_a;

assign busy = copying | copy_req;
assign kanji_busy = k_pend | k_wait;

always @(posedge clk) begin
	reset_d <= reset;
	dl_d <= ioctl_download && dl_ours;
	rom_we <= 0;
	if (!ddr_busy) begin ddr_rd <= 0; ddr_we <= 0; end

	if (ioctl_download && dl_ours && dl_set == 2'd0) loaded <= 2'd0;

	// a copy after a reset (or the end of a download) that leaves another model's ROM in the core
	if (((reset_d && !reset) || (dl_d && !(ioctl_download && dl_ours))) && model != loaded) copy_req <= 1'b1;

	if (kanji_rd) begin k_pend <= 1'b1; k_a <= kanji_a; end

	if (ioctl_download && ioctl_wr && dl_ours && ioctl_addr[24:18] == 0) begin
		ddr_addr <= BASE + {12'd0, dl_set, 15'd0} + {14'd0, ioctl_addr[17:3]};
		ddr_din <= {8{ioctl_dout}};
		ddr_be <= 8'h01 << ioctl_addr[2:0];
		ddr_we <= 1'b1;
		wr_pend <= 1'b1;
	end
	else if (wr_pend && (!ddr_we || !ddr_busy)) wr_pend <= 0;

	if (copy_req && !copying && !ioctl_download && !wr_pend && !k_wait) begin
		copy_req <= 0; copying <= 1'b1; word <= 0; have <= 0; rd_wait <= 0;
	end
	else if (copying) begin
		if (!have && !rd_wait && !ddr_rd) begin
			ddr_addr <= BASE + {12'd0, model, 15'd0} + {17'd0, word};
			ddr_rd <= 1'b1;
			rd_wait <= 1'b1;
		end
		else if (rd_wait && ddr_dout_ready) begin
			data <= ddr_dout; have <= 1'b1; lane <= 0; rd_wait <= 0;
		end
		else if (have) begin
			rom_a <= {word, lane};
			rom_d <= data[{lane, 3'b000} +: 8];
			rom_we <= 1'b1;
			lane <= lane + 1'd1;
			if (lane == 3'd7) begin
				have <= 0;
				word <= word + 1'd1;
				if (&word) begin copying <= 0; loaded <= model; end
			end
		end
	end
	// kanji: the mkII set's bytes 8000h + 2a, 8000h + 2a + 1 (one word, lanes 2a % 8 and +1)
	else if (k_pend && !k_wait && !ddr_rd && !wr_pend && !ddr_we) begin
		ddr_addr <= BASE + {12'd0, 2'd1, 15'd0} + 29'h1000 + {15'd0, k_a[15:2]};
		ddr_rd <= 1'b1;
		k_pend <= 0;
		k_wait <= 1'b1;
	end
	else if (k_wait && ddr_dout_ready) begin
		kanji_q <= {ddr_dout[{k_a[1:0], 4'b0000} +: 8], ddr_dout[{k_a[1:0], 4'b1000} +: 8]};
		k_wait <= 0;
	end
end

endmodule
