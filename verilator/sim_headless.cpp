// Headless PC-8001 simulation: run frames, type keys, capture PNG screenshots, frame hashes and traces.
//
// Cut down from the PC-6001 core's verilator/sim_headless.cpp (same option names). Examples:
//
//   ./obj_dir_headless/Vtop --rom-dir ../refs/emulators/mame_roms/pc8001 --stop-at-frame 120 --screenshot 120
//   ./obj_dir_headless/Vtop --stop-at-frame 60 --frame-log out/frames.csv --trace-io out/io.csv
//
// A frame ends when vertical blanking starts; frame 0 starts when reset is released (as CSCP's frame 0). Each PNG is the visible
// picture as the core outputs it, 640x200.

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <vector>
#include <set>
#include <map>
#include <deque>
#include <cstring>
#include <sys/stat.h>

#include "Vtop.h"
#include "Vtop___024root.h"
#include "verilated.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include "ps2_keys.h"

static const double CLK_HZ = 28636364.0;   // clk_sys, as the MiSTer

struct TypeCmd { uint32_t frame; std::string text; };

struct Options {
    uint32_t    stop_frame = 60;
    bool        quiet = false;
    std::set<uint32_t> screenshots;       // --screenshot N
    uint32_t    dump_every = 0;
    std::string out_dir = "out";
    std::string frame_log;
    std::vector<TypeCmd> types;
    uint32_t    type_press = 4, type_release = 4;
    std::string trace_file;               // --trace-cpu
    std::string io_file;                  // --trace-io
    uint32_t    trace_from = 0, trace_to = 0xFFFFFFFF;
    std::string basic_rom, font_rom;      // --rom-dir DIR: DIR/n80v110.rom, DIR/font.rom (MAME names)
    std::string dump_ram;                 // --dump-ram FILE: the 32 KB at 8000h at the end
    bool        ram16k = false;
    bool        kbd_us = false;
    std::set<uint32_t> resets;            // --reset-at FRAME
    std::string wav_file;                 // --wav
    std::string disk_rom;                 // DIR/disk.rom: the PC-80S31's firmware at 6800h of boot.rom
    bool        disk_unit = false;        // --disk-unit (or --disk): load disk.rom, so the unit is connected
    std::string disk_file;                // --disk FILE: a .d88 mounted as S0
    std::string disk_out;                 // --disk-out FILE: the image as the drive left it
    std::map<uint32_t, std::string> swaps; // --swap-disk FRAME:FILE: mount FILE before FRAME
    std::string tape_file;                // --tape FILE: .cmt / .t88 through ioctl index 1 (.t88: 41h)
    bool        tape_turbo = false;       // --tape-turbo: OSD Tape speed 5x
    std::vector<std::string> after_motor; // --after-motor TEXT: typed 20 frames after each motor stop
    uint32_t    tape_end_stop = 0;        // --stop-after-motor N: end when the motor has stayed off N frames
};

