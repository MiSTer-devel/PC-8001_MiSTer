#!/usr/bin/env python3
# SR N80SR-mode graphics tests (tools/cscp_suite.sh srg*): prints machine code (at C000h) as hex that fills the
# planes (5Ch B: the address's low byte, 5Dh R: low ^ high, 5Eh G: high rotated left twice), optionally sets
# the palette 54h-5Bh to colour 7-i, then sets 53h, 33h, 31h and spins with interrupts off.
#   tools/srg_asm.py P31 P33 P53 [rev]      (hex values)
import sys
p31, p33, p53 = (int(x, 16) for x in sys.argv[1:4])
rev = len(sys.argv) > 4 and sys.argv[4] == 'rev'
c = [0xF3]
for port, op in ((0x5C, [0x7D]), (0x5D, [0x7D, 0xAC]), (0x5E, [0x7C, 0x07, 0x07])):
    c += [0xD3, port, 0x21, 0x00, 0x80, 0x01, 0x00, 0x40]   # OUT (port),A; LD HL,8000h; LD BC,4000h
    loop = len(c)
    c += op + [0x77, 0x23, 0x0B, 0x78, 0xB1]              # op; LD (HL),A; INC HL; DEC BC; LD A,B; OR C
    c += [0x20, (loop - (len(c) + 2)) & 0xFF]             # JR NZ,loop
c += [0xD3, 0x5F]
if rev:
    for i in range(8):
        c += [0x3E, 7 - i, 0xD3, 0x54 + i]
c += [0x3E, p53, 0xD3, 0x53, 0x3E, p33, 0xD3, 0x33, 0x3E, p31, 0xD3, 0x31, 0x18, 0xFE]
print(''.join('%02X' % x for x in c))
