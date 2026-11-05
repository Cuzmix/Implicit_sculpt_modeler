# Renders each brush's icon as a real 3D clay form (signed distance fields, ray marched),
# grey matcap-like shading with ambient occlusion and a soft shadow, into a round tile.
import numpy as np, sys
from PIL import Image
N=512  # rendered size; shown down to 20-32 pt
R=1.0
def norm(v): return v/np.linalg.norm(v)
def smin(a,b,k):
    h=np.clip(0.5+0.5*(b-a)/k,0,1); return b*(1-h)+a*h-k*h*(1-h)
def sph(p,c,r): return np.linalg.norm(p-c,axis=-1)-r
def rbox(p,c,frame,half,r):
    q=np.einsum('...j,ij->...i',p-c,frame)  # into the box's frame
    d=np.abs(q)-half
    return np.linalg.norm(np.maximum(d,0),axis=-1)+np.minimum(d.max(-1),0)-r
def rcone(p,a,b,r1,r2):
    # Blender-free round cone (iq): a ball r1 at a tapering to r2 at b.
    ba=b-a; l2=ba@ba; rr=r1-r2; a2=l2-rr*rr; il2=1/l2
    pa=p-a; y=pa@ba; z=y-l2
    x=pa*l2-y[...,None]*ba; x2=(x*x).sum(-1); y2=y*y*l2; z2=z*z*l2
    k=np.sign(rr)*rr*rr*x2
    out=np.where(np.sign(z)*a2*z2>k, np.sqrt(x2+z2)*il2-r2,
        np.where(np.sign(y)*a2*y2<k, np.sqrt(x2+y2)*il2-r1, (np.sqrt(x2*a2*il2)+y*rr)*il2-r1))
    return out
def frame_on(n,spin):
    n=norm(np.array(n,float)); t=norm(np.cross([0,0,1],n) if abs(n[2])<.99 else np.cross([1,0,0],n))
    t=norm(t*np.cos(spin)+np.cross(n,t)*np.sin(spin)); return np.stack([t,np.cross(n,t),n])
rng=np.random.default_rng(3)
BUMPS=[]
for i in range(60):
    d=norm(rng.normal(size=3))
    if d[2]>0.15 and d[0]<-0.05 and d[1]<0.45: BUMPS.append((d*R, 0.07+0.07*rng.random()))
def scene(name,p):
    d=sph(p,np.zeros(3),R)
    if name=='clay':
        # Clay fills up to a plane: a strip whose top is flat, as the brush lays it.
        for n,spin,half,h in [((-0.12,0.12,0.98),2.5,(0.62,0.22),0.07)]:
            n=norm(np.array(n)); F=frame_on(n,spin); q=np.einsum('...j,ij->...i',p,F)
            rr=0.19; dd=np.abs(q[...,:2])-(np.array(half)-rr)
            rect=np.linalg.norm(np.maximum(dd,0),axis=-1)+np.minimum(dd.max(-1),0)-rr
            strip=np.maximum(np.maximum(rect,q[...,2]-(R+h)),(R-0.4)-q[...,2])
            d=smin(d,strip,0.09)
    elif name=='smooth':
        for c,r in BUMPS: d=smin(d,sph(p,c,r),0.04)
    elif name=='grab':
        a=norm(np.array([0.35,0.45,0.82]))*0.82; b=np.array([0.95,1.35,0.55])
        d=smin(d,rcone(p,a,b,0.42,0.07),0.3)
    return d
def render(name,center=(-0.22,0.3),scale=1.22):
    s=(np.arange(N)+0.5)/N*2-1
    X,Y=np.meshgrid(s*scale+center[0], -s*scale+center[1])
    o=np.stack([X,Y,np.full_like(X,4.0)],-1); rd=np.array([0,0,-1.0])
    t=np.zeros(X.shape); hit=np.zeros(X.shape,bool)
    for _ in range(140):
        p=o+t[...,None]*rd; d=scene(name,p)
        hit|=d<1e-3; t=np.where(hit,t,t+d*0.9)
    p=o+t[...,None]*rd; e=1e-3
    nrm=np.stack([scene(name,p+np.array(v)*e)-scene(name,p-np.array(v)*e) for v in np.eye(3)],-1); nrm/=np.linalg.norm(nrm,axis=-1,keepdims=True)+1e-9
    L=norm(np.array([-0.55,0.65,0.55]))
    dif=np.clip(nrm@L,0,1)
    ao=np.ones(X.shape)
    for i in range(1,6):
        h=0.05*i; ao-= (h-scene(name,p+nrm*h))*(0.5**i)*2.2
    ao=np.clip(ao,0,1)
    sh=np.ones(X.shape); tt=np.full(X.shape,0.03)
    for _ in range(90):
        q=p+L*tt[...,None]; dd=scene(name,q); sh=np.minimum(sh,6*dd/tt); tt+=np.clip(dd,0.01,0.08)
    sh=np.clip(sh,0,1)
    hv=norm(L+np.array([0,0,1.0])); spec=np.clip(nrm@hv,0,1)**40
    rim=(1-np.clip(nrm[...,2],0,1))**3
    col=0.06+0.86*dif*(0.3+0.7*sh)
    col=col*(0.45+0.55*ao)+0.18*spec*sh+0.10*rim*ao
    col=np.clip(col,0,1)**(1/1.25)
    rgb=np.stack([col*0.96,col*0.96,col*1.0],-1)
    bg=np.array([0x2b,0x2b,0x2e])/255
    img=np.where(hit[...,None],rgb,bg)
    return (img*255).astype(np.uint8)
for name in sys.argv[1:]:
    Image.fromarray(render(name)).save(f'/mnt/project-files/notes/icons/render3d/{name}.png')
    print(name,'ok')
