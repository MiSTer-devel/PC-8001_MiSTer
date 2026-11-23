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
#include <sys/wait.h>
#include <unistd.h>

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
    std::vector<TypeCmd> types_rel;                     // --type-rel REL:TEXT: typed REL frames past the load's end
    std::vector<std::pair<uint32_t, uint32_t>> joys;   // --joy FRAME:BITS (hex): joystick bits from that frame
    uint32_t    joy_cfg = 0;                            // --joy-cfg N: OSD status[29:18]
    std::vector<std::pair<uint32_t, uint32_t>> joys_rel;  // --joy-rel REL:BITS: from REL frames past the load's end
    uint32_t    stop_rel = 0;                           // --stop-rel N: end N frames past the load's end
    // --fork NAME:REL:BITS,...: at the load's end a copy of the run (fork) writes to OUT/NAME with these presses
    std::vector<std::pair<std::string, std::vector<std::pair<uint32_t, uint32_t>>>> forks;
    uint32_t    type_press = 4, type_release = 4;
    std::string trace_file;               // --trace-cpu
    std::string io_file;                  // --trace-io
    uint32_t    trace_from = 0, trace_to = 0xFFFFFFFF;
    std::string basic_rom, font_rom;      // --rom-dir DIR: DIR/n80v110.rom, DIR/font.rom (MAME names)
    std::string dump_ram;                 // --dump-ram FILE: the 32 KB at 8000h at the end
    bool        ram16k = false;
    bool        pcg = false;              // --pcg: PCG-8100 connected
    int         model = 0;                // --mk2: 1 (OSD Model PC-8001mkII)
    bool        n_mode = false;           // --n-mode: the mkII's N-BASIC switch
    std::string mk2_dir = "../refs/emulators/mame_roms/pc8001mk2";   // --mk2-dir: n80_2.rom, kanji1.rom
    int         main_gap = -1;    // --main-start N: boot*.rom loaded as Main does (all, the core running), N clocks apart
    std::string sr_dir = "../refs/emulators/mame_roms/pc8001mk2sr";  // --sr-dir: n80_2sr.rom, n80_3.rom, font80sr.rom, kanji1.rom
    bool        v2 = false;               // --v2: the SR's N80SR mode
    bool        kbd_us = false;
    bool        overlay = false;          // --overlay: the tape overlay and next-step hint
    bool        hint_log = false;         // --hint-log: print the next-step hint each time it changes
    std::set<uint32_t> resets;            // --reset-at FRAME
    std::string wav_file;                 // --wav
    std::string disk_rom;                 // DIR/disk.rom: the PC-80S31's firmware at 6800h of boot.rom
    bool        disk_unit = false;        // --disk-unit (or --disk): load disk.rom, so the unit is connected
    std::string disk_file[2];             // --disk FILE / --disk2 FILE: a .d88 mounted as S0 / S1
    std::string disk_out;                 // --disk-out FILE: the image as the drive left it
    std::multimap<uint32_t, std::pair<int, std::string>> swaps; // --swap-disk[2] FRAME:FILE: mount before FRAME
    std::multimap<uint32_t, std::string> tape_swaps;           // --swap-tape FRAME:FILE: mount a tape at FRAME
    std::map<uint32_t, std::string> tape_after;                // --tape-after-motor N:FILE: 10 frames after stop N
    std::string tape_file;                // --tape FILE: .cmt / .t88 through ioctl index 1 (.t88: 41h)
    uint32_t    n80_frame = 0;            // --n80 FRAME:FILE: a .n80 memory image (OSD F3, ioctl index 3) at FRAME
    std::string n80_file;
    bool        tape_turbo = false;       // --tape-turbo: OSD Tape speed 5x
    std::vector<std::string> after_motor; // --after-motor TEXT: typed 20 frames after each motor stop
    uint32_t    tape_end_stop = 0;        // --stop-after-motor N: end when the motor has stayed off N frames
    std::string ext_rom;                  // --ext-rom FILE: expansion ROM at 6000h (OSD F2, ioctl index 2)
    std::string printer;                  // --printer FILE: bytes sent to the printer
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
"  --joy FRAME:BITS      joystick bits (hex: 1 right 2 left 4 down 8 up 10 A 20 B 40 C 80 Start 100 Select 200 STOP) from FRAME\n"
"  --joy-rel REL:BITS    joystick bits REL frames past the load's end (every --after-motor text typed, then\n"
"                         the tape at its end for 180 frames or the motor off for 900; prints LOADEND frame=N)\n"
"  --type-rel REL:TEXT    type TEXT REL frames past the load's end (as --type)\n"
"  --stop-rel N           end N frames past the load's end\n"
"  --fork NAME:REL:BITS,...  at the load's end a copy of the run (fork) in OUT/NAME, with these joystick\n"
"                         changes added (REL frames past the load's end); repeatable\n"
"  --joy-cfg N           OSD Input rows, status[29:18]: 1-0 Joystick, 2 Diagonals, 5-3 A, 8-6 B, 11-9 C\n"
"  --pcg                  PCG-8100 connected\n"
"  --mk2                  PC-8001mkII (boot1.rom = DIR/n80_2.rom + DIR/kanji1.rom, --mk2-dir DIR); --n-mode:\n"
"                         its N-BASIC switch\n"
"  --sr                   PC-8001mkIISR (boot2.rom from --sr-dir DIR: n80_2sr.rom, n80_3.rom, font80sr.rom,\n"
"                         kanji1.rom); --n-mode N mode, --v2 N80SR mode (else N80 mode)\n"
"  --kbd-us               keyboard: US symbols (OSD Keyboard = US)\n"
"  --overlay              draw the tape overlay (status bar, next-step hint) as the core does\n"
"  --hint-log             print the next-step hint each time it changes ([hint] frame N: TYPE ... <ret>)\n"
"  --ext-rom FILE         expansion ROM at 6000h (OSD Expansion ROM)\n"
"  --printer FILE         write the bytes sent to the printer to FILE\n"
"  --type FRAME:TEXT      type TEXT from FRAME; \\n or {RETURN}, {WAITn}, {CTRL+B} ...\n"
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
"  --disk2 FILE           mount a .d88 in drive 2 (OSD S1)\n"
"  --swap-disk F:FILE     mount FILE in drive 1 before frame F (repeatable); --swap-disk2 for drive 2\n"
"  --tape FILE            load a .cmt / .t88 tape image (OSD Tape); --tape-turbo: OSD Tape speed 5x\n"
"  --swap-tape F:FILE     mount another tape at frame F, as choosing it in OSD Tape (repeatable)\n"
"  --tape-after-motor N:FILE  mount FILE 10 frames after the tape motor's N-th stop (1 = first; repeatable)\n"
"  --n80 FRAME:FILE       load a .n80 memory image at FRAME (OSD Memory Image): it starts at once\n"
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
        else if (a == "--type-rel") { uint32_t f; if (!pair("REL:TEXT", f, rest)) return false; o.types_rel.push_back({f, rest}); }
        else if (a == "--joy") { uint32_t f; if (!pair("FRAME:BITS", f, rest)) return false; o.joys.push_back({f, (uint32_t)strtoul(rest.c_str(), nullptr, 16)}); }
        else if (a == "--joy-cfg") o.joy_cfg = parse_num(next());
        else if (a == "--joy-rel") { uint32_t f; if (!pair("REL:BITS", f, rest)) return false; o.joys_rel.push_back({f, (uint32_t)strtoul(rest.c_str(), nullptr, 16)}); }
        else if (a == "--stop-rel") o.stop_rel = parse_num(next());
        else if (a == "--fork") {
            std::string v = next(); size_t c = v.find(':');
            if (c == std::string::npos) { fprintf(stderr, "--fork NAME:REL:BITS,...\n"); return false; }
            std::vector<std::pair<uint32_t, uint32_t>> js;
            std::string r = v.substr(c + 1);
            while (!r.empty()) {
                size_t e = r.find(','); std::string one = r.substr(0, e);
                size_t k = one.find(':');
                js.push_back({(uint32_t)strtoul(one.substr(0, k).c_str(), nullptr, 10), (uint32_t)strtoul(one.substr(k + 1).c_str(), nullptr, 16)});
                r = e == std::string::npos ? "" : r.substr(e + 1);
            }
            o.forks.push_back({v.substr(0, c), js});
        }
        else if (a == "--type-rate") { if (!pair("P:R", o.type_press, rest)) return false; o.type_release = parse_num(rest); }
        else if (a == "--screenshot") o.screenshots.insert(parse_num(next()));
        else if (a == "--dump-every") o.dump_every = parse_num(next());
        else if (a == "--out") o.out_dir = next();
        else if (a == "--frame-log") o.frame_log = next();
        else if (a == "--trace-cpu") o.trace_file = next();
        else if (a == "--trace-io") o.io_file = next();
        else if (a == "--trace-from") o.trace_from = parse_num(next());
        else if (a == "--trace-to") o.trace_to = parse_num(next());
        else if (a == "--rom-dir") { std::string d = next(); o.basic_rom = d + "/n80v110.rom"; o.font_rom = d + "/font.rom"; o.disk_rom = d + "/disk.rom"; o.mk2_dir = d + "mk2"; o.sr_dir = d + "mk2sr"; }
        else if (a == "--basic") o.basic_rom = next();
        else if (a == "--font") o.font_rom = next();
        else if (a == "--ram16k") o.ram16k = true;
        else if (a == "--pcg") o.pcg = true;
        else if (a == "--mk2") o.model = 1;
        else if (a == "--sr") o.model = 2;
        else if (a == "--main-start") o.main_gap = atoi(next().c_str());
        else if (a == "--v2") o.v2 = true;
        else if (a == "--sr-dir") o.sr_dir = next();
        else if (a == "--n-mode") o.n_mode = true;
        else if (a == "--mk2-dir") o.mk2_dir = next();
        else if (a == "--kbd-us") o.kbd_us = true;
        else if (a == "--overlay") o.overlay = true;
        else if (a == "--hint-log") o.hint_log = true;
        else if (a == "--ext-rom") o.ext_rom = next();
        else if (a == "--printer") o.printer = next();
        else if (a == "--dump-ram") o.dump_ram = next();
        else if (a == "--reset-at") o.resets.insert(parse_num(next()));
        else if (a == "--wav") o.wav_file = next();
        else if (a == "--tape") o.tape_file = next();
        else if (a == "--n80") {
            std::string v = next();
            size_t c = v.find(':');
            if (c == std::string::npos) { fprintf(stderr, "--n80 FRAME:FILE\n"); exit(2); }
            o.n80_frame = parse_num(v.substr(0, c)); o.n80_file = v.substr(c + 1);
        }
        else if (a == "--disk") { o.disk_file[0] = next(); o.disk_unit = true; }
        else if (a == "--disk2") { o.disk_file[1] = next(); o.disk_unit = true; }
        else if (a == "--disk-unit") o.disk_unit = true;
        else if (a == "--disk-out") o.disk_out = next();
        else if (a == "--swap-disk" || a == "--swap-disk2") {
            uint32_t f; if (!pair("FRAME:FILE", f, rest)) return false;
            o.swaps.insert({f, {a == "--swap-disk2" ? 1 : 0, rest}});
        }
        else if (a == "--swap-tape") {
            uint32_t f; if (!pair("FRAME:FILE", f, rest)) return false;
            o.tape_swaps.insert({f, rest});
        }
        else if (a == "--tape-after-motor") {
            uint32_t n; if (!pair("N:FILE", n, rest)) return false;
            o.tape_after[n] = rest;
        }
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
    explicit Sim(const Options &o) : opt(o), out_dir(o.out_dir) { top = new Vtop; }
    ~Sim() { top->final(); delete top; }
    int run();
