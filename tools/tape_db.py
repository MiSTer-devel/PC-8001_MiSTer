#!/usr/bin/env python3
# Tape hint database (tools/tape_db.txt): the core's table and test scripts.
#   tools/tape_db.py --pack DIR --list                 each tape: files, fingerprint, the hint per zone
#   tools/tape_db.py --pack DIR --svh rtl/tape_db.svh  the table rtl/tape_hint.sv includes
#   tools/tape_db.py --pack DIR --cscp OUT --font F [--all]   one CSCP script per title in OUT/<n>/ (--all:
#                                                      also every other tape in the pack, with the core's own hint)
#   tools/tape_db.py --pack DIR --tb FILE [--all [--also DIR2]]   the script for verilator/tb_hint (each tape's
#                                                      hint at its start and past each file, line by line)
#   tools/tape_db.py --pack DIR --readme               one line per title: how to load and start it
#   --db FILE: another database (experiments); --only FILE: only the titles listed in FILE
# DIR holds the tapes under the paths tape_db.txt names (Danjuro's type-in pack). Run with python3 -I.
import argparse, os, re, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
W = 17                      # characters after "TYPE " in the 22-character box

# ---------------------------------------------------------------------------------------------------------
# tapes, as rtl/tape_hint.sv reads them

def data_map(path):
    """the bytes the 8251 gets (a .cmt whole; a .t88's data tags after their 12-byte header) and each one's
    offset in the image (the player's position)"""
    b = open(path, 'rb').read()
    if not path.lower().endswith('.t88'):
        return b, list(range(len(b)))
    out = bytearray(); offs = []; i = 24
    while i + 4 <= len(b):
        tid = b[i] | b[i + 1] << 8; ln = b[i + 2] | b[i + 3] << 8; i += 4
        if tid == 0 and ln == 0:
            break
        if tid == 0x101:
            out += b[i + 12:i + ln]; offs += range(i + 12, i + ln)
        i += ln
    return bytes(out), offs

def data_bytes(path):
    return data_map(path)[0]

def printable(c):
    return 0x20 <= c < 0x7F or c == 0

def files(d, nmax=8):
    """[(kind 'B'/'M', start, end, name or load address)], as the core's scanner finds them: a CSAVE header
    (ten D3h, a 6-byte name) and its program up to the first 00 00 00, or a monitor header (3Ah hi lo sum 3Ah)
    and its records up to the one of length 0. A first file that is neither ends the list."""
    res = []; i = 0; n = len(d)
    while i < n and len(res) < nmax:
        if d[i:i + 10] == b'\xd3' * 10:
            j = i + 10
            while j < n and d[j] == 0xD3:
                j += 1
            if not res and not (j < n and printable(d[j])):
                break
            name = d[j:j + 6]
            if len(name) < 6 or not all(printable(c) for c in name):
                break
            e = d.find(b'\x00\x00\x00', j + 6)
            if e < 0:
                break
            res.append(('B', i, e + 2, name.replace(b'\x00', b' ').decode('latin1').rstrip()))
            i = e + 3
            continue
        if i + 4 < n and d[i] == 0x3A and (d[i + 1] + d[i + 2] + d[i + 3]) & 255 == 0 and d[i + 4] == 0x3A:
            a = d[i + 1] << 8 | d[i + 2]; j = i + 4; ok = False
            while j + 1 < n and d[j] == 0x3A:
                l = d[j + 1]
                if l == 0:
                    j += 3; ok = True; break
                j += l + 3
            if not ok:
                res.append(('m', i, n - 1, a))      # no end record: the core still sees a machine-code block
                break
            res.append(('M', i, j - 1, a))
            i = j
            continue
        if not res and d[i] == 0xD3:
            pass
        i += 1
    return res

def crc16(d):
    c = 0xFFFF
    for x in d:
        c ^= x << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c

