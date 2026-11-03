// uPD8251 (8251) USART at 20h (data) / 21h (mode, command / status), asynchronous mode, as the PC-8001's
// cassette and RS-232C port. The receiver takes whole bytes from the tape player (rtl/pc8001_cmt.sv) instead
// of a serial line; the transmitter takes bytes and reports them sent at once (tx_byte / tx_stb) for a
// recorder. Sync mode is not modelled.
//   mode (first write to 21h after reset): 7-6 stop bits (01 1, 10 1.5, 11 2), 5 even parity, 4 parity on,
//     3-2 character length (5 + n bits), 1-0 baud factor (00 = sync)
//   command: 6 internal reset (back to mode), 5 RTS, 4 error reset, 3 send break, 2 RxE, 1 DTR, 0 TxEN
//   status: 7 DSR, 6 SYNDET, 5 FE, 4 OE, 3 PE, 2 TxEMPTY, 1 RxRDY, 0 TxRDY
// Sources: datasheets/uPD8251_from_1980_catalog.txt; MAME i8251.cpp.

module i8251
(
	input             clk,
	input             reset,

	input             io_sel,      // 20h-21h
	input             io_a0,
	input             io_wr,       // one clock per access
	input             io_rd,
	input       [7:0] din,
	output      [7:0] dout,

	input             rx_stb,      // a received byte
	input       [7:0] rx_byte,
	input             dsr,

	output reg  [7:0] mode = 8'h00,
	output reg  [7:0] command = 8'h00,
	output reg        tx_stb = 0,
	output reg  [7:0] tx_byte = 0
);

reg       mode_next = 1;     // the next 21h write is the mode
reg [7:0] rx_data = 0;
reg       rx_rdy = 0, oe = 0;

assign dout = io_a0 ? {dsr, 2'b00, oe, 1'b0, 1'b1, rx_rdy, 1'b1} : rx_data;

always @(posedge clk) begin
	tx_stb <= 0;
	if (reset) begin
		mode_next <= 1;
		mode <= 0;
		command <= 0;
		rx_rdy <= 0;
		oe <= 0;
	end
	else begin
		if (rx_stb & command[2]) begin
			rx_data <= rx_byte;
			if (rx_rdy) oe <= 1;
			rx_rdy <= 1;
		end
		if (io_sel & io_rd & ~io_a0) rx_rdy <= 0;
		if (io_sel & io_wr) begin
			if (~io_a0) begin
				tx_byte <= din;
				tx_stb <= command[0];
			end
			else if (mode_next) begin
				mode <= din;
				mode_next <= 0;
			end
			else begin
				command <= din;
				if (din[4]) oe <= 0;
				if (din[6]) begin
					mode_next <= 1;
					command <= 0;
					rx_rdy <= 0;
					oe <= 0;
				end
			end
		end
	end
end

endmodule
