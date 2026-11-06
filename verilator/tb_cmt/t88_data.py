#!/usr/bin/env python3
# t88_data.py FILE.t88 OUT: the bytes of every data tag (101h, after its 12-byte header), in order
import sys, struct
d = open(sys.argv[1], 'rb').read(); p = 24; out = bytearray()
while p + 4 <= len(d):
    tag, ln = struct.unpack_from('<HH', d, p); p += 4
    if tag == 0 and ln == 0: break
    if tag == 0x101 and ln > 12: out += d[p + 12:p + ln]
    p += ln
open(sys.argv[2], 'wb').write(out)
print(f"{len(out)} data bytes")
