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

   input         ioctl_download,
   input   [7:0] ioctl_index,
   input         ioctl_wr,
   input  [24:0] ioctl_addr,
   input   [7:0] ioctl_dout,
   output        ioctl_wait,

   output [15:0] cpu_addr /*verilator public_flat*/,
   output        cpu_ce /*verilator public_flat*/,
   output        cpu_m1_n /*verilator public_flat*/,
   output        dbg_io_wr /*verilator public_flat*/,
   output        dbg_io_rd /*verilator public_flat*/,
   output [7:0]  dbg_io_port /*verilator public_flat*/,
   output [7:0]  dbg_io_data /*verilator public_flat*/
);

assign ioctl_wait = 1'b0;

wire [15:0] audio;
assign AUDIO_L = audio;
assign AUDIO_R = audio;

pc8001 pc8001
(
   .clk_sys(clk_sys),
   .reset(reset),
   .ram16k(ram16k),
   .ps2_key(ps2_key),
   .ioctl_download(ioctl_download),
   .ioctl_index(ioctl_index),
   .ioctl_wr(ioctl_wr),
   .ioctl_addr(ioctl_addr),
   .ioctl_dout(ioctl_dout),
   .ce_pix(ce_pix),
   .R(VGA_R), .G(VGA_G), .B(VGA_B),
   .HSync(VGA_HS), .VSync(VGA_VS),
   .HBlank(VGA_HB), .VBlank(VGA_VB),
   .audio(audio),
   .cpu_addr(cpu_addr), .cpu_ce(cpu_ce), .cpu_m1_n(cpu_m1_n),
   .dbg_io_wr(dbg_io_wr), .dbg_io_rd(dbg_io_rd), .dbg_io_port(dbg_io_port), .dbg_io_data(dbg_io_data)
);

endmodule
