//============================================================================
//  NEC PC-8001 for MiSTer
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 0;
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = cfg[122:121];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

// OSD per ~/dev2/osd-standard.md: media on the top page, then Machine, Video and Input pages. Settings take effect
// at the next reset (cfg); "Changes pending" shows until then.
// Status bits: 0 reset, 1 memory, 121-122 aspect ratio.
`include "build_id.v"
localparam CONF_STR = {
	"PC8001;;",
	"-;",
	"F0,ROM,Load ROM;",
	"-;",
	"P1,Machine;",
	"P2,Video;",
	"-;",
	"h0-,Changes pending;",
	"R[0],Apply and reset;",

	"P1O[1],Memory,32 KB,16 KB;",

	"P2O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",

	"v,0;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

wire         ioctl_download;
wire   [7:0] ioctl_index;
wire         ioctl_wr;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({15'd0, osd_pending}),

	.ps2_key(ps2_key),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(1'b0)
);


///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;   // 28.636 MHz
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys)
);

wire reset = RESET | status[0] | buttons[1] | (ioctl_download & ioctl_index[5:0] == 6'd0);

// The settings the machine runs with, taken from the OSD at every reset
reg [127:0] cfg;
always @(posedge clk_sys) if (reset) cfg <= status;
wire osd_pending = {status[1], status[122:121]} != {cfg[1], cfg[122:121]};

//////////////////////////////////////////////////////////////////

wire [15:0] audio;
assign AUDIO_L = audio;
assign AUDIO_R = audio;

wire ce_pix, HBlank, VBlank, HSync, VSync;
wire [7:0] R, G, B;

pc8001 pc8001
(
	.clk_sys(clk_sys),
	.reset(reset),
	.ram16k(cfg[1]),

	.ps2_key(ps2_key),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr[24:0]),
	.ioctl_dout(ioctl_dout),

	.ce_pix(ce_pix),
	.R(R), .G(G), .B(B),
	.HSync(HSync), .VSync(VSync),
	.HBlank(HBlank), .VBlank(VBlank),

	.audio(audio),

	.cpu_addr(), .cpu_ce(), .cpu_m1_n(),
	.dbg_io_wr(), .dbg_io_rd(), .dbg_io_port(), .dbg_io_data()
);

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL = ce_pix;

assign VGA_R = R;
assign VGA_G = G;
assign VGA_B = B;
assign VGA_DE = ~(HBlank | VBlank);
assign VGA_HS = HSync;
assign VGA_VS = VSync;

assign LED_USER = ioctl_download;

endmodule
