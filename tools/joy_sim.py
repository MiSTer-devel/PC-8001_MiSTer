#!/usr/bin/env python3
"""Joystick check of the tape titles in the headless sim (OSD Joystick = Auto): does each game react to the pad?

For each title of tools/tape_db.txt (one tape; not pc88 / fails) one sim run, copied at the load's end (sim --fork):
  base: load with the hint's steps; past the load's end (sim LOADEND) hold A, Start, A 90 frames each (start), nothing more
  dirs: as base, then hold right, left, up, down in turn
  btns: as base, then press A, B, C in turn (24 frames on, 6 off, over each input's window)
The sim is deterministic, so the first frame where dirs / btns differ from base is the first input the game
reacted to. Writes OUT/TITLE/ (base frame log), OUT/TITLE/{dirs,btns}/ (frame log, frames of the window), OUT/TITLE/sheet.png
(dirs then btns) and OUT/report.md.

  tools/joy_sim.py --pack refs/software/tape_pack/80 --out runs/joysim [--only REGEX] [--jobs 12]
"""
import argparse, os, re, subprocess, sys, concurrent.futures as cf

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tape_db as T

VTOP = os.path.join(HERE, '..', 'verilator', 'obj_dir_headless', 'Vtop')
BITS = {'right': 1, 'left': 2, 'down': 4, 'up': 8, 'a': 0x10, 'b': 0x20, 'c': 0x40}
HOLD, GAP = 60, 60          # frames an input is held, frames between inputs
START = 300                 # past the load's end: A, Start, A held 90 frames each from here (start)
FIRST = START + 600         # first test input
GROUPS = {'dirs': ['right', 'left', 'up', 'down'], 'btns': ['a', 'b', 'c']}
END = FIRST + 4 * (HOLD + GAP)


def sim_text(step):
    if step.startswith(T.MSG):
        return ''
    return T.keys(step).replace('{CTRL}B', '{CTRL+B}')


def sim_args(t, extra):
    tp = t['tapes'][0]
    z = tp['all']
    a = [VTOP, '--tape', os.path.abspath(tp['path']), '--tape-turbo', '--stop-at-frame', '40000']
    if 'mk2' in t['flags']:
        a.append('--mk2')
    if 'mk2n' in t['flags']:
        a += ['--mk2', '--n-mode']
    if 'pcg' in t['flags']:
        a.append('--pcg')
    if z.get(0):
        a += ['--type', '300:' + ''.join(sim_text(s) for s in z[0])]
    last = max(z) if z else 0
    for k in range(1, last + 1):
        a += ['--after-motor', ''.join(sim_text(s) for s in z.get(k, []))]
    w = t.get('wait', 0)
    for f, b in ((START, 0x10), (START + 100, 0x80), (START + 200, 0x10)):   # start: A, Start (Return: Door Door), A
        a += ['--joy-rel', '%d:%x' % (w + f, b), '--joy-rel', '%d:0' % (w + f + 90)]
    return a + extra + ['--stop-rel', str(w + END + 30)]


def run(t, d):
    """one sim process: the base run in D, its copies at the load's end (sim --fork) in D/dirs and D/btns"""
    os.makedirs(d, exist_ok=True)
    w = t.get('wait', 0)
    extra = ['--frame-log', os.path.join(d, 'frames.csv'), '--out', d, '--quiet', '--dump-every', '10']
    for kind, names in GROUPS.items():
        js = []
        for i, n in enumerate(names):
            f = w + FIRST + i * (HOLD + GAP)
            if kind == 'btns':      # pressed 24 frames, released 6, over hold and gap: a game busy for a moment still gets presses
                for k in range(0, HOLD + GAP - 6, 30):
                    js += ['%d:%x' % (f + k, BITS[n]), '%d:0' % (f + k + 24)]
            else:
                js += ['%d:%x' % (f, BITS[n]), '%d:0' % (f + HOLD)]
        extra += ['--fork', kind + ':' + ','.join(js)]
    r = subprocess.run(sim_args(t, extra), capture_output=True, text=True, cwd=os.path.dirname(VTOP) + '/..')
    with open(os.path.join(d, 'sim.log'), 'w') as fh:
        fh.write(r.stdout + r.stderr)
    for fn in os.listdir(d):      # the base run's frames are not needed
        if fn.startswith('frame_'):
            os.remove(os.path.join(d, fn))
    m = re.search(r'LOADEND frame=(\d+)', r.stdout)
    return int(m.group(1)) if m else None


def hashes(path):
    h = {}
    for line in open(path):
        p = line.strip().split(',')
        if p[0].isdigit():
            h[int(p[0])] = p[1]
    return h