private:
    const Options &opt;
    std::string out_dir;                  // --out (a --fork copy: OUT/NAME)
    std::vector<pid_t> children;
    Vtop     *top;
    uint64_t  cycle = 0, cpu_cycles = 0;
    uint32_t  frame = 0;
    int       exit_code = 0;
    bool      started = false;            // frame 0 starts when reset is released (the CRTC's counters start then)
    std::vector<uint8_t> fb, line;
    int       fb_w = 0, fb_h = 0;
    bool      prev_hb = false, prev_vb = false;
    FILE     *flog = nullptr, *ftrace = nullptr, *fio = nullptr, *fprn = nullptr;
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
    std::multimap<uint32_t, std::string> tswaps;   // tapes to mount: frame -> file
    std::string last_hint;
    int last_machine = 0;
    uint32_t  motor_off_frame = 0, motor_on_frames = 0;
    uint32_t  load_end = 0, idle_frames = 0;   // --joy-rel / --stop-rel: the frame the load ended
    std::vector<std::pair<uint32_t, uint32_t>> joys_late;   // --joy-rel, made absolute at the load's end
    std::vector<uint8_t> disks[2];        // the disk images (hps_io S0, S1): 512-byte blocks
    int       sd_state = 0;               // 0 idle, 1 read block, 2 write block
    int       sd_drv = 0;
    uint32_t  sd_blk = 0, sd_i = 0, sd_wait = 0;
    bool      disk_written = false, prev_disk_motor = false;
    void sd_service();
    void disk_mount(int d);
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
    clock();
    while (top->ioctl_wait) clock();      // Main sends nothing while the core waits
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
void Sim::disk_mount(int d)
{
    top->img_size = disks[d].size();
    top->img_readonly = 0;
    top->img_mounted = 1 << d;
    clock();
    top->img_mounted = 0;
}

