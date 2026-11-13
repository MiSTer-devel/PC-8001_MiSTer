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
assign DDRAM_CLK = clk_sys;   // the disk image (rtl/d88_media.sv)

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 0;
assign AUDIO_MIX = 0;

assign LED_DISK = {1'b0, disk_motor};
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

// OSD per ~/dev2/osd-standard.md: media (ending with Load ROM) and Memory on the top page, then the Machine, Video
// and Input pages. Machine settings take effect at the next reset (cfg); "Changes pending" shows until then.
// Tape per ~/dev2/tape-standard.md and video per ~/dev2/video-standard.md: Tape speed, Tape overlay, Aspect ratio,
// Scale, Scandoubler Fx and the Input page act at once (status, out of "Changes pending").
// Status bits: 0 reset, 1 memory, 3 rewind tape, 4 tape speed, 5 tape overlay, 6 PCG, 7 keyboard, 8-9 model,
// 10-11 mkII/SR mode (N80, N, N80SR), 12-13 scale, 14-16 scandoubler fx, 17 swap Alt/Win, 121-122 aspect ratio.
`include "build_id.v"
// Tape turbo factor: the Z80 and the deck run TURBO times as fast while the deck plays (rtl/pc8001.sv)
localparam int TURBO = 5;
localparam CONF_STR = {
	"PC8001;;",
	"-;",
	// PC-80S31 disk unit, when boot.rom has disk.rom: a .d88 image, written back as the drive changes it;
	// remembered (SC): mounted again at the next core start
	"SC0,D88,Drive 1;",
	"SC1,D88,Drive 2;",
	// The whole image is loaded into the core; not remembered (F, not FC), so a core start has no tape.
	"F1,CMTT88,Tape;",
	// a memory image from 8000h, started at once from FF3Dh as CSCP does; for the machine as it is (BASIC up)
	"F3,N80,Memory Image;",
	"F2,ROMBIN,Expansion ROM;",
	"F0,ROM,Load ROM;",
	"-;",
	// the PC-8001's RAM (the mkII and SR always have 64 KB): hidden on those, its line kept
	"H1O[1],Memory,32 KB,16 KB;",
	"h1-;",
	"-;",
	"P1,Machine;",
	"P2,Video;",
	"P3,Input;",
	"-;",
	"h0-,Changes pending;",
	"R[0],Apply and reset;",

	"P1O[9:8],Model,PC-8001,PC-8001mkII,PC-8001mkIISR;",
	"H2P1O[11:10],Mode,N80-BASIC,N-BASIC,N80SR-BASIC (SR);",
	"h2P1-;",
	"P1O[6],PCG-8100,Off,On;",
	"P1-;",
	"P1O[4],Tape speed,", 8'h30 + 8'(TURBO), "x,Normal;",
	"P1-;",
	"P1T[3],Rewind tape;",

	"P2O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P2O[13:12],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"P2O[16:14],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P2-;",
	"P2O[5],Tape overlay,On,Off;",

	"P3O[7],Keyboard,JP (positions),US (symbols);",
	"P3O[17],Swap Alt/Win keys,No,Yes;",

	"I,Tape ready (rewound),Tape too large (512 KB max),Disk too large (512 KB max),No disk unit (boot.rom without disk.rom);",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

// Input: Swap Alt/Win keys (acts at once): left Alt (11h) <-> left Win (E0 1Fh), right Alt (E0 11h) <-> right
// Win (E0 27h). Left Alt is GRPH and right Alt KANA (rtl/pc8001_kbd.sv), so with Yes the Win keys are.
reg [8:0] key_sw;
always @(*) begin
	key_sw = ps2_key[8:0];
	if (status[17]) case (ps2_key[8:0])
		9'h011: key_sw = 9'h11F;
		9'h11F: key_sw = 9'h011;
		9'h111: key_sw = 9'h127;
		9'h127: key_sw = 9'h111;
		default: ;
	endcase
end
wire [10:0] ps2_key_sw = {ps2_key[10:9], key_sw};
wire  [64:0] rtc;

wire         ioctl_download;
wire         ioctl_wait;
wire   [7:0] ioctl_index;
wire         ioctl_wr;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;

wire  [1:0] img_mounted, sd_rd, sd_wr, sd_ack;
wire        img_readonly, sd_buff_wr;
wire [63:0] img_size;
wire [63:0] sd_lba;              // {drive 2, drive 1}
wire  [8:0] sd_buff_addr;
wire  [7:0] sd_buff_dout, sd_buff_din;
wire        disk_unit, disk_motor;
wire  [1:0] disk_ready, disk_too_big;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	// 1: Memory hidden (not the PC-8001), 2: Mode hidden (the PC-8001); from the live Model row
	.status_menumask({13'd0, status[9:8] == 2'd0, status[9:8] != 2'd0, osd_pending}),
	.info_req(tape_info_req),
	.info(tape_info),

	.ps2_key(ps2_key),
	.RTC(rtc),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba('{sd_lba[31:0], sd_lba[63:32]}),
	.sd_blk_cnt('{6'd0, 6'd0}),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din('{sd_buff_din, sd_buff_din}),
	.sd_buff_wr(sd_buff_wr)
);


///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;   // 28.636 MHz
wire clk_vid;   // 57.27 MHz: CLK_VIDEO, 4 x the 14.318 MHz dot clock (video_mixer needs 4x or more)
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_vid)
);

wire reset = RESET | status[0] | buttons[1] | (ioctl_download & (ioctl_index[5:0] == 6'd0 || ioctl_index[5:0] == 6'd2));

// The settings the machine runs with, taken from the OSD at every reset
reg [127:0] cfg;
always @(posedge clk_sys) if (reset) cfg <= status;
wire osd_pending = {status[11:8], status[6], status[1]} != {cfg[11:8], cfg[6], cfg[1]};

//////////////////////////////////////////////////////////////////

wire [15:0] audio;
assign AUDIO_L = audio;
assign AUDIO_R = audio;

wire ce_pix, HBlank, VBlank, HSync, VSync;
wire [7:0] R, G, B;
wire        tape_motor, tape_loaded, tape_too_big, tape_turbo_on;
wire [19:0] tape_position, tape_length;

pc8001 #(.TURBO(TURBO)) pc8001
(
	.clk_sys(clk_sys),
	.reset(reset),
	.model(cfg[9:8]),
	.n_mode(cfg[11:10] == 2'd1),
	.v2(cfg[11:10] == 2'd2),
	.ram16k(cfg[1]),
	.pcg_on(cfg[6]),
	.rtc(rtc),
	.kbd_us(status[7]),

	.ps2_key(ps2_key_sw),

	.tape_turbo(~status[4]),
	.tape_rewind(status[3]),
	.tape_motor(tape_motor),
	.tape_loaded(tape_loaded),
	.tape_too_big(tape_too_big),
	.tape_turbo_on(tape_turbo_on),
	.tape_position(tape_position),
	.tape_length(tape_length),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr[24:0]),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

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
	.ddr_busy(DDRAM_BUSY),
	.ddr_burstcnt(DDRAM_BURSTCNT),
	.ddr_addr(DDRAM_ADDR),
	.ddr_dout(DDRAM_DOUT),
	.ddr_dout_ready(DDRAM_DOUT_READY),
	.ddr_rd(DDRAM_RD),
	.ddr_din(DDRAM_DIN),
	.ddr_be(DDRAM_BE),
	.ddr_we(DDRAM_WE),
	.disk_unit(disk_unit),
	.disk_ready(disk_ready),
	.disk_too_big(disk_too_big),
	.disk_motor(disk_motor),

	.ce_pix(ce_pix),
	.R(R), .G(G), .B(B),
	.HSync(HSync), .VSync(VSync),
	.HBlank(HBlank), .VBlank(VBlank),

	.audio(audio),

	.cpu_addr(), .cpu_ce(), .cpu_m1_n(),
	.dbg_io_wr(), .dbg_io_rd(), .dbg_io_port(), .dbg_io_data(),
	.prn_wr(), .prn_data()
);

// One OSD message per tape download: ready (rewound), or cut off at 64 KB
reg       tape_info_req = 0;
reg [7:0] tape_info = 0;
reg       old_tape_dl = 0;
reg [1:0] old_mount = 0;
always @(posedge clk_sys) begin
	old_tape_dl <= ioctl_download && ioctl_index[5:0] == 6'd1;
	tape_info_req <= 0;
	if (old_tape_dl && !(ioctl_download && ioctl_index[5:0] == 6'd1)) begin
		tape_info <= tape_too_big ? 8'd2 : 8'd1;
		tape_info_req <= 1;
	end
	// a disk mounted: too large, or no unit to put it in
	old_mount <= img_mounted;
	if ((old_mount & ~img_mounted) != 0 && img_size != 0) begin
		if (!disk_unit) begin tape_info <= 8'd4; tape_info_req <= 1; end
		else if (img_size > 64'd524288) begin tape_info <= 8'd3; tape_info_req <= 1; end
	end
end

// Next step while the deck is stopped (tape standard rules 25-28): read from the tape as it downloads
wire         hint_show;
wire [175:0] hint_text;

tape_hint tape_hint
(
	.clk(clk_sys),
	.ioctl_download(ioctl_download & (ioctl_addr[26:25] == 0)),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr[24:0]),
	.ioctl_dout(ioctl_dout),
	.loaded(tape_loaded),
	.motor(tape_motor),
	.rewind(status[3]),
	.position(tape_position),
	.ps2_key(ps2_key),
	.show(hint_show),
	.text(hint_text)
);

// Tape status bar while the deck plays (tape standard): bytes at about 55 a second (600 baud, 11 bits)
wire [218:0] tape_status_word;
wire        tape_status_req, tape_status_ack;

tape_status tape_status
(
	.clk(clk_sys),
	.loaded(tape_loaded),
	.playing(tape_motor),
	.fast(tape_turbo_on),
	.position({12'd0, tape_position}),
	.length({12'd0, tape_length}),
	.hz(18'd55),
	.hint_show(hint_show),
	.hint_text(hint_text),
	.status(tape_status_word),
	.req(tape_status_req),
	.ack(tape_status_ack)
);

tape_overlay #(.FACTOR(4'(TURBO))) tape_overlay
(
	.clk(clk_sys),
	.ce_pix(ce_pix),
	.hblank(HBlank),
	.vblank(VBlank),
	.enable(~status[5]),
	.status(tape_status_word),
	.req(tape_status_req),
	.ack(tape_status_ack),
	// the hint's font: font.rom's characters 00h-7Fh (boot.rom 6000h-63FFh) as boot.rom loads
	.font_we(ioctl_download & (ioctl_index == 8'd0) & ioctl_wr & (ioctl_addr[26:10] == 17'h18)),
	.font_a(ioctl_addr[9:0]),
	.font_d(ioctl_dout),
	.rgb_in({R, G, B}),
	.rgb_out(rgb_ov)
);

// ---------------------------------------------------------------- video out (~/dev2/video-standard.md)
// The machine makes 15 kHz NTSC-rate video: 640 dots (14.318 MHz, ce_pix on clk_sys) x 200 lines, in every model
// and mode (40-column text and the 320-dot graphics repeat dots). video_mixer: the scandoubler for 31 kHz VGA
// (Scandoubler Fx, or forced by MiSTer.ini), HQ2x / CRT scanlines, gamma; video_freak: aspect ratio and integer
// scaling. They run on clk_vid (4x the dot clock): each dot, with its sync and blanking, is latched on ce_pix and
// handed over with a toggle (clk_sys and clk_vid come from the same PLL).
wire [23:0] rgb_ov;
reg  [23:0] px_rgb;
reg   [3:0] px_sync;
reg         px_tog = 0;
always @(posedge clk_sys) if (ce_pix) begin
	px_rgb <= rgb_ov;
	px_sync <= {HSync, VSync, HBlank, VBlank};
	px_tog <= ~px_tog;
end

reg  [23:0] v_rgb;
reg   [3:0] v_sync;
reg         v_tog = 0, v_tog_d = 0;
always @(posedge clk_vid) begin
	v_rgb <= px_rgb;
	v_sync <= px_sync;
	v_tog <= px_tog;
	v_tog_d <= v_tog;
end
wire v_ce = v_tog ^ v_tog_d;   // one clk_vid pulse per dot, while v_rgb / v_sync hold it

wire [21:0] gamma_bus;
wire  [1:0] ar  = status[122:121];
wire  [2:0] sfx = status[16:14];          // 0 None, 1 HQ2x, 2-4 CRT 25/50/75%
wire  [2:0] sl  = sfx ? sfx - 3'd1 : 3'd0;
assign VGA_SL = sl[1:0];
assign CLK_VIDEO = clk_vid;

video_mixer #(.LINE_LENGTH(680), .GAMMA(1)) video_mixer
(
	.CLK_VIDEO(clk_vid),
	.CE_PIXEL(CE_PIXEL),
	.ce_pix(v_ce),
	.scandoubler(sfx != 3'd0 || forced_scandoubler),
	.hq2x(sfx == 3'd1),
	.gamma_bus(gamma_bus),
	.R(v_rgb[23:16]), .G(v_rgb[15:8]), .B(v_rgb[7:0]),
	.HSync(v_sync[3]), .VSync(v_sync[2]), .HBlank(v_sync[1]), .VBlank(v_sync[0]),
	.HDMI_FREEZE(HDMI_FREEZE),
	.freeze_sync(),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_VS(VGA_VS), .VGA_HS(VGA_HS), .VGA_DE(VGA_DE)
);

video_freak video_freak
(
	.CLK_VIDEO(clk_vid),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE_IN(VGA_DE),
	.VGA_DE(),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	// Original: the real shape of the 640 x 200 picture. 14.318 MHz dots (4 fsc) have a pixel aspect of 3/7
	// (square-pixel rate 6.136 MHz / 14.318 MHz), so 640*3 : 200*7 = 1920:1400 = 48:35 (1.37:1, not 4:3).
	.ARX((!ar) ? 12'd48 : (ar - 1'd1)),
	.ARY((!ar) ? 12'd35 : 12'd0),
	.CROP_SIZE(12'd0),                     // 200 lines: 5x = 1000 already fits 1080
	.CROP_OFF(5'd0),
	.SCALE({1'b0, status[13:12]})
);

assign LED_USER = ioctl_download;

endmodule
