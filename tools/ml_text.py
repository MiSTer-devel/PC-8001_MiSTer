#!/usr/bin/env python3
# The BASIC text typed by the machine-code tests: hex (stdin) poked at C000h from strings of up to 150 hex
# digits (BASIC lines and strings are short), then USR. Prints it with \n escapes for tools/cscp_cmp.sh.
import sys
h = sys.stdin.read().strip()
parts = [h[i:i + 150] for i in range(0, len(h), 150)]
lines = []
n = 10
off = 0
for p in parts:
    lines.append('%d a$="%s":for i=0 to len(a$)/2-1:poke &h%x+i,val("&h"+mid$(a$,i*2+1,2)):next' % (n, p, 0xC000 + off))
    off += len(p) // 2
    n += 10
lines.append('%d def usr=&hc000:a=usr(0)' % n)
lines.append('run')
print('\\n'.join(lines) + '\\n', end='')
