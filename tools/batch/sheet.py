import sys,os,subprocess
# sheet.py OUTDIR SHOT DIR... : 12 frames a sheet (4x3, 320x200 each); SUB=o picks each DIR's output folder
out,shot=sys.argv[1],sys.argv[2]; dirs=[d for d in sys.argv[3:] if os.path.exists(os.path.join(d,os.environ.get('SUB','out'),shot))]
os.makedirs(out,exist_ok=True)
for n in range(0,len(dirs),12):
    g=dirs[n:n+12]; g2=g+[g[0]]*(12-len(g))
    args=['ffmpeg','-loglevel','error','-y']
    for d in g2: args+=['-i',os.path.join(d,os.environ.get('SUB','out'),shot)]
    f=';'.join('[%d]scale=320:200[a%d]'%(i,i) for i in range(12))
    lay='|'.join('%d_%d'%(320*(i%4),200*(i//4)) for i in range(12))
    f+=';'+''.join('[a%d]'%i for i in range(12))+'xstack=inputs=12:layout=%s[v]'%lay
    p=os.path.join(out,'s%02d.png'%(n//12))
    subprocess.run(args+['-filter_complex',f,'-map','[v]',p],check=True)
    print(p,' '.join(os.path.basename(d.rstrip('/')) for d in g))