static void usage()
{
    fprintf(stderr,
"usage: Vtop [options]\n"
"  --stop-at-frame N      exit after frame N (default 60)\n"
"  --quiet                no progress on stderr\n"
"  --rom-dir DIR          DIR/n80v110.rom and DIR/font.rom (default ../refs/emulators/mame_roms/pc8001);\n"
"                         --basic FILE / --font FILE\n"
"  --ram16k               16 KB RAM (C000-FFFF) instead of 32 KB\n"
"  --type FRAME:TEXT      type TEXT from FRAME; \\n or {RETURN}, {WAITn} ...\n"
"  --type-rate P:R        frames per key press:release (default 4:4)\n"
"  --reset-at F           reset before frame F\n"
"  --screenshot N         PNG of frame N (repeatable); --dump-every K: every Kth frame\n"
"  --out DIR              output directory (default ./out)\n"
"  --frame-log FILE       frame,fb_hash,cpu_cycles,pc per frame\n"
"  --trace-cpu FILE       frame,cpu_cycle,pc at each instruction fetch (M1)\n"
"  --trace-io FILE        frame,cpu_cycle,pc,kind,address,data for each IN/OUT\n"
"  --trace-from N         start tracing at frame N; --trace-to N stops after frame N\n"
"  --dump-ram FILE        write the RAM (8000-FFFF, 32 KB) to FILE at the end\n"
"  --wav FILE             record the audio output (48 kHz, 16-bit stereo WAV)\n"
"  --disk FILE            mount a .d88 (OSD Disk) and connect the PC-80S31 unit (DIR/disk.rom); --disk-unit:\n"
"                         the unit without a disk; --disk-out FILE writes the image as the drive left it\n"
"  --swap-disk F:FILE     mount FILE in the drive before frame F (repeatable)\n"
"  --tape FILE            load a .cmt / .t88 tape image (OSD Tape); --tape-turbo: OSD Tape speed 5x\n"
"  --after-motor TEXT     type TEXT 20 frames after the tape motor stops (repeatable: one per stop, in order)\n"
"  --stop-after-motor N   stop once the motor has stopped (after every --after-motor text) and stayed off\n"
"                         N frames; prints a TAPE line\n"
"fb_hash is FNV-1a 32 over the RGB888 bytes of the visible picture.\n");
}

static void mkdir_p(const std::string &path)
{
    for (size_t i = 1; i <= path.size(); i++)
        if (i == path.size() || path[i] == '/') mkdir(path.substr(0, i).c_str(), 0777);
}

static uint32_t parse_num(const std::string &s) { return (uint32_t)std::stoul(s, nullptr, 0); }

static bool parse_args(int argc, char **argv, Options &o)
{
    std::string dir = "../refs/emulators/mame_roms/pc8001";
    o.basic_rom = dir + "/n80v110.rom";
    o.font_rom = dir + "/font.rom";
    o.disk_rom = dir + "/disk.rom";
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= argc) { fprintf(stderr, "%s needs an argument\n", a.c_str()); exit(2); }
            return argv[++i];
        };
        auto pair = [&](const char *what, uint32_t &x, std::string &y) -> bool {
            std::string s = next();
            size_t c = s.find(':');
            if (c == std::string::npos) { fprintf(stderr, "%s wants %s\n", a.c_str(), what); return false; }
            x = parse_num(s.substr(0, c)); y = s.substr(c + 1);
            return true;
        };
        std::string rest;
        if (a == "--help" || a == "-h") { usage(); exit(0); }
        else if (a == "--headless") {}
        else if (a == "--stop-at-frame") o.stop_frame = parse_num(next());
        else if (a == "--quiet") o.quiet = true;
        else if (a == "--type") { uint32_t f; if (!pair("FRAME:TEXT", f, rest)) return false; o.types.push_back({f, rest}); }
        else if (a == "--type-rate") { if (!pair("P:R", o.type_press, rest)) return false; o.type_release = parse_num(rest); }
        else if (a == "--screenshot") o.screenshots.insert(parse_num(next()));
        else if (a == "--dump-every") o.dump_every = parse_num(next());
        else if (a == "--out") o.out_dir = next();
        else if (a == "--frame-log") o.frame_log = next();
        else if (a == "--trace-cpu") o.trace_file = next();
        else if (a == "--trace-io") o.io_file = next();
        else if (a == "--trace-from") o.trace_from = parse_num(next());
        else if (a == "--trace-to") o.trace_to = parse_num(next());
        else if (a == "--rom-dir") { std::string d = next(); o.basic_rom = d + "/n80v110.rom"; o.font_rom = d + "/font.rom"; o.disk_rom = d + "/disk.rom"; }
        else if (a == "--basic") o.basic_rom = next();
        else if (a == "--font") o.font_rom = next();
        else if (a == "--ram16k") o.ram16k = true;
        else if (a == "--kbd-us") o.kbd_us = true;
        else if (a == "--dump-ram") o.dump_ram = next();
        else if (a == "--reset-at") o.resets.insert(parse_num(next()));
        else if (a == "--wav") o.wav_file = next();
        else if (a == "--tape") o.tape_file = next();
        else if (a == "--disk") { o.disk_file = next(); o.disk_unit = true; }
        else if (a == "--disk-unit") o.disk_unit = true;
        else if (a == "--disk-out") o.disk_out = next();
        else if (a == "--swap-disk") { uint32_t f; if (!pair("FRAME:FILE", f, rest)) return false; o.swaps[f] = rest; }
        else if (a == "--tape-turbo") o.tape_turbo = true;
        else if (a == "--after-motor") o.after_motor.push_back(next());
        else if (a == "--stop-after-motor") o.tape_end_stop = parse_num(next());
        else if (a[0] == '+') {}   // Verilator plusargs
        else { fprintf(stderr, "unknown option %s (try --help)\n", a.c_str()); return false; }
    }
    return true;
}

