// Testbench: rtl/pc8001_cmt.sv with its image in DDR3 (behind rtl/ddr_arb.sv, as in rtl/pc8001.sv), the motor on,
// every byte it sends to the 8251 logged by tb_cmt.cpp. CLK_HZ small: 4800 Hz ticks come every few clocks.
module tb_cmt
(
	input         clk,
	input         ioctl_download,
	input   [7:0] ioctl_index,
	input         ioctl_wr,
	input  [24:0] ioctl_addr,
	input   [7:0] ioctl_dout,
	output        ioctl_wait,
	input         motor,
	output        rx_stb,
	output  [7:0] rx_byte,
	output        loaded,
	output [19:0] position,
	output [19:0] length,
	input         other_rd     // the other arbiter client reading now and then
);

wire        c_busy, c_ready, c_rd, c_we, a_busy, a_ready;
wire [28:0] c_addr;
wire [63:0] c_din;
wire  [7:0] c_be;

pc8001_cmt #(.CLK_HZ(25'd60000)) cmt
(
	.clk(clk), .reset(1'b0), .rewind(1'b0),
	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
	.motor(motor), .baud1200(1'b0), .usart_mode(8'hCE), .turbo(4'd1),
	.rx_stb(rx_stb), .rx_byte(rx_byte), .dcd(), .loaded(loaded), .too_big(), .position(position), .length(length),
	.ddr_busy(c_busy), .ddr_addr(c_addr), .ddr_dout(ddr_dout), .ddr_dout_ready(c_ready), .ddr_rd(c_rd),
	.ddr_din(c_din), .ddr_be(c_be), .ddr_we(c_we)
);

// client a: a read of another region every so often (the disk unit / ROM store's traffic)
reg a_rd = 0;
always @(posedge clk) if (!a_busy) a_rd <= other_rd; else if (other_rd) a_rd <= 1;

wire        ddr_rd, ddr_we;
wire [28:0] ddr_addr;
wire [63:0] ddr_din;
wire  [7:0] ddr_be;
ddr_arb arb
(
	.clk(clk),
	.a_rd(a_rd), .a_we(1'b0), .a_addr(29'h06000000), .a_din(64'd0), .a_be(8'd0), .a_busy(a_busy), .a_dout_ready(a_ready),
	.b_rd(c_rd), .b_we(c_we), .b_addr(c_addr), .b_din(c_din), .b_be(c_be), .b_busy(c_busy), .b_dout_ready(c_ready),
	.ddr_busy(ddr_busy), .ddr_dout_ready(ddr_dout_ready),
	.ddr_rd(ddr_rd), .ddr_we(ddr_we), .ddr_addr(ddr_addr), .ddr_din(ddr_din), .ddr_be(ddr_be)
);

// DDR3 as verilator/sim.v's: busy now and then, reads back 10 clocks later
reg  [63:0] ddr_dout;
reg         ddr_dout_ready = 0;
reg  [63:0] ddr_mem[0:327679];
reg   [3:0] ddr_lat = 0;
reg  [18:0] ddr_ra;
reg   [7:0] ddr_lfsr = 8'h5a;
wire        ddr_busy = ddr_lfsr[0] & ddr_lfsr[3] | ddr_lat != 0;
always @(posedge clk) begin
	ddr_lfsr <= {ddr_lfsr[6:0], ddr_lfsr[7] ^ ddr_lfsr[5] ^ ddr_lfsr[4] ^ ddr_lfsr[3]};
	ddr_dout_ready <= 0;
	if (ddr_lat != 0) begin
		ddr_lat <= ddr_lat - 1'd1;
		if (ddr_lat == 1) begin ddr_dout <= ddr_mem[ddr_ra]; ddr_dout_ready <= 1; end
	end
	else if (!ddr_busy) begin
		if (ddr_rd) begin ddr_ra <= ddr_addr[18:0]; ddr_lat <= 4'd10; end
		if (ddr_we) begin : wr
			integer i;
			for (i = 0; i < 8; i = i + 1) if (ddr_be[i]) ddr_mem[ddr_addr[18:0]][i*8 +: 8] <= ddr_din[i*8 +: 8];
		end
	end
end

endmodule
