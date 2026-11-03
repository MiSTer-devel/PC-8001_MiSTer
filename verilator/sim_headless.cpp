// Headless PC-8001 simulation: run frames, type keys, capture PNG screenshots, frame hashes and traces.
//
// Cut down from the PC-6001 core's verilator/sim_headless.cpp (same option names). Examples:
//
//   ./obj_dir_headless/Vtop --rom-dir ../refs/emulators/mame_roms/pc8001 --stop-at-frame 120 --screenshot 120
//   ./obj_dir_headless/Vtop --stop-at-frame 60 --frame-log out/frames.csv --trace-io out/io.csv
//
// A frame ends when vertical blanking starts; frame 0 is the first full one after reset. Each PNG is the visible
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
        else if (a == "--rom-dir") { std::string d = next(); o.basic_rom = d + "/n80v110.rom"; o.font_rom = d + "/font.rom"; }
        else if (a == "--basic") o.basic_rom = next();
        else if (a == "--font") o.font_rom = next();
        else if (a == "--ram16k") o.ram16k = true;
        else if (a == "--kbd-us") o.kbd_us = true;
        else if (a == "--dump-ram") o.dump_ram = next();
        else if (a == "--reset-at") o.resets.insert(parse_num(next()));
        else if (a == "--wav") o.wav_file = next();
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
    bool      started = false;            // frames are counted from the first full one after reset
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

// boot.rom as the MiSTer loads it: N-BASIC (24 KB) at 0, font.rom (2 KB) at 6000h
bool Sim::load_rom()
{
    std::vector<uint8_t> d, font;
    if (!read_file(opt.basic_rom, d)) { fprintf(stderr, "cannot read BASIC ROM %s\n", opt.basic_rom.c_str()); return false; }
    if (d.size() != 0x6000) fprintf(stderr, "warning: %s is %zu bytes, expected 24576\n", opt.basic_rom.c_str(), d.size());
    d.resize(0x6000, 0xFF);
    if (!read_file(opt.font_rom, font)) { fprintf(stderr, "cannot read font %s\n", opt.font_rom.c_str()); return false; }
    font.resize(0x800, 0xFF);
    d.insert(d.end(), font.begin(), font.end());
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
    if (top->cpu_ce) cpu_cycles++;

    if (fwav && cycle >= wav_next) {
        int16_t lr[2] = {(int16_t)top->AUDIO_L, (int16_t)top->AUDIO_R};
        fwrite(lr, 2, 2, fwav);
        wav_samples++;
        wav_next += CLK_HZ / 48000.0;
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
    if (!started) { fb.clear(); fb_h = 0; line.clear(); started = true; return; }
    uint32_t h = 2166136261u;
    for (uint8_t b : fb) { h ^= b; h *= 16777619u; }
    if (flog) fprintf(flog, "%u,%08x,%llu,%04x\n", frame, h, (unsigned long long)cpu_cycles, last_pc);
    if (opt.screenshots.count(frame) || (opt.dump_every && frame % opt.dump_every == 0)) write_png(frame);
    if (!opt.quiet && frame % 50 == 0)
        fprintf(stderr, "[sim] frame %u  %.3fs emulated  %dx%d  pc %04x  hash %08x\n",
                frame, cycle / CLK_HZ, fb_w, fb_h, last_pc, h);
    fb.clear(); fb_h = 0; line.clear();
    frame++;
    auto range = ps2_schedule.equal_range(frame);
    for (auto it = range.first; it != range.second; ++it) ps2_queue.push_back(it->second);
    if (opt.resets.count(frame)) reset_machine();
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
    top->reset = 1;
    top->ps2_key = 0;
    for (int i = 0; i < 16; i++) clock();
    if (!load_rom()) return 2;
    for (int i = 0; i < 16; i++) clock();
    top->reset = 0;

    for (auto &t : opt.types) schedule_text(t.frame, t.text);
    auto range = ps2_schedule.equal_range(frame);
    for (auto it = range.first; it != range.second; ++it) ps2_queue.push_back(it->second);

    while (frame <= opt.stop_frame && !Verilated::gotFinish()) clock();

    if (!opt.dump_ram.empty()) {
        FILE *fr = fopen(opt.dump_ram.c_str(), "wb");
        if (!fr) perror(opt.dump_ram.c_str());
        else {
            for (int i = 0; i < 0x8000; i++) { uint8_t v = top->rootp->top__DOT__pc8001__DOT__ram__DOT__mem[i]; fwrite(&v, 1, 1, fr); }
            fclose(fr);
        }
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