struct Ps2Event { uint8_t code; bool ext; bool press; };

class Sim {
public:
    explicit Sim(const Options &o) : opt(o) { top = new Vtop; }
    ~Sim() { top->final(); delete top; }
    int run();
private:
    const Options &opt;
    Vtop     *top;
    uint64_t  cycle = 0, cpu_cycles = 0;
    uint32_t  frame = 0;
    int       exit_code = 0;
    bool      started = false;            // frame 0 starts when reset is released (the CRTC's counters start then)
    std::vector<uint8_t> fb, line;
    int       fb_w = 0, fb_h = 0;
    bool      prev_hb = false, prev_vb = false;
    FILE     *flog = nullptr, *ftrace = nullptr, *fio = nullptr;
    bool      prev_m1 = true;
    uint16_t  last_pc = 0;
    std::multimap<uint32_t, Ps2Event> ps2_schedule;
    std::deque<Ps2Event> ps2_queue;
    uint64_t  ps2_next_ok = 0;
    bool      ps2_toggle = false;
    FILE     *fwav = nullptr;
    uint32_t  wav_samples = 0;
    double    wav_next = 0;
    bool      prev_motor = false, done = false;
    size_t    motor_stops = 0;
    uint32_t  motor_off_frame = 0, motor_on_frames = 0;
    std::vector<uint8_t> disk;            // the disk image (hps_io S0): 512-byte blocks
    int       sd_state = 0;               // 0 idle, 1 read block, 2 write block
    uint32_t  sd_blk = 0, sd_i = 0, sd_wait = 0;
    bool      disk_written = false, prev_disk_motor = false;
    void sd_service();
    void disk_mount();
    void clock();
    void end_frame();
    bool tracing() const { return started && frame >= opt.trace_from && frame <= opt.trace_to; }
    void write_png(uint32_t f);
    void schedule_text(uint32_t f, const std::string &s);
    bool load_rom();
    void ioctl_load(uint32_t base, const std::vector<uint8_t> &data, int index = 0);
    void wav_close();
    void reset_machine();
};

void Sim::reset_machine()
{
    top->reset = 1;
    for (int i = 0; i < 64; i++) clock();
    top->reset = 0;
    if (!opt.quiet) fprintf(stderr, "[sim] reset before frame %u\n", frame);
}

static bool read_file(const std::string &name, std::vector<uint8_t> &out)
{
    FILE *f = fopen(name.c_str(), "rb");
    if (!f) return false;
    uint8_t buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) out.insert(out.end(), buf, buf + n);
    fclose(f);
    return true;
}

// hps_io style download: one byte every 4 clocks, machine held in reset by ioctl_download.
void Sim::ioctl_load(uint32_t base, const std::vector<uint8_t> &data, int index)
{
    top->ioctl_index = index;
    top->ioctl_download = 1;
    for (size_t i = 0; i < data.size(); i++) {
        top->ioctl_addr = base + (uint32_t)i;
        top->ioctl_dout = data[i];
        top->ioctl_wr = 1;
        clock();
        top->ioctl_wr = 0;
        clock(); clock(); clock();
        while (top->ioctl_wait) clock();
    }
    top->ioctl_download = 0;
}

