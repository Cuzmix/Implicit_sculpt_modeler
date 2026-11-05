"""Quality numbers for an OBJ: face sizes, quad share, valence, edges (boundary, non-manifold), Euler, bounds, sphere deviation."""
import sys, math, collections
def load(p):
    V=[];F=[]
    for line in open(p, errors="replace"):
        if line.startswith("v "): V.append(tuple(float(x) for x in line.split()[1:4]))
        elif line.startswith("f "):
            idx=[]
            for tok in line.split()[1:]:
                i=int(tok.split("/")[0]); idx.append(i-1 if i>0 else len(V)+i)
            F.append(idx)
    return V,F
def main(p, sphere=False):
    V,F=load(p)
    sizes=collections.Counter(len(f) for f in F)
    quads=sizes.get(4,0)
    val=collections.Counter()
    edges=collections.Counter(); directed=collections.Counter()
    degenerate=0
    for f in F:
        if len(set(f))!=len(f): degenerate+=1
        for k in range(len(f)):
            a,b=f[k],f[(k+1)%len(f)]
            val[a]+=1 if k==0 else 0
            edges[(min(a,b),max(a,b))]+=1; directed[(a,b)]+=1
    # valence = number of edges at a vertex
    vval=collections.Counter()
    for (a,b),c in edges.items(): vval[a]+=1; vval[b]+=1
    vh=collections.Counter(vval.values())
    nv=len(V); used=len(vval)
    boundary=sum(1 for c in edges.values() if c==1); nonman=sum(1 for c in edges.values() if c>2)
    inconsistent=sum(1 for (a,b),c in directed.items() if c>1)
    euler=used-len(edges)+len(F)
    dev=""
    if sphere:
        r=[abs(math.sqrt(x*x+y*y+z*z)-1) for x,y,z in V]; dev=" sphere_max_dev=%.4f sphere_mean_dev=%.5f"%(max(r),sum(r)/len(r))
    v4=vh.get(4,0)
    print("%s: V=%d F=%d quads=%d (%.1f%%) tris=%d ngon5+=%d degenerate=%d E=%d boundary=%d nonmanifold=%d inconsistent=%d euler=%d unused_v=%d valence4=%.1f%% val3=%d val5=%d val6+=%d%s" % (
        p.split("/")[-1], nv, len(F), quads, 100.0*quads/max(1,len(F)), sizes.get(3,0), sum(c for s,c in sizes.items() if s>=5), degenerate, len(edges), boundary, nonman, inconsistent, euler, nv-used,
        100.0*v4/max(1,used), vh.get(3,0), vh.get(5,0), sum(c for v,c in vh.items() if v>=6), dev))
if __name__=="__main__":
    for p in sys.argv[1:]:
        if p=="--sphere": continue
        main(p, sphere="--sphere" in sys.argv)