def first_diff(base, other, frm):
    for f in sorted(other):
        if f >= frm and f in base and base[f] != other[f]:
            return f
    return None


def which(t, kind, le, f):
    """the input whose window (its hold and the gap after it) holds frame f"""
    if f is None:
        return '-'
    rel = f - le - t.get('wait', 0) - FIRST
    if rel < 0:
        return 'before'
    i = rel // (HOLD + GAP)
    names = GROUPS[kind]
    return '%s+%d' % (names[i], rel % (HOLD + GAP)) if i < len(names) else 'after'


def sheet(dirp, le, t):
    """dirs then btns: a frame every 30 over the input window"""
    w = t.get('wait', 0)
    pics = []
    for kind in ('dirs', 'btns'):
        n = len(GROUPS[kind])
        for f in range(le + w + FIRST - 20, le + w + FIRST + n * (HOLD + GAP), 30):
            f10 = f - f % 10
            p = os.path.join(dirp, kind, 'frame_%06d.png' % f10)
            if os.path.exists(p):
                pics.append(p)
    if not pics:
        return None
    lst = os.path.join(dirp, 'sheet.txt')
    with open(lst, 'w') as fh:
        for p in pics:
            fh.write("file '%s'\n" % os.path.abspath(p))
    out = os.path.join(dirp, 'sheet.png')
    subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', lst,
                    '-vf', 'scale=320:200,tile=8x%d' % ((len(pics) + 7) // 8), '-frames:v', '1', out])
    # keep only the frames of the input windows
    for kind in ('dirs', 'btns'):
        for fn in os.listdir(os.path.join(dirp, kind)):
            if fn.startswith('frame_') and int(fn[6:12]) < le + w + START - 30:
                os.remove(os.path.join(dirp, kind, fn))
    return out


def check(t, out):
    name = re.sub(r'[^A-Za-z0-9]+', '_', t['title']).strip('_')
    d = os.path.abspath(os.path.join(out, name))
    le = run(t, d)
    row = {'title': t['title'], 'dir': name, 'loadend': le, 'joy': t.get('joy')}
    if le is None:
        row['note'] = 'no load end'
        return row
    b = hashes(os.path.join(d, 'frames.csv'))
    for kind in ('dirs', 'btns'):
        o = hashes(os.path.join(d, kind, 'frames.csv'))
        f = first_diff(b, o, le)
        row[kind] = which(t, kind, le, f)
    # does the game change the screen on its own over the input window (base)?
    w = t.get('wait', 0)
    win = [b.get(f) for f in range(le + w + FIRST, le + w + END)]
    row['still'] = len(set(win)) <= 1
    row['sheet'] = sheet(d, le, t)
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--pack', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--only')
    ap.add_argument('--jobs', type=int, default=12)
    ap.add_argument('--db')
    args = ap.parse_args()
    titles = T.load(argparse.Namespace(pack=args.pack, db=args.db))
    sel = [t for t in titles if len(t['tapes']) == 1 and not (t['flags'] & {'pc88', 'fails'})
           and (not args.only or re.search(args.only, t['title'], re.I))]
    print('%d titles' % len(sel), flush=True)
    rows = []
    with cf.ThreadPoolExecutor(args.jobs) as ex:
        futs = {ex.submit(check, t, args.out): t for t in sel}
        for f in cf.as_completed(futs):
            r = f.result()
            rows.append(r)
            print('%-28s loadend %-6s dirs %-12s btns %-12s %s' % (r['title'], r['loadend'], r.get('dirs'),
                  r.get('btns'), r.get('note', '')), flush=True)
    rows.sort(key=lambda r: r['title'].lower())
    with open(os.path.join(args.out, 'report.md'), 'w') as fh:
        fh.write('# Joystick (Auto) in the sim: first input each game reacted to\n\n')
        fh.write('dirs: right, left, up, down held %d frames each; btns: A, B, C. "-": no reaction; '
                 'name+N: N frames into that input. Start: A, Start, A held 90 frames each past the load\'s end.\n\n' % HOLD)
        fh.write('| title | Auto map | load end | dirs | btns | screen still | note |\n|---|---|---|---|---|---|---|\n')
        for r in rows:
            fh.write('| %s | %s | %s | %s | %s | %s | %s |\n' % (
                r['title'], 'yes' if r['joy'] else 'default', r['loadend'], r.get('dirs', ''), r.get('btns', ''),
                'yes' if r.get('still') else '', r.get('note', '')))
    print(os.path.join(args.out, 'report.md'))


if __name__ == '__main__':
    main()