// hps_io's side of sd_rd / sd_wr: sd_ack for the block, sd_buff_wr per byte read in, sd_buff_din sampled per byte
// written out (the core's RAM has one clock of latency, so each address is held for 2 clocks)
void Sim::sd_service()
{
    if (sd_state == 0) {
        if (top->sd_rd || top->sd_wr) {
            sd_drv = ((top->sd_rd | top->sd_wr) & 1) ? 0 : 1;
            sd_state = (top->sd_rd >> sd_drv) & 1 ? 1 : 2;
            sd_blk = (uint32_t)(top->sd_lba >> (32 * sd_drv));
            sd_i = 0; sd_wait = 0;
            top->sd_ack = 1 << sd_drv;
            top->sd_buff_addr = 0;
            top->sd_buff_wr = 0;
        }
        return;
    }
    if (sd_state == 1) {
        if (top->sd_buff_wr) { top->sd_buff_wr = 0; if (++sd_i == 512) { top->sd_ack = 0; sd_state = 0; } return; }
        uint32_t a = sd_blk * 512 + sd_i;
        top->sd_buff_addr = sd_i;
        top->sd_buff_dout = a < disks[sd_drv].size() ? disks[sd_drv][a] : 0;
        top->sd_buff_wr = 1;
        return;
    }
    if (++sd_wait < 3) return;
    sd_wait = 0;
    uint32_t a = sd_blk * 512 + sd_i;
    if (a < disks[sd_drv].size()) { disks[sd_drv][a] = top->sd_buff_din; if (sd_drv == 0) disk_written = true; }
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
    if (fprn && top->prn_wr) fputc(top->prn_data, fprn);
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
            auto ta = opt.tape_after.find((uint32_t)motor_stops + 1);
            if (ta != opt.tape_after.end()) tswaps.insert({frame + 10, ta->second});
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
    if (opt.hint_log) {
        std::string h;
        if (top->hint_show) {
            for (int i = 0; i < 22; i++) {
                int bit = 175 - 8 * i - 7;
                uint8_t c = (top->hint_text[bit / 32] >> (bit % 32)) & 0xFF;
                if (bit % 32 > 24) c = (uint8_t)(((uint64_t)top->hint_text[bit / 32 + 1] << 32 | top->hint_text[bit / 32]) >> (bit % 32));
                h += c == 1 ? std::string("<ret>") : std::string(1, (char)c);
            }
            while (!h.empty() && h.back() == ' ') h.pop_back();
        }
        if (h != last_hint) { printf("[hint] frame %u: %s\n", frame, h.empty() ? "(none)" : h.c_str()); fflush(stdout); last_hint = h; }
        if (top->hint_machine != last_machine) {
            static const char *mn[] = {"any", "mkII N80 mode", "mkII Mode N", "PC-8801"};
            printf("[hint] frame %u: machine %s\n", frame, mn[top->hint_machine & 3]); fflush(stdout); last_machine = top->hint_machine;
        }
    }
    // the load's end: every --after-motor text used, and the deck stopped (or at the tape's end) for 180 frames
    if (!load_end && (!opt.joys_rel.empty() || !opt.types_rel.empty() || opt.stop_rel)) {
        // the tape at its end for 180 frames, or the deck stopped for 900 (a loader may pause between files)
        bool at_end = top->tape_length && top->tape_position >= top->tape_length;
        bool idle = motor_stops >= std::max<size_t>(1, opt.after_motor.size()) && (at_end || !top->tape_motor);
        idle_frames = idle ? idle_frames + 1 : 0;
        if (idle_frames >= (at_end ? 180u : 900u)) {
            load_end = frame;
            printf("LOADEND frame=%u\n", frame); fflush(stdout);
            for (auto &j : opt.joys_rel) joys_late.push_back({frame + j.first, j.second});
            for (auto &t : opt.types_rel) schedule_text(frame + t.frame, t.text);
            fflush(stdout); fflush(stderr); if (flog) fflush(flog);
            for (auto &fk : opt.forks) {
                pid_t pid = fork();
                if (pid < 0) { perror("fork"); continue; }
                if (pid > 0) { children.push_back(pid); continue; }
                // the copy: its own output folder, frame log and presses
                children.clear();
                out_dir = opt.out_dir + "/" + fk.first;
                mkdir_p(out_dir);
                if (flog) {
                    fclose(flog);
                    flog = fopen((out_dir + "/frames.csv").c_str(), "w");
                    if (flog) fprintf(flog, "frame,fb_hash,cpu_cycles,pc\n");
                }
                for (auto &j : fk.second) joys_late.push_back({frame + j.first, j.second});
                break;
            }
        }
    }
    if (opt.stop_rel && load_end && frame >= load_end + opt.stop_rel) done = true;
    if (opt.tape_end_stop && motor_stops && motor_stops >= opt.after_motor.size() && !top->tape_motor &&
        frame - motor_off_frame >= opt.tape_end_stop) done = true;
    frame++;
    auto range = ps2_schedule.equal_range(frame);
    for (auto it = range.first; it != range.second; ++it) ps2_queue.push_back(it->second);
    if (opt.resets.count(frame)) reset_machine();
    auto sws = opt.swaps.equal_range(frame);
    for (auto sw = sws.first; sw != sws.second; ++sw) {
        int d = sw->second.first;
        disks[d].clear();
        if (!read_file(sw->second.second, disks[d])) fprintf(stderr, "cannot read disk %s\n", sw->second.second.c_str());
        else {
            disk_mount(d);
            if (!opt.quiet) fprintf(stderr, "[sim] frame %u: disk '%s' mounted in drive %d\n", frame, sw->second.second.c_str(), d + 1);
        }
    }
}