def default_zones(fl):
    """the core's own hint: zone -> steps"""
    z = {}
    if not fl:
        return z
    k, _, _, x = fl[0]
    z[0] = ['CLOAD"%s"\\n' % x] if k == 'B' else ['MON\\n L\\n']
    if k == 'B' and not (len(fl) > 1 and fl[1][0] in 'Mm'):
        z[1] = ['RUN\\n']
    return z

# ---------------------------------------------------------------------------------------------------------
# the database

def parse(path):
    titles = []; t = None; tp = None
    for raw in open(path, encoding='utf-8'):
        line = raw.rstrip('\n')
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        m = re.match(r'title:\s*(.*)$', line)
        if m:
            words = m.group(1).split()
            flags = set()
            while words and words[-1] in ('pcg', 'mk2', 'mk2n', 'pc88', 'fails'):
                flags.add(words.pop())
            name = ' '.join(words)
            t = {'title': name, 'flags': flags, 'tapes': [], 'play': '', 'wait': 0}; titles.append(t); continue
        m = re.match(r'tape:\s*(.*)$', line)
        if m:
            tp = {'file': m.group(1).strip(), 'zones': {}}; t['tapes'].append(tp); continue
        m = re.match(r'\s+(\d+):\s*(.*)$', line)
        if m:
            v = m.group(2).strip()
            tp['zones'][int(m.group(1))] = [] if v == '-' else [s.strip() for s in v.split(' ; ')]
            continue
        m = re.match(r'wait:\s*(\d+)$', line)
        if m:
            t['wait'] = int(m.group(1)); continue
        m = re.match(r'play:\s?(.*)$', line)
        if m:
            t['play'] = m.group(1); continue
        sys.exit('tape_db.txt: cannot read: ' + line)
    return titles

def shown(step):
    """a step as the box shows it: \\n -> 01h (the Return arrow), {CTRL}B -> CTRL+B"""
    s = keys(step).replace('{CTRL}B', 'CTRL+B ').replace('\\n', ' \x01 ')
    return re.sub(' +', ' ', s).strip()

def events(step):
    return step.count('\\n') + step.count('{CTRL}B')

def lines_of(steps):
    """steps -> [(text, events)]: as many steps per line as fit"""
    out = []
    for s in steps:
        txt = shown(s)
        if len(txt) > W:
            sys.exit('step too long for the box: ' + s)
        if out and len(out[-1][0]) + 1 + len(txt) <= W:
            out[-1] = (out[-1][0] + ' ' + txt, out[-1][1] + events(s))
        else:
            out.append((txt, events(s)))
    return out

def load(args):
    titles = parse(args.db or os.path.join(HERE, 'tape_db.txt'))
    for t in titles:
        for tp in t['tapes']:
            p = os.path.join(args.pack, tp['file'])
            if not os.path.exists(p):
                sys.exit('missing tape: ' + p)
            d = data_bytes(p)
            fl = files(d)
            tp['path'] = p; tp['files'] = [f for f in fl if f[0] != 'm']; tp['len'] = len(d); tp['crc'] = crc16(d)
            z = default_zones(fl); z.update(tp['zones']); tp['all'] = z
    return titles

# ---------------------------------------------------------------------------------------------------------
# outputs

