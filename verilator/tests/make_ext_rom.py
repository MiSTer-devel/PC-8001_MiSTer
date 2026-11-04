#!/usr/bin/env python3
"""Test expansion ROM (8 KB at 6000h): "AB", then code at 6002h that copies "EXT OK" to the text VRAM (F300h)
and loops. N-BASIC calls 6002h at reset when 6000h holds "AB"."""
import sys
msg = b'EXT OK'
code = bytes([0x21, 0x10, 0x60,          # LD HL, 6010h
              0x11, 0x00, 0xF3,          # LD DE, F300h
              0x01, len(msg), 0x00,      # LD BC, len
              0xED, 0xB0,                # LDIR
              0x18, 0xFE])               # JR $
rom = b'AB' + code
rom += b'\xff' * (0x10 - len(rom)) + msg
rom += b'\xff' * (0x2000 - len(rom))
open(sys.argv[1], 'wb').write(rom)