void Sim::write_png(uint32_t f)
{
    if (fb_w == 0 || fb_h == 0) { fprintf(stderr, "[sim] frame %u: no picture\n", f); return; }
    char name[1024];
    snprintf(name, sizeof(name), "%s/frame_%06u.png", out_dir.c_str(), f);
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
        bool ctrl = false;
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
            if (name.rfind("CTRL+", 0) == 0 && name.size() == 6) {
                // {CTRL+B}: CTRL held a frame before the key until a frame after (the monitor's Ctrl+B)
                ok = ps2_from_ascii((char)tolower(name[5]), k);
                if (ok) ctrl = true;
            }
            else ok = ps2_from_name(name, k);
            if (!ok) fprintf(stderr, "--type: unknown key {%s}\n", name.c_str());
        } else {
            ok = opt.kbd_us ? ps2_from_ascii_us(s[i], k) : ps2_from_ascii(s[i], k);
            if (!ok) fprintf(stderr, "--type: no key for '%c'\n", s[i]);
        }
        if (!ok) continue;
        // SHIFT goes down a frame before the key and up a frame after, as typed: pressed together, the
        // BIOS can scan the key's row before it sees SHIFT (in 80 columns the CPU gets fewer cycles).
        if (k.shift) ps2_schedule.insert({f ? f - 1 : 0, {PS2_LSHIFT, false, true}});
        ps2_schedule.insert({f, {k.code, k.extended, true}});
        ps2_schedule.insert({f + opt.type_press, {k.code, k.extended, false}});
        if (k.shift) ps2_schedule.insert({f + opt.type_press + 1, {PS2_LSHIFT, false, false}});
        if (ctrl) {
            ps2_schedule.insert({f ? f - 1 : 0, {PS2_LCTRL, false, true}});
            ps2_schedule.insert({f + opt.type_press + 1, {PS2_LCTRL, false, false}});
        }
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
    top->pcg_on = opt.pcg;
    top->model = opt.model;
    top->n_mode = opt.n_mode;
    top->v2 = opt.v2;
    top->kbd_us = opt.kbd_us;
    top->joy = 0;
    top->joy_cfg = opt.joy_cfg;
    top->overlay = opt.overlay;
    // the MiSTer's RTC as Main sends it: 2026-11-03 (Tuesday) 12:00:00, BCD; bit 64 toggled
    top->rtc[0] = 0x03120000;      // day 03, hours 12, minutes 00, seconds 00
    top->rtc[1] = 0x00022611;      // weekday 2, year 26, month 11
    top->rtc[2] = 1;
    top->tape_turbo = opt.tape_turbo;
    top->tape_rewind = 0;
    top->reset = 1;
    top->ps2_key = 0;
    for (int i = 0; i < 16; i++) clock();
    if (opt.main_gap >= 0) top->reset = 0;
    if (!load_rom()) return 2;
    if (opt.main_gap >= 0) for (int i = 0; i < opt.main_gap; i++) clock();
    if (opt.model == 1 || opt.main_gap >= 0) {
        // boot1.rom as Main loads it after boot.rom (ioctl index 40h): n80_2.rom (32 KB) + kanji1.rom (128 KB)
        std::vector<uint8_t> b, k;
        if (!read_file(opt.mk2_dir + "/n80_2.rom", b) || !read_file(opt.mk2_dir + "/kanji1.rom", k)) {
            fprintf(stderr, "cannot read %s/n80_2.rom, kanji1.rom\n", opt.mk2_dir.c_str()); return 2;
        }
        b.resize(0x8000, 0xFF);
        b.insert(b.end(), k.begin(), k.end());
        ioctl_load(0, b, 0x40);
        if (!opt.quiet) fprintf(stderr, "[sim] boot1.rom: '%s' n80_2.rom + kanji1.rom\n", opt.mk2_dir.c_str());
    }
    if (opt.main_gap >= 0) for (int i = 0; i < opt.main_gap; i++) clock();
    if (opt.model == 2 || opt.main_gap >= 0) {
        // boot2.rom (ioctl index 80h): n80_2sr.rom at 0, n80_3.rom at 8000h, font80sr.rom at 12000h, kanji1.rom
        // at 20000h (tools/make_boot2_rom.sh)
        std::vector<uint8_t> a, n3, f, k;
        const std::string &d = opt.sr_dir;
        if (!read_file(d + "/n80_2sr.rom", a) || !read_file(d + "/n80_3.rom", n3) || !read_file(d + "/font80sr.rom", f) ||
            !read_file(d + "/kanji1.rom", k)) {
            fprintf(stderr, "cannot read %s/n80_2sr.rom, n80_3.rom, font80sr.rom, kanji1.rom\n", d.c_str()); return 2;
        }
        std::vector<uint8_t> b(0x20000, 0xFF);
        std::copy(a.begin(), a.begin() + std::min<size_t>(a.size(), 0x8000), b.begin());
        std::copy(n3.begin(), n3.begin() + std::min<size_t>(n3.size(), 0xA000), b.begin() + 0x8000);
        std::copy(f.begin(), f.begin() + std::min<size_t>(f.size(), 0x1000), b.begin() + 0x12000);
        b.insert(b.end(), k.begin(), k.end());
        ioctl_load(0, b, 0x80);
        if (!opt.quiet) fprintf(stderr, "[sim] boot2.rom: '%s'\n", d.c_str());
    }
    if (!opt.ext_rom.empty()) {
        std::vector<uint8_t> e;
        if (!read_file(opt.ext_rom, e)) { fprintf(stderr, "cannot read %s\n", opt.ext_rom.c_str()); return 2; }
        ioctl_load(0, e, 2);
        if (!opt.quiet) fprintf(stderr, "[sim] expansion ROM: '%s', %zu bytes\n", opt.ext_rom.c_str(), e.size());
    }
    if (!opt.printer.empty() && !(fprn = fopen(opt.printer.c_str(), "wb"))) { perror(opt.printer.c_str()); return 2; }
    for (int d = 0; d < 2; d++) {
        if (opt.disk_file[d].empty()) continue;
        if (!read_file(opt.disk_file[d], disks[d])) { fprintf(stderr, "cannot read disk %s\n", opt.disk_file[d].c_str()); return 2; }
        disk_mount(d);
        if (!opt.quiet) fprintf(stderr, "[sim] drive %d: '%s', %zu bytes\n", d + 1, opt.disk_file[d].c_str(), disks[d].size());
    }
    for (int i = 0; i < 16; i++) clock();
    top->reset = 0;
    fb.clear(); fb_h = 0; line.clear(); prev_hb = prev_vb = false; started = true;

    if (!opt.tape_file.empty()) {
        std::vector<uint8_t> t;
        if (!read_file(opt.tape_file, t)) { fprintf(stderr, "cannot read tape %s\n", opt.tape_file.c_str()); return 2; }
        // Main puts the extension's place in the F1 list ("CMTT88CAS") in index bits 7:6
        std::string ext = opt.tape_file.substr(opt.tape_file.find_last_of('.') + 1);
        for (auto &c : ext) c = (char)tolower((unsigned char)c);
        ioctl_load(0, t, ext == "t88" ? 0x41 : ext == "cas" ? 0x81 : 0x01);
        if (!opt.quiet) fprintf(stderr, "[sim] tape: '%s', %zu bytes\n", opt.tape_file.c_str(), t.size());
    }
    for (auto &t : opt.types) schedule_text(t.frame, t.text);
    auto range = ps2_schedule.equal_range(frame);
    for (auto it = range.first; it != range.second; ++it) ps2_queue.push_back(it->second);

    std::vector<uint8_t> n80;
    if (!opt.n80_file.empty() && !read_file(opt.n80_file, n80)) { fprintf(stderr, "cannot read %s\n", opt.n80_file.c_str()); return 2; }
    tswaps = opt.tape_swaps;
    while (frame <= opt.stop_frame && !done && !Verilated::gotFinish()) {
        clock();
        for (auto &j : opt.joys) if (frame == j.first && top->joy != j.second) {
            top->joy = j.second;
            if (!opt.quiet) fprintf(stderr, "[sim] frame %u: joystick %03X\n", frame, j.second);
        }
        for (auto &j : joys_late) if (frame == j.first && top->joy != j.second) {
            top->joy = j.second;
            if (!opt.quiet) fprintf(stderr, "[sim] frame %u: joystick %03X\n", frame, j.second);
        }
        if (!tswaps.empty() && frame >= tswaps.begin()->first) {
            std::string f = tswaps.begin()->second;
            tswaps.erase(tswaps.begin());
            std::vector<uint8_t> t;
            if (!read_file(f, t)) { fprintf(stderr, "cannot read tape %s\n", f.c_str()); return 2; }
            std::string ext = f.substr(f.find_last_of('.') + 1);
            for (auto &c : ext) c = (char)tolower((unsigned char)c);
            ioctl_load(0, t, ext == "t88" ? 0x41 : ext == "cas" ? 0x81 : 0x01);
            if (!opt.quiet) fprintf(stderr, "[sim] frame %u: tape '%s' mounted, %zu bytes\n", frame, f.c_str(), t.size());
        }
        if (!n80.empty() && frame >= opt.n80_frame) {
            ioctl_load(0, n80, 3);
            if (!opt.quiet) fprintf(stderr, "[sim] memory image: '%s', %zu bytes at frame %u\n", opt.n80_file.c_str(), n80.size(), frame);
            n80.clear();
        }
    }
    if (opt.tape_end_stop) {
        char name[1024];
        snprintf(name, sizeof(name), "%s/last.png", out_dir.c_str());
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
    const std::vector<uint8_t> &disk = disks[0];
    if (!opt.disk_out.empty() && !disk.empty()) {
        FILE *fd = fopen(opt.disk_out.c_str(), "wb");
        if (!fd) perror(opt.disk_out.c_str());
        else { fwrite(disk.data(), 1, disk.size(), fd); fclose(fd); }
        if (!opt.quiet) fprintf(stderr, "[sim] disk written to '%s'%s\n", opt.disk_out.c_str(), disk_written ? "" : " (unchanged)");
    }
    wav_close();
    if (flog) fclose(flog);
    for (pid_t c : children) { int st; waitpid(c, &st, 0); }
    if (ftrace) fclose(ftrace);
    if (fio) fclose(fio);
    if (fprn) fclose(fprn);
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
