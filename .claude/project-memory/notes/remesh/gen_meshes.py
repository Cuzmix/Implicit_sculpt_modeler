import math, sys, os
out = sys.argv[1]
def write(name, V, F):
    with open(os.path.join(out, name), "w") as f:
        for v in V: f.write("v %.6f %.6f %.6f\n" % v)
        for t in F: f.write("f %d %d %d\n" % tuple(i + 1 for i in t))
    print(name, len(V), len(F))
def uvsphere(r, n, m, c=(0,0,0)):
    V=[]; F=[]
    for i in range(n+1):
        th = math.pi*i/n
        for j in range(m):
            ph = 2*math.pi*j/m
            V.append((c[0]+r*math.sin(th)*math.cos(ph), c[1]+r*math.cos(th), c[2]+r*math.sin(th)*math.sin(ph)))
    def idx(i,j): return i*m + (j % m)
    for i in range(n):
        for j in range(m):
            a,b,cc,d = idx(i,j), idx(i+1,j), idx(i+1,j+1), idx(i,j+1)
            if i != 0: F.append((a,b,d))
            if i != n-1: F.append((b,cc,d))
    # weld poles crudely: fine for a test (duplicate pole vertices remain; dedupe)
    return weld(V,F)
def weld(V,F):
    key={}; remap=[]; NV=[]
    for v in V:
        k=tuple(round(x,6) for x in v)
        if k not in key: key[k]=len(NV); NV.append(v)
        remap.append(key[k])
    NF=[]
    for t in F:
        t2=tuple(remap[i] for i in t)
        if len(set(t2))==3: NF.append(t2)
    return NV,NF
def torus(R,r,n,m):
    V=[];F=[]
    for i in range(n):
        u=2*math.pi*i/n
        for j in range(m):
            v=2*math.pi*j/m
            V.append(((R+r*math.cos(v))*math.cos(u),(R+r*math.cos(v))*math.sin(u),r*math.sin(v)))
    def idx(i,j): return (i%n)*m+(j%m)
    for i in range(n):
        for j in range(m):
            a,b,c,d=idx(i,j),idx(i+1,j),idx(i+1,j+1),idx(i,j+1)
            F.append((a,b,c)); F.append((a,c,d))
    return V,F
def cylinder(r,h,n,c=(0,0,0),capped=True):
    V=[];F=[]
    for k,y in ((0,-h/2),(1,h/2)):
        for j in range(n):
            ph=2*math.pi*j/n
            V.append((c[0]+r*math.cos(ph),c[1]+y,c[2]+r*math.sin(ph)))
    for j in range(n):
        a,b,cc,d=j,(j+1)%n,n+(j+1)%n,n+j
        F.append((a,b,cc)); F.append((a,cc,d))
    if capped:
        bot=len(V); V.append((c[0],c[1]-h/2,c[2])); top=len(V); V.append((c[0],c[1]+h/2,c[2]))
        for j in range(n):
            F.append((bot,(j+1)%n,j)); F.append((top,n+j,n+(j+1)%n))
    return V,F
def merge(*parts):
    V=[];F=[]
    for pv,pf in parts:
        o=len(V); V+=pv; F+=[tuple(i+o for i in t) for t in pf]
    return V,F
def bumpy_sphere(r,n,m):
    V,F=uvsphere(r,n,m)
    V2=[]
    for x,y,z in V:
        l=math.sqrt(x*x+y*y+z*z); d=1+0.15*math.sin(8*math.atan2(z,x))*math.sin(6*math.acos(max(-1,min(1,y/l))))
        V2.append((x*d,y*d,z*d))
    return V2,F
write("sphere.obj", *uvsphere(1.0, 64, 128))
write("dense_bumpy.obj", *bumpy_sphere(1.0, 400, 800))
write("overlap_spheres.obj", *merge(uvsphere(1.0,48,96,(0,0,0)), uvsphere(0.8,48,96,(1.0,0.3,0))))
write("thin_protrusion.obj", *merge(uvsphere(1.0,48,96), cylinder(0.03,2.5,16)))
write("narrow_gap.obj", *merge(uvsphere(1.0,48,96,(0,0,0)), uvsphere(1.0,48,96,(2.02,0,0))))
write("open_cylinder.obj", *cylinder(1.0,2.0,96,capped=False))
write("disconnected.obj", *merge(uvsphere(0.5,32,64,(0,0,0)), torus(1.5,0.3,96,32), uvsphere(0.4,32,64,(0,3,0))))
# non-manifold: two cubes sharing an edge + a dangling fin
V=[(0,0,0),(1,0,0),(1,1,0),(0,1,0),(0,0,1),(1,0,1),(1,1,1),(0,1,1)]
cube=[(0,2,1),(0,3,2),(4,5,6),(4,6,7),(0,1,5),(0,5,4),(1,2,6),(1,6,5),(2,3,7),(2,7,6),(3,0,4),(3,4,7)]
V2=[(x+1,y+1,z) for x,y,z in V]
Vn,Fn=merge((V,cube),(V2,cube))
Vn=Vn+[(0.5,0.5,2.0)]; Fn=Fn+[(6,7,len(Vn)-1)]
write("nonmanifold.obj", Vn, Fn)
write("torus.obj", *torus(1.0,0.35,128,48))
