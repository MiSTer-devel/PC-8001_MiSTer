import sys, os, re, shutil
sys.path.insert(0, '/Users/alans/dev2/PC-8001_MiSTer/tools')
import tape_db as T
survey, pack, out = sys.argv[1:4]; rx = sys.argv[4] if len(sys.argv) > 4 else r'@Commercial/80|@Demo|@Unidentified'
font = '/Users/alans/dev2/PC-8001_MiSTer/runs/cscp_font/font/font.txt'
os.makedirs(out, exist_ok=True); n = 0
for l in open(survey):
    st, rel, _ = l.rstrip('\n').split('\t', 2)
    if st != 'NEW' or not re.search(rx, rel): continue
    p = os.path.join(pack, rel); d = T.data_bytes(p); fl = T.files(d)
    dd = os.path.join(out, '%03d' % n); n += 1; os.makedirs(dd, exist_ok=True)
    ext = rel.rsplit('.', 1)[1].lower().replace('cas', 'cmt')
    shutil.copy(p, os.path.join(dd, 't0.' + ext))
    w = len(d) * 12 // 10 + 600
    s = ['font ' + font, 'timeout 200000', 'frames 300', 'tape t0.' + ext]
    if fl and fl[0][0] == 'B':
        name = fl[0][3].replace('\x00', '').rstrip()
        s += ['line CLOAD"%s"' % name, 'frames %d' % w, 'shot l.png', 'text l.txt', 'line RUN', 'frames %d' % w]
    else:
        s += ['line MON', 'frames 30', 'line L', 'frames %d' % w, 'shot l.png', 'text l.txt', 'frames 600']
    s += ['shot b.png', 'text b.txt', 'frames 1200', 'shot c.png']
    open(os.path.join(dd, 'script.txt'), 'w').write('\n'.join(s) + '\n')
    open(os.path.join(dd, 'title.txt'), 'w').write(rel + '\n')
print(n)
