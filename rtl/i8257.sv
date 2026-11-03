// uPD8257 (8257) DMA controller, as the PC-8001 uses it: channel 2 feeds the uPD3301 CRTC from the text VRAM.
//
// All four channels' registers are there (the CPU can write and read them back); only channel 2 transfers.
// Ports (60h-68h): 60h+2n address, 61h+2n terminal count (n = channel; low byte then high byte, one shared
// first/last flip-flop), 68h mode (write) / status (read).
//   mode:   7 autoload (ch2 reloads from ch3 at TC; writes to ch2 also go to ch3), 6 TC stop, 5 extended
//           write, 4 rotating priority, 3-0 channel enables
//   status: 4 update flag (autoload reload done), 3-0 TC reached per channel (cleared by the read)
// Count: bits 13-0 are the byte count - 1, bits 15-14 the transfer type (read/write/verify).
// Sources: datasheets/uPD8257_from_1980_catalog.txt; CSCP pc88_dmac_t (pc88.cpp); MAME i8257.cpp.

module i8257
(
	input             clk,
	input             reset,

	input             io_sel,      // 60h-6Fh
	input       [3:0] io_a,
	input             io_wr,       // one clock per access
	input             io_rd,       // one clock per access
	input       [7:0] din,
	output reg  [7:0] dout,

	// channel 2: the CRTC's requests
	output     [15:0] ch2_addr,
	output            ch2_ready,   // enabled and not stopped at TC
	input             ch2_adv      // one byte transferred
);

reg [15:0] addr[0:3];
reg [15:0] count[0:3];
reg  [7:0] mode;
reg  [4:0] status;
reg        ff;                     // first/last: 0 low byte, 1 high byte

assign ch2_addr  = addr[2];
assign ch2_ready = mode[2];

wire [1:0] ch = io_a[2:1];

always @(*) begin
	if (io_a[3]) dout = {3'b000, status};
	else if (~io_a[0]) dout = ff ? addr[ch][15:8] : addr[ch][7:0];
	else dout = ff ? count[ch][15:8] : count[ch][7:0];
end

always @(posedge clk) begin
	if (reset) begin
		mode   <= 8'h00;
		status <= 5'h00;
		ff     <= 1'b0;
	end
	else begin
		if (io_sel & io_wr) begin
			if (io_a[3]) begin
				mode <= din;
				ff <= 1'b0;
				if (~din[7]) status[4] <= 1'b0;
			end
			else begin
				if (~io_a[0]) begin
					if (ff) addr[ch][15:8] <= din; else addr[ch][7:0] <= din;
					if (mode[7] & ch == 2'd2) begin
						if (ff) addr[3][15:8] <= din; else addr[3][7:0] <= din;
					end
				end
				else begin
					if (ff) count[ch][15:8] <= din; else count[ch][7:0] <= din;
					if (mode[7] & ch == 2'd2) begin
						if (ff) count[3][15:8] <= din; else count[3][7:0] <= din;
					end
				end
				ff <= ~ff;
			end
		end
		else if (io_sel & io_rd) begin
			if (io_a[3]) status[3:0] <= 4'h0;
			else ff <= ~ff;
		end

		if (ch2_adv & mode[2]) begin
			status[4] <= 1'b0;
			if (count[2][13:0] == 14'd0) begin
				status[2] <= 1'b1;
				if (mode[7]) begin
					addr[2] <= addr[3];
					count[2] <= count[3];
					status[4] <= 1'b1;
				end
				else begin
					count[2][13:0] <= 14'h3FFF;
					addr[2] <= addr[2] + 1'd1;
					if (mode[6]) mode[2] <= 1'b0;
				end
			end
			else begin
				addr[2] <= addr[2] + 1'd1;
				count[2][13:0] <= count[2][13:0] - 1'd1;
			end
		end
	end
end

endmodule
