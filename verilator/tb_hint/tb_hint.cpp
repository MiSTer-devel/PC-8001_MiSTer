// tb_hint SCRIPT: rtl/tape_hint.sv alone, driven by a script from tools/tape_db.py --tb (one command a line):
//   title NAME          name for the report
//   tape FILE           download FILE (index 1; 41h for .t88) and mount it
//   pos N               the player's position (image offset)
//   motor               the motor on for a few clocks, then off (a load has run)
//   ret | ctrlb         a Return / Ctrl+B key press and release
//   expect TEXT         the hint now: TYPE ... with <ret> for the Return arrow, trailing spaces cut; (none)
//   machine N | -       the last tape was found in the table, its machine N (0-3); - : not found (no pulse)
// Prints each failed expect and a summary; exit 1 on any failure.
// Build: verilator --cc --exe --build -I../../rtl ../../rtl/tape_hint.sv tb_hint.cpp --top-module tape_hint -o tb_hint
#include "Vtape_hint.h"
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

static Vtape_hint *t;
static bool toggle = false;
static int mpulses = 0;             // machine_v pulses since the last tape command

static void step(int n = 1)
{
	for (int i = 0; i < n; i++) { t->clk = 0; t->eval(); t->clk = 1; t->eval(); if (t->machine_v) mpulses++; }
}

static void key(int code, bool press)
{
	toggle = !toggle;
	t->ps2_key = (toggle << 10) | (press << 9) | code;
	step(4);
}

static std::string hint()
{
	if (!t->show) return "(none)";
	std::string h;
	for (int i = 0; i < 22; i++) {
		int lo = 175 - 8 * i - 7;
		uint8_t c = 0;
		for (int b = 0; b < 8; b++) if ((t->text[(lo + b) / 32] >> ((lo + b) % 32)) & 1) c |= 1 << b;
		h += c == 1 ? std::string("<ret>") : std::string(1, (char)c);
	}
	while (!h.empty() && h.back() == ' ') h.pop_back();
	return h;
}

int main(int argc, char **argv)
{
	if (argc < 2) { fprintf(stderr, "usage: tb_hint SCRIPT\n"); return 2; }
	std::ifstream in(argv[1]);
	t = new Vtape_hint;
	step(10);
	std::string line, title;
	int fails = 0, checks = 0, n = 0;
	while (std::getline(in, line)) {
		n++;
		std::string cmd = line.substr(0, line.find(' ')), arg = line.find(' ') == std::string::npos ? "" : line.substr(line.find(' ') + 1);
		if (cmd == "title") title = arg;
		else if (cmd == "tape") {
			FILE *f = fopen(arg.c_str(), "rb");
			if (!f) { fprintf(stderr, "cannot read %s\n", arg.c_str()); return 2; }
			std::vector<uint8_t> d; int c; while ((c = fgetc(f)) != EOF) d.push_back(c); fclose(f);
			std::string ext = arg.substr(arg.find_last_of('.') + 1);
			for (auto &e : ext) e = tolower(e);
			t->loaded = 0;
			mpulses = 0;
			t->ioctl_index = ext == "t88" ? 0x41 : 0x01;
			t->ioctl_download = 1; step(2);
			for (size_t i = 0; i < d.size(); i++) {
				t->ioctl_addr = i; t->ioctl_dout = d[i]; t->ioctl_wr = 1; step(); t->ioctl_wr = 0; step(2);
			}
			t->ioctl_download = 0; step(4);
			t->loaded = 1; t->position = 0;
			step(600);                        // the scan closes, the table lookup runs
		}
		else if (cmd == "pos") { t->position = std::stoul(arg); step(20); }
		else if (cmd == "motor") { t->motor = 1; step(4); t->motor = 0; step(20); }
		else if (cmd == "ret") { key(0x5A, true); key(0x5A, false); step(20); }
		else if (cmd == "ctrlb") { key(0x14, true); key(0x32, true); key(0x32, false); key(0x14, false); step(20); }
		else if (cmd == "machine") {
			checks++;
			std::string got = mpulses == 0 ? "-" : mpulses == 1 ? std::to_string((int)t->machine) : "pulses " + std::to_string(mpulses);
			if (got != arg) { fails++; printf("FAIL %s (line %d): machine expected %s, got %s\n", title.c_str(), n, arg.c_str(), got.c_str()); }
		}
		else if (cmd == "expect") {
			checks++;
			std::string h = hint();
			if (h != arg) { fails++; printf("FAIL %s (line %d): expected '%s', got '%s'\n", title.c_str(), n, arg.c_str(), h.c_str()); }
		}
		else if (!cmd.empty() && cmd[0] != '#') { fprintf(stderr, "line %d: unknown command %s\n", n, cmd.c_str()); return 2; }
	}
	printf("%d checks, %d failed\n", checks, fails);
	return fails ? 1 : 0;
}
