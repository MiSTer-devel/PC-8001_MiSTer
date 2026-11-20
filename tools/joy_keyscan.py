# tools/joy_keyscan.py DIR: per tape, the keyboard keys its Z80 code reads (IN A,(0-9) + BIT/AND) and the 1-char
# strings a BASIC program compares; a guess for tools/joy_map.md. Run with python3 -I.
import sys,os,re,collections
sys.path.insert(0,'/Users/alans/dev2/PC-8001_MiSTer/tools'); import tape_db as T
K=[['p0','p1','p2','p3','p4','p5','p6','p7'],['p8','p9','p*','p+','p=','p,','p.','RET'],['@','A','B','C','D','E','F','G'],['H','I','J','K','L','M','N','O'],
['P','Q','R','S','T','U','V','W'],['X','Y','Z','[','\\',']','^','-'],['0','1','2','3','4','5','6','7'],['8','9',':',';',',','.','/','_'],
['HOME','UP','RIGHT','INS','GRPH','KANA','SHIFT','CTRL'],['STOP','F1','F2','F3','F4','F5','SPC','ESC']]
def mc(d):
    keys=collections.Counter()
    for m in re.finditer(rb'\xdb([\x00-\x09])',d):
        r=m.group(1)[0]; w=d[m.end():m.end()+12]; got=False
        for i in range(len(w)-1):
            o=w[i]
            if o==0xcb and 0x40<=w[i+1]<0x80: keys[K[r][(w[i+1]>>3)&7]]+=1; got=True; break
            if o in (0xe6,0xee,0xfe) and i==0 or (o==0xe6): 
                for b in range(8):
                    if (w[i+1]>>b)&1==(0 if o==0xee else 1) and o==0xe6: keys[K[r][b]]+=1
                got=True; break
            if o in (0x0f,0x1f,0x07,0x17): # rotates: bit0/bit7 tested via carry
                keys[K[r][0 if o in (0x0f,0x1f) else 7]]+=1; got=True; break
        if not got: keys['row%d'%r]+=1
    return keys
def basic(d):
    s=set(re.findall(rb'"(.)"',d)); i=set(re.findall(rb'\(([0-9])\)',d))
    return ''.join(sorted(chr(c[0]) for c in s if 32<c[0]<127))
for root,_,fs in os.walk(sys.argv[1]):
    for f in sorted(fs):
        if not f.lower().endswith(('.cmt','.t88','.cas')): continue
        p=os.path.join(root,f)
        try: d=T.data_bytes(p)
        except Exception: continue
        k=mc(d); b=basic(d)
        print('%-50s | %s | %s'%(os.path.relpath(p,sys.argv[1])[:50],' '.join(x for x,_ in k.most_common()),b[:40]))
