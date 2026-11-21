import sys, os, re
sys.path.insert(0, '/Users/alans/dev2/PC-8001_MiSTer/tools')
import tape_db as T
pack = sys.argv[1]; typeins = sys.argv[2]
titles = T.parse('/Users/alans/dev2/PC-8001_MiSTer/tools/tape_db.txt')
known = {}
for t in titles:
    for tp in t['tapes']:
        p = os.path.join(typeins, tp['file'])
        d = T.data_bytes(p); known[(len(d), T.crc16(d))] = t['title']
# also every tape in refs/software and the tester set: seen before
seen = {}
for base in ['/Users/alans/dev2/PC-8001_MiSTer/refs/software', typeins]:
    for r, _, fs in os.walk(base):
        for f in fs:
            if re.search(r'\.(t88|cmt|cas)$', f, re.I):
                try: d = T.data_bytes(os.path.join(r, f)); seen[(len(d), T.crc16(d))] = os.path.join(r, f)
                except Exception: pass
rows = []
for r, _, fs in os.walk(pack):
    if '__MACOSX' in r: continue
    for f in sorted(fs):
        if not re.search(r'\.(t88|cmt|cas)$', f, re.I): continue
        p = os.path.join(r, f); rel = os.path.relpath(p, pack)
        try:
            d = T.data_bytes(p); fl = T.files(d)
        except Exception as e:
            rows.append(('ERR', rel, str(e))); continue
        k = (len(d), T.crc16(d))
        st = 'DB' if k in known else 'SEEN' if k in seen else 'NEW'
        z = T.default_zones(fl)
        hint = ' | '.join('%d: %s' % (zz, ' / '.join(l for l, _ in T.lines_of(v)) or '-') for zz, v in sorted(z.items())).replace('\x01', '<ret>')
        fls = ' '.join(('B"%s"' % x if kk == 'B' else 'M%04X' % x) for kk, _, _, x in fl)
        rows.append((st, rel, fls[:40] + '  ' + hint))
for row in sorted(rows): print('\t'.join(row))
