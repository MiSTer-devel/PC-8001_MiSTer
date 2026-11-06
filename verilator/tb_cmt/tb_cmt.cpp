// tb_cmt FILE.t88|FILE.cmt OUT: load the tape, play it with the motor on, write the bytes sent to the 8251 to OUT
#include "Vtb_cmt.h"
#include <cstdio>
#include <cstring>
#include <vector>
static Vtb_cmt *t;
static uint64_t clk_n = 0;
static void step() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); clk_n++; t->other_rd = (clk_n % 37) == 0; }
int main(int argc, char **argv)
{
	if (argc < 3) { fprintf(stderr, "usage: tb_cmt TAPE OUT\n"); return 2; }
	FILE *f = fopen(argv[1], "rb"); if (!f) return 2;
	std::vector<uint8_t> d; int c; while ((c = fgetc(f)) != EOF) d.push_back(c); fclose(f);
	bool t88 = strstr(argv[1], ".t88") != nullptr;
	t = new Vtb_cmt;
	for (int i = 0; i < 10; i++) step();
	t->ioctl_index = t88 ? 0x41 : 0x01; t->ioctl_download = 1;
	for (size_t i = 0; i < d.size(); i++) {
		t->ioctl_addr = i; t->ioctl_dout = d[i]; t->ioctl_wr = 1; step(); t->ioctl_wr = 0;
		step(); step(); step(); while (t->ioctl_wait) step();
	}
	t->ioctl_download = 0; step(); step();
	fprintf(stderr, "loaded %zu bytes: length %u\n", d.size(), (unsigned)t->length);
	t->motor = 1;
	FILE *o = fopen(argv[2], "wb"); size_t n = 0; uint64_t idle = 0;
	while (idle < 20000000) {
		step();
		if (t->rx_stb) { fputc(t->rx_byte, o); n++; idle = 0; } else idle++;
	}
	fclose(o);
	fprintf(stderr, "%zu bytes out, position %u, %llu clocks\n", n, (unsigned)t->position, (unsigned long long)clk_n);
	return 0;
}
