import sys
sys.path.insert(0, '/Users/alans/dev2/PC-8001_MiSTer/tools')
import tape_db as T
for p in sys.argv[1:]:
    d = T.data_bytes(p)
    # find the first 3A hi lo cs header
    i = d.find(b'\x3a')
    hi, lo = d[i+1], d[i+2]; addr = hi*256+lo; j = i+4; recs = []; total = 0
    while j < len(d) and d[j] == 0x3a:
        n = d[j+1]
        if n == 0: j += 3; break
        recs.append(d[j+2:j+2+n]); total += n; j += 3 + n
    body = b''.join(recs)
    print(p.split('/')[-1], 'len', len(d), 'at %04X' % addr, 'block', total, 'end at', j, 'rest', len(d)-j)
    print('  ', body[:48].hex())
    print('  ', 'next:', d[j:j+24].hex())
