`timescale 1ns/1ns
//
// Simulation top: the machine (rtl/pc8001.sv) with its ports made visible to the C++ harness
// (sim_headless.cpp), which plays hps_io (ps2_key and the ioctl ROM download). Stands in for PC8001.sv.
//
module top
(
   input         clk_sys /*verilator public_flat*/,
   input         reset /*verilator public_flat*/,
   input         ram16k,
   input         pcg_on,
   input  [64:0] rtc,
   input         kbd_us,

   output [7:0]  VGA_R /*verilator public_flat*/,
   output [7:0]  VGA_G /*verilator public_flat*/,
   output [7:0]  VGA_B /*verilator public_flat*/,
   output        VGA_HS /*verilator public_flat*/,
   output        VGA_VS /*verilator public_flat*/,
   output        VGA_HB /*verilator public_flat*/,
   output        VGA_VB /*verilator public_flat*/,
   output        ce_pix /*verilator public_flat*/,

   output [15:0] AUDIO_L /*verilator public_flat*/,
   output [15:0] AUDIO_R /*verilator public_flat*/,

   input  [10:0] ps2_key,
   input         tape_turbo,
   input         tape_rewind,
   output        tape_motor /*verilator public_flat*/,
   output        tape_loaded /*verilator public_flat*/,
   output        tape_turbo_on /*verilator public_flat*/,
   output [16:0] tape_position /*verilator public_flat*/,
   output [16:0] tape_length /*verilator public_flat*/,

   input         ioctl_download,
   input   [7:0] ioctl_index,
   input         ioctl_wr,
   input  [24:0] ioctl_addr,
   input   [7:0] ioctl_dout,
   output        ioctl_wait,

   // the disk images, as hps_io's S0 and S1 (sim_headless.cpp serves the blocks)
   input   [1:0] img_mounted,
   input         img_readonly,
   input  [63:0] img_size,
   output [63:0] sd_lba,
   output  [1:0] sd_rd,
   output  [1:0] sd_wr,
   input   [1:0] sd_ack,
   input   [8:0] sd_buff_addr,
   input   [7:0] sd_buff_dout,
   output  [7:0] sd_buff_din,
   input         sd_buff_wr,
   output        disk_motor /*verilator public_flat*/,
   output  [1:0] disk_ready /*verilator public_flat*/,

   output [15:0] cpu_addr /*verilator public_flat*/,
   output        cpu_ce /*verilator public_flat*/,
   output        cpu_m1_n /*verilator public_flat*/,
   output        dbg_io_wr /*verilator public_flat*/,
   output        dbg_io_rd /*verilator public_flat*/,
   output [7:0]  dbg_io_port /*verilator public_flat*/,
   output [7:0]  dbg_io_data /*verilator public_flat*/,
   output        prn_wr,
   output [7:0]  prn_data
);

assign ioctl_wait = 1'b0;

wire [15:0] audio;
assign AUDIO_L = audio;
assign AUDIO_R = audio;

pc8001 pc8001
(
   .clk_sys(clk_sys),
   .reset(reset),
   .ram16k(ram16k), .pcg_on(pcg_on), .rtc(rtc), .kbd_us(kbd_us),
   .ps2_key(ps2_key),
   .tape_turbo(tape_turbo),
   .tape_rewind(tape_rewind),
   .tape_motor(tape_motor),
   .tape_loaded(tape_loaded),
   .tape_too_big(),
   .tape_turbo_on(tape_turbo_on),
   .tape_position(tape_position),
   .tape_length(tape_length),
   .ioctl_download(ioctl_download),
   .ioctl_index(ioctl_index),
   .ioctl_wr(ioctl_wr),
   .ioctl_addr(ioctl_addr),
   .ioctl_dout(ioctl_dout),
   .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
   .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
   .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
   .ddr_busy(ddr_busy), .ddr_burstcnt(), .ddr_addr(ddr_addr), .ddr_dout(ddr_dout),
   .ddr_dout_ready(ddr_dout_ready), .ddr_rd(ddr_rd), .ddr_din(ddr_din), .ddr_be(ddr_be), .ddr_we(ddr_we),
   .disk_unit(), .disk_ready(disk_ready), .disk_too_big(), .disk_motor(disk_motor),
   .ce_pix(ce_pix),
   .R(VGA_R), .G(VGA_G), .B(VGA_B),
   .HSync(VGA_HS), .VSync(VGA_VS),
   .HBlank(VGA_HB), .VBlank(VGA_VB),
   .audio(audio),
   .cpu_addr(cpu_addr), .cpu_ce(cpu_ce), .cpu_m1_n(cpu_m1_n),
   .dbg_io_wr(dbg_io_wr), .dbg_io_rd(dbg_io_rd), .dbg_io_port(dbg_io_port), .dbg_io_data(dbg_io_data),
   .prn_wr(prn_wr), .prn_data(prn_data)
);

// DDR3 (sys/ddr_svc's side of emu): 1 MB at the disk images' base (512 KB each), one access at a time, busy now and then and
// reads coming back some clocks later, as the real one (from the PC-6001 core's sim)
wire        ddr_rd, ddr_we;
wire [28:0] ddr_addr;
wire [63:0] ddr_din;
wire  [7:0] ddr_be;
reg  [63:0] ddr_dout;
reg         ddr_dout_ready = 0;
reg  [63:0] ddr_mem[0:131071];   // 1 MB
reg   [3:0] ddr_lat = 0;
reg  [16:0] ddr_ra;
reg   [7:0] ddr_lfsr = 8'h5a;
wire        ddr_busy = ddr_lfsr[0] & ddr_lfsr[3] | ddr_lat != 0;
always @(posedge clk_sys) begin
   ddr_lfsr <= {ddr_lfsr[6:0], ddr_lfsr[7] ^ ddr_lfsr[5] ^ ddr_lfsr[4] ^ ddr_lfsr[3]};
   ddr_dout_ready <= 0;
   if (ddr_lat != 0) begin
      ddr_lat <= ddr_lat - 1'd1;
      if (ddr_lat == 1) begin ddr_dout <= ddr_mem[ddr_ra]; ddr_dout_ready <= 1; end
   end
   else if (!ddr_busy) begin
      if (ddr_rd) begin ddr_ra <= ddr_addr[16:0]; ddr_lat <= 4'd10; end
      if (ddr_we) begin : wr
         integer i;
         for (i = 0; i < 8; i = i + 1) if (ddr_be[i]) ddr_mem[ddr_addr[16:0]][i*8 +: 8] <= ddr_din[i*8 +: 8];
      end
   end
end

endmodule