// Main mounting the image: img_mounted for one clock with its size
void Sim::disk_mount()
{
    top->img_size = disk.size();
    top->img_readonly = 0;
    top->img_mounted = 1;
    clock();
    top->img_mounted = 0;
}

// hps_io's side of sd_rd / sd_wr: sd_ack for the block, sd_buff_wr per byte read in, sd_buff_din sampled per byte
// written out (the core's RAM has one clock of latency, so each address is held for 2 clocks)
void Sim::sd_service()
{
    if (sd_state == 0) {
        if (top->sd_rd || top->sd_wr) {
            sd_state = top->sd_rd ? 1 : 2;
            sd_blk = top->sd_lba;
            sd_i = 0; sd_wait = 0;
            top->sd_ack = 1;
            top->sd_buff_addr = 0;
            top->sd_buff_wr = 0;
        }
        return;
    }
    if (sd_state == 1) {
        if (top->sd_buff_wr) { top->sd_buff_wr = 0; if (++sd_i == 512) { top->sd_ack = 0; sd_state = 0; } return; }
        uint32_t a = sd_blk * 512 + sd_i;
        top->sd_buff_addr = sd_i;
        top->sd_buff_dout = a < disk.size() ? disk[a] : 0;
        top->sd_buff_wr = 1;
        return;
    }
    if (++sd_wait < 3) return;
    sd_wait = 0;
    uint32_t a = sd_blk * 512 + sd_i;
    if (a < disk.size()) { disk[a] = top->sd_buff_din; disk_written = true; }
    if (++sd_i == 512) { top->sd_ack = 0; sd_state = 0; return; }
    top->sd_buff_addr = sd_i;
}

// boot.rom as the MiSTer loads it: N-BASIC (24 KB) at 0, font.rom (2 KB) at 6000h, disk.rom (2 KB) at 6800h
bool Sim::load_rom()
{
    std::vector<uint8_t> d, font;
    if (!read_file(opt.basic_rom, d)) { fprintf(stderr, "cannot read BASIC ROM %s\n", opt.basic_rom.c_str()); return false; }
    if (d.size() != 0x6000) fprintf(stderr, "warning: %s is %zu bytes, expected 24576\n", opt.basic_rom.c_str(), d.size());
    d.resize(0x6000, 0xFF);
    if (!read_file(opt.font_rom, font)) { fprintf(stderr, "cannot read font %s\n", opt.font_rom.c_str()); return false; }
    font.resize(0x800, 0xFF);
    d.insert(d.end(), font.begin(), font.end());
    if (opt.disk_unit) {
        std::vector<uint8_t> dr;
        if (!read_file(opt.disk_rom, dr)) { fprintf(stderr, "cannot read %s\n", opt.disk_rom.c_str()); return false; }
        dr.resize(0x800, 0xFF);
        d.insert(d.end(), dr.begin(), dr.end());
        if (!opt.quiet) fprintf(stderr, "[sim] boot.rom: + '%s' (disk unit)\n", opt.disk_rom.c_str());
    }
    ioctl_load(0, d);
    if (!opt.quiet) fprintf(stderr, "[sim] boot.rom: '%s' + '%s'\n", opt.basic_rom.c_str(), opt.font_rom.c_str());
    return true;
}