def write_svh(titles, out):
    entries = []; lines = []
    seen = {}; seen_m = {}
    for t in titles:
        for tp in t['tapes']:
            key = (tp['len'], tp['crc'])
            if key in seen:
                if seen[key] != tp['all']:
                    sys.exit('same tape, different hints: ' + tp['file'])
                if seen_m[key] != (1 if 'mk2' in t['flags'] else 2 if 'mk2n' in t['flags'] else 3 if 'pc88' in t['flags'] else 0):
                    sys.exit('same tape, different machines: ' + tp['file'])
                continue
            seen[key] = tp['all']
            seen_m[key] = 1 if 'mk2' in t['flags'] else 2 if 'mk2n' in t['flags'] else 3 if 'pc88' in t['flags'] else 0
            first = len(lines)
            for zone in sorted(tp['all']):
                ls = lines_of(tp['all'][zone])
                if not ls:
                    lines.append((zone, '', 0, True))
                for i, (txt, ev) in enumerate(ls):
                    lines.append((zone, txt, ev, i == len(ls) - 1))
            f = t['flags']
            mach = 1 if 'mk2' in f else 2 if 'mk2n' in f else 3 if 'pc88' in f else 0
            entries.append((tp['len'], tp['crc'], first, len(lines) - first, mach, t['title'], tp['file']))
    if len(lines) > 1024 or len(entries) > 256:
        sys.exit('table too large')
    with open(out, 'w') as f:
        f.write('// Generated by tools/tape_db.py from tools/tape_db.txt: do not edit.\n')
        f.write('// Known tapes: data length, CRC-16 (CCITT, FFFFh) of the data bytes -> their hint lines.\n')
        f.write('/* verilator lint_off UNUSEDPARAM */\nlocalparam DB_TAPES = %d, DB_LINES = %d;\n/* verilator lint_on UNUSEDPARAM */\n\n' % (len(entries), len(lines)))
        f.write('// tape i: {len[19:0], crc[15:0], first line[9:0], lines[3:0], machine[1:0]}\n')
        f.write('// machine: 0 any, 1 the mkII in N80 mode, 2 the mkII in Mode N, 3 a PC-8801 tape (runs on no PC-8001)\n')
        f.write('function automatic [51:0] db_tape(input [7:0] i);\n\tcase (i)\n')
        for i, (ln, crc, first, cnt, mach, title, fn) in enumerate(entries):
            f.write("\t8'd%d: db_tape = {20'd%d, 16'h%04X, 10'd%d, 4'd%d, 2'd%d};   // %s: %s\n" % (i, ln, crc, first, cnt, mach, title, fn))
        f.write("\tdefault: db_tape = 0;\n\tendcase\nendfunction\n\n")
        f.write('// line j: {zone[2:0], last of its zone, events[2:0], 17 characters (01h = Return arrow)}\n')
        f.write('function automatic [142:0] db_line(input [9:0] j);\n\tcase (j)\n')
        for j, (zone, txt, ev, last) in enumerate(lines):
            chars = ''.join('%02X' % ord(c) for c in txt.ljust(W))
            f.write("\t10'd%d: db_line = {3'd%d, 1'b%d, 3'd%d, 136'h%s};   // %s\n" % (j, zone, int(last), ev, chars, txt.replace('\x01', '<ret>') or '(nothing)'))
        f.write("\tdefault: db_line = 0;\n\tendcase\nendfunction\n")
    print('%s: %d tapes, %d lines' % (out, len(entries), len(lines)))

def keys(step):
    """a step as typed (sim / CSCP --type): without the space shown after a Return"""
    return step.replace('\\n ', '\\n')

def cscp_cmds(step):
    """a step as CSCP script commands: text lines through auto key (line: any character, its Return, waits
    until typed), Ctrl+B as a scheduled key"""
    out = []
    for part in re.split(r'(\{CTRL\}B)', keys(step)):
        if part == '{CTRL}B':
            out += ['type {CTRL}B', 'frames 30']
            continue
        segs = part.split('\\n')
        for i, seg in enumerate(segs):
            seg = seg.strip()
            if i < len(segs) - 1:
                out += ['line %s' % seg, 'frames 30']
            elif seg:
                out += ['type %s' % seg, 'frames %d' % (8 * len(seg) + 30)]
    return out

def write_cscp(titles, out, font):
    os.makedirs(out, exist_ok=True)
    for n, t in enumerate(titles):
        d = os.path.join(out, '%03d' % n); os.makedirs(d, exist_ok=True)
        s = ['font %s' % os.path.abspath(font), 'timeout 40000', 'frames 300']
        for k, tp in enumerate(t['tapes']):
            fn = 't%d.%s' % (k, tp['file'].rsplit('.', 1)[1].lower().replace('cas', 'cmt'))
            shutil.copy(tp['path'], os.path.join(d, fn))
            if k:
                s.append('eject')
            s.append('tape %s' % fn)
            fl = tp['files']; pos = 0; last = ''
            for zone in sorted(tp['all']):
                if zone > 0:
                    if zone > len(fl):
                        break
                    # the load the last command started: until its prompt; a load the program does itself:
                    # CSCP plays a tape in real time (about 1.1 frames a byte), then a margin
                    if re.match(r'CLOAD', last):
                        s.append('prompt Ok')
                    elif last == 'L':
                        s.append('prompt *')
                    else:
                        s.append('frames %d' % ((fl[zone - 1][2] - pos) * 12 // 10 + 600))
                    s.append('frames 30')
                    pos = fl[zone - 1][2]
                for step in tp['all'][zone]:
                    s += cscp_cmds(step)
                    lines = [x.strip() for x in keys(step).replace('{CTRL}B', '').split('\\n') if x.strip()]
                    if lines:
                        last = lines[-1]
            s.append('shot tape%d.png' % k)
        if t['play']:
            s.append('frames 300'); s.append('type %s' % t['play'])
        if t.get('wait'):
            s.append('frames %d' % t['wait'])
        s += ['frames 300', 'shot a.png', 'frames 900', 'shot b.png', 'text b.txt']
        open(os.path.join(d, 'script.txt'), 'w').write('\n'.join(s) + '\n')
        open(os.path.join(d, 'title.txt'), 'w').write(t['title'] + (' [%s]' % ','.join(sorted(t['flags'])) if t['flags'] else '') + '\n')
    print('%s: %d titles' % (out, len(titles)))

def write_tb(titles, out):
    """the script for verilator/tb_hint: each tape's hint at its start and past each file, line by line"""
    s = []
    for t in titles:
        for tp in t['tapes']:
            known = bool(tp['zones'])
            _, offs = data_map(tp['path'])
            fl = tp['files']
            s += ['title %s: %s' % (t['title'], tp['file']), 'tape %s' % os.path.abspath(tp['path'])]
            f = t['flags']
            s.append('machine %s' % ('-' if t.get('extra') else 1 if 'mk2' in f else 2 if 'mk2n' in f else 3 if 'pc88' in f else 0))
            if 'pc88' in f:
                # the PC-8801 message instead of the steps, at the start and past each file
                s.append('expect NEEDS A PC-8801')
                for k in range(len(fl)):
                    s += ['motor', 'pos %d' % (offs[fl[k][2]] + 2), 'expect NEEDS A PC-8801']
                continue
            for zone in range(0, len(fl) + 1):
                if zone > 0:
                    s += ['motor', 'pos %d' % (offs[fl[zone - 1][2]] + 2)]
                steps = tp['all'].get(zone, [])
                ls = lines_of(steps)
                if not known and zone == 0:
                    s += ['expect TYPE %s' % ls[0][0].replace('\x01', '<ret>')] if ls else ['expect (none)']
                    continue
                for (txt, ev), step_keys in zip(ls, line_keys(steps)):
                    s.append('expect TYPE %s' % txt.replace('\x01', '<ret>'))
                    s += step_keys
                s.append('expect (none)')
    open(out, 'w').write('\n'.join(s) + '\n')
    print('%s: %d checks' % (out, sum(1 for x in s if x.startswith('expect'))))

def line_keys(steps):
    """the keys that end each shown line (Returns and Ctrl+Bs, in order)"""
    out = []
    groups = []
    for st in steps:
        txt = shown(st)
        if groups and len(groups[-1][0]) + 1 + len(txt) <= W:
            groups[-1] = (groups[-1][0] + ' ' + txt, groups[-1][1] + [st])
        else:
            groups.append((txt, [st]))
    for _, sts in groups:
        k = []
        for st in sts:
            for m in re.finditer(r'\{CTRL\}B|\\n', st):
                k.append('ctrlb' if m.group(0) == '{CTRL}B' else 'ret')
        out.append(k)
    return out

def readme_line(t):
    """a title's steps as one line for a README: Title: cload"X", run (swap tapes with "then <tape>:")"""
    parts = []
    for k, tp in enumerate(t['tapes']):
        steps = []
        for zone in sorted(tp['all']):
            for st in tp['all'][zone]:
                for x in re.split(r'(\{CTRL\}B)|\\n', keys(st)):
                    if x and x.strip():
                        steps.append('Ctrl+B' if x == '{CTRL}B' else x.strip())
        name = os.path.basename(tp['file'])
        parts.append(('%s: ' % name if len(t['tapes']) > 1 else '') + ', '.join(steps))
    flags = []
    if 'pcg' in t['flags']:
        flags.append('PCG-8100 on')
    if 'mk2' in t['flags']:
        flags.append('mkII, N80 mode: set by the core')
    if 'mk2n' in t['flags']:
        flags.append('mkII, Mode N: set by the core')
    if 'pc88' in t['flags']:
        flags.append('PC-8801 tape: does not run on any PC-8001')
    if 'fails' in t['flags']:
        flags.append('runs on no model tried, PC-8801 included')
    return '%s%s: %s' % (t['title'], ' (%s)' % ', '.join(flags) if flags else '', '; then '.join(parts))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--pack', required=True)
    ap.add_argument('--list', action='store_true')
    ap.add_argument('--svh')
    ap.add_argument('--cscp')
    ap.add_argument('--font')
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--tb')
    ap.add_argument('--readme', action='store_true', help='one line per title: how to load and start it')
    ap.add_argument('--db', help='another database file (experiments)')
    ap.add_argument('--only', help='a file of titles: only these')
    ap.add_argument('--also', help='with --all: the tapes under this directory too')
    a = ap.parse_args()
    titles = load(a)
    if a.all:
        named = set(os.path.normpath(tp['file']) for t in titles for tp in t['tapes'])
        known = set((tp['len'], tp['crc']) for t in titles for tp in t['tapes'])
        extra = []
        for base in [a.pack] + ([a.also] if a.also else []):
          for root, _, fs in os.walk(base):
            for f in sorted(fs):
                rel = os.path.normpath(os.path.relpath(os.path.join(root, f), base))
                if re.search(r'\.(t88|cmt|cas)$', f, re.I) and rel not in named and '__MACOSX' not in rel:
                    p = os.path.join(base, rel); dd = data_bytes(p); fl = files(dd)
                    if base != a.pack and (len(dd), crc16(dd)) in known:
                        continue
                    extra.append({'title': rel.rsplit('.', 1)[0], 'flags': set(), 'play': '', 'extra': True,
                                  'tapes': [{'file': rel, 'zones': {}, 'path': p, 'files': [f for f in fl if f[0] != 'm'], 'len': len(dd),
                                             'crc': crc16(dd), 'all': default_zones(fl)}]})
        titles_all = titles + sorted(extra, key=lambda t: t['title'])
    else:
        titles_all = titles
    if a.only:
        want = set(l.strip() for l in open(a.only) if l.strip())
        titles_all = [t for t in titles_all if t['title'] in want]
    if a.list:
        for t in titles_all:
            for tp in t['tapes']:
                fl = ' '.join(('B"%s"' % x if k == 'B' else 'M%04X' % x) for k, _, _, x in tp['files'])
                print('%-50s %6d %04X  %-24s %s' % (tp['file'][:50], tp['len'], tp['crc'], fl[:24],
                      ' | '.join('%d: %s' % (z, ' / '.join(l for l, _ in lines_of(v)) or '-') for z, v in sorted(tp['all'].items())).replace('\x01', '<ret>')))
    if a.svh:
        write_svh(titles, a.svh)
    if a.readme:
        for t in titles_all:
            print(readme_line(t))
    if a.tb:
        write_tb(titles_all, a.tb)
    if a.cscp:
        write_cscp(titles_all, a.cscp, a.font)

if __name__ == '__main__':
    main()