static void wav_header(FILE *f, uint32_t samples)
{
    uint32_t data = samples * 4, riff = 36 + data, fmt_len = 16, rate = 48000, brate = 48000 * 4;
    uint16_t pcm = 1, ch = 2, align = 4, bits = 16;
    fseek(f, 0, SEEK_SET);
    fwrite("RIFF", 1, 4, f); fwrite(&riff, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
    fwrite(&fmt_len, 4, 1, f); fwrite(&pcm, 2, 1, f); fwrite(&ch, 2, 1, f); fwrite(&rate, 4, 1, f);
    fwrite(&brate, 4, 1, f); fwrite(&align, 2, 1, f); fwrite(&bits, 2, 1, f);
    fwrite("data", 1, 4, f); fwrite(&data, 4, 1, f);
}

void Sim::wav_close()
{
    if (!fwav) return;
    wav_header(fwav, wav_samples);
    fclose(fwav);
    fwav = nullptr;
}

void Sim::clock()
{
    // Sample what the video pipeline sees at this rising edge: MiSTer's video_mixer latches RGB on the
    // clk_sys edge where CE_PIXEL is high.
    top->clk_sys = 0;
    top->eval();
    if (top->ce_pix) {
        bool hb = top->VGA_HB, vb = top->VGA_VB;
        if (!hb && !vb) {
            line.push_back(top->VGA_R);
            line.push_back(top->VGA_G);
            line.push_back(top->VGA_B);
        }
        if (hb && !prev_hb && !line.empty()) {
            int w = (int)line.size() / 3;
            if (fb_h == 0) fb_w = w;
            line.resize((size_t)fb_w * 3, 0);
            fb.insert(fb.end(), line.begin(), line.end());
            fb_h++;
            line.clear();
        }
        prev_hb = hb;
        if (vb && !prev_vb) end_frame();
        prev_vb = vb;
    }
    top->clk_sys = 1;
    top->eval();
    cycle++;
    sd_service();
    if (top->cpu_ce) cpu_cycles++;
    if (top->disk_motor != prev_disk_motor) {
        prev_disk_motor = top->disk_motor;
        if (!opt.quiet) fprintf(stderr, "[sim] frame %u: disk motor %s\n", frame, prev_disk_motor ? "on" : "off");
    }

    if (fwav && cycle >= wav_next) {
        int16_t lr[2] = {(int16_t)top->AUDIO_L, (int16_t)top->AUDIO_R};
        fwrite(lr, 2, 2, fwav);
        wav_samples++;
        wav_next += CLK_HZ / 48000.0;
    }

    if (top->tape_motor != prev_motor) {
        prev_motor = top->tape_motor;
        if (!opt.quiet) fprintf(stderr, "[sim] frame %u: tape motor %s (byte %u of %u)\n", frame, prev_motor ? "on" : "off",
                                (unsigned)top->tape_position, (unsigned)top->tape_length);
        if (!prev_motor) {
            if (motor_stops < opt.after_motor.size()) schedule_text(frame + 20, opt.after_motor[motor_stops]);
            motor_stops++;
            motor_off_frame = frame;
        }
    }

    bool m1 = top->cpu_m1_n;
    if (!m1 && prev_m1) {
        last_pc = top->cpu_addr;
        if (ftrace && tracing()) fprintf(ftrace, "%u,%llu,%04x\n", frame, (unsigned long long)cpu_cycles, last_pc);
    }
    prev_m1 = m1;
    if (fio && tracing() && (top->dbg_io_wr || top->dbg_io_rd))
        fprintf(fio, "%u,%llu,%04x,%c,%02x,%02x\n", frame, (unsigned long long)cpu_cycles, last_pc,
                top->dbg_io_wr ? 'W' : 'R', top->dbg_io_port, top->dbg_io_data);

    // hps_io style ps2_key: bit 10 toggles per event, 9 = pressed, 8 = extended. One event per ~1 ms.
    if (!ps2_queue.empty() && cycle >= ps2_next_ok) {
        Ps2Event e = ps2_queue.front();
        ps2_queue.pop_front();
        ps2_toggle = !ps2_toggle;
        top->ps2_key = (uint16_t)((ps2_toggle << 10) | (e.press << 9) | (e.ext << 8) | e.code);
        ps2_next_ok = cycle + (uint64_t)(CLK_HZ / 1000);
    }
}

void Sim::end_frame()
{
    uint32_t h = 2166136261u;
    for (uint8_t b : fb) { h ^= b; h *= 16777619u; }
    if (flog) fprintf(flog, "%u,%08x,%llu,%04x\n", frame, h, (unsigned long long)cpu_cycles, last_pc);
    if (opt.screenshots.count(frame) || (opt.dump_every && frame % opt.dump_every == 0)) write_png(frame);
    if (!opt.quiet && frame % 50 == 0)
        fprintf(stderr, "[sim] frame %u  %.3fs emulated  %dx%d  pc %04x  hash %08x\n",
                frame, cycle / CLK_HZ, fb_w, fb_h, last_pc, h);
    fb.clear(); fb_h = 0; line.clear();
    if (top->tape_motor) motor_on_frames++;
    if (opt.tape_end_stop && motor_stops && motor_stops >= opt.after_motor.size() && !top->tape_motor &&
        frame - motor_off_frame >= opt.tape_end_stop) done = true;
    frame++;
    auto range = ps2_schedule.equal_range(frame);
    for (auto it = range.first; it != range.second; ++it) ps2_queue.push_back(it->second);
    if (opt.resets.count(frame)) reset_machine();
    auto sw = opt.swaps.find(frame);
    if (sw != opt.swaps.end()) {
        disk.clear();
        if (!read_file(sw->second, disk)) fprintf(stderr, "cannot read disk %s\n", sw->second.c_str());
        else {
            disk_mount();
            if (!opt.quiet) fprintf(stderr, "[sim] frame %u: disk '%s' mounted\n", frame, sw->second.c_str());
        }
    }
}

void Sim::write_png(uint32_t f)
{
    if (fb_w == 0 || fb_h == 0) { fprintf(stderr, "[sim] frame %u: no picture\n", f); return; }
    char name[1024];
    snprintf(name, sizeof(name), "%s/frame_%06u.png", opt.out_dir.c_str(), f);
    if (!stbi_write_png(name, fb_w, fb_h, 3, fb.data(), fb_w * 3)) {
        fprintf(stderr, "cannot write %s\n", name);
        exit_code = 3;
    }
    else if (!opt.quiet) fprintf(stderr, "[sim] wrote %s (%dx%d)\n", name, fb_w, fb_h);
}

void Sim::schedule_text(uint32_t f, const std::string &s)
{
    for (size_t i = 0; i < s.size(); i++) {
        Ps2Key k;
        bool ok = false;
        if (s[i] == '\\' && i + 1 < s.size()) {
            char c = s[++i];
            c = c == 'n' || c == 'r' ? '\n' : c;
            ok = opt.kbd_us ? ps2_from_ascii_us(c, k) : ps2_from_ascii(c, k);
        } else if (s[i] == '{') {
            size_t e = s.find('}', i);
            std::string name = s.substr(i + 1, e - i - 1);
            i = e;
            if (name.rfind("WAIT", 0) == 0) { f += parse_num(name.substr(4)); continue; }
            ok = ps2_from_name(name, k);
            if (!ok) fprintf(stderr, "--type: unknown key {%s}\n", name.c_str());
        } else {
            ok = opt.kbd_us ? ps2_from_ascii_us(s[i], k) : ps2_from_ascii(s[i], k);
            if (!ok) fprintf(stderr, "--type: no key for '%c'\n", s[i]);
        }
        if (!ok) continue;
        if (k.shift) ps2_schedule.insert({f, {PS2_LSHIFT, false, true}});
        ps2_schedule.insert({f, {k.code, k.extended, true}});
        ps2_schedule.insert({f + opt.type_press, {k.code, k.extended, false}});
        if (k.shift) ps2_schedule.insert({f + opt.type_press, {PS2_LSHIFT, false, false}});
        f += opt.type_press + opt.type_release;
    }
}

int Sim::run()
{
    mkdir_p(opt.out_dir);
    if (!opt.frame_log.empty() && !(flog = fopen(opt.frame_log.c_str(), "w"))) { perror(opt.frame_log.c_str()); return 2; }
    if (!opt.trace_file.empty() && !(ftrace = fopen(opt.trace_file.c_str(), "w"))) { perror(opt.trace_file.c_str()); return 2; }
    if (!opt.io_file.empty() && !(fio = fopen(opt.io_file.c_str(), "w"))) { perror(opt.io_file.c_str()); return 2; }
    if (flog) fprintf(flog, "frame,fb_hash,cpu_cycles,pc\n");
    if (ftrace) fprintf(ftrace, "frame,cpu_cycle,pc\n");
    if (fio) fprintf(fio, "frame,cpu_cycle,pc,kind,address,data\n");
    if (!opt.wav_file.empty()) {
        if (!(fwav = fopen(opt.wav_file.c_str(), "wb"))) { perror(opt.wav_file.c_str()); return 2; }
        wav_header(fwav, 0);
    }

    top->ram16k = opt.ram16k;
    top->tape_turbo = opt.tape_turbo;
    top->tape_rewind = 0;
    top->reset = 1;
    top->ps2_key = 0;
    for (int i = 0; i < 16; i++) clock();
    if (!load_rom()) return 2;
    if (!opt.disk_file.empty()) {
        if (!read_file(opt.disk_file, disk)) { fprintf(stderr, "cannot read disk %s\n", opt.disk_file.c_str()); return 2; }
        disk_mount();
        if (!opt.quiet) fprintf(stderr, "[sim] disk: '%s', %zu bytes\n", opt.disk_file.c_str(), disk.size());
    }
    for (int i = 0; i < 16; i++) clock();
    top->reset = 0;
    fb.clear(); fb_h = 0; line.clear(); prev_hb = prev_vb = false; started = true;

    if (!opt.tape_file.empty()) {
        std::vector<uint8_t> t;
        if (!read_file(opt.tape_file, t)) { fprintf(stderr, "cannot read tape %s\n", opt.tape_file.c_str()); return 2; }
        // Main puts the extension's place in the F1 list ("CMTT88") in index bits 7:6
        std::string ext = opt.tape_file.substr(opt.tape_file.find_last_of('.') + 1);
        for (auto &c : ext) c = (char)tolower((unsigned char)c);
        ioctl_load(0, t, ext == "t88" ? 0x41 : 0x01);
        if (!opt.quiet) fprintf(stderr, "[sim] tape: '%s', %zu bytes\n", opt.tape_file.c_str(), t.size());
    }
    for (auto &t : opt.types) schedule_text(t.frame, t.text);
    auto range = ps2_schedule.equal_range(frame);
    for (auto it = range.first; it != range.second; ++it) ps2_queue.push_back(it->second);

    while (frame <= opt.stop_frame && !done && !Verilated::gotFinish()) clock();
    if (opt.tape_end_stop) {
        char name[1024];
        snprintf(name, sizeof(name), "%s/last.png", opt.out_dir.c_str());
        printf("TAPE frames=%u motor_on_frames=%u motor_stops=%zu pos=%u len=%u\n", frame, motor_on_frames,
               motor_stops, (unsigned)top->tape_position, (unsigned)top->tape_length);
    }

    if (!opt.dump_ram.empty()) {
        FILE *fr = fopen(opt.dump_ram.c_str(), "wb");
        if (!fr) perror(opt.dump_ram.c_str());
        else {
            for (int i = 0; i < 0x8000; i++) { uint8_t v = top->rootp->top__DOT__pc8001__DOT__ram__DOT__mem[i]; fwrite(&v, 1, 1, fr); }
            fclose(fr);
        }
    }
    if (!opt.disk_out.empty() && !disk.empty()) {
        FILE *fd = fopen(opt.disk_out.c_str(), "wb");
        if (!fd) perror(opt.disk_out.c_str());
        else { fwrite(disk.data(), 1, disk.size(), fd); fclose(fd); }
        if (!opt.quiet) fprintf(stderr, "[sim] disk written to '%s'%s\n", opt.disk_out.c_str(), disk_written ? "" : " (unchanged)");
    }
    wav_close();
    if (flog) fclose(flog);
    if (ftrace) fclose(ftrace);
    if (fio) fclose(fio);
    if (!opt.quiet) fprintf(stderr, "[sim] done: %u frames, %.3f s emulated\n", frame, cycle / CLK_HZ);
    return exit_code;
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    Options o;
    if (!parse_args(argc, argv, o)) return 2;
    Sim sim(o);
    return sim.run();
}
