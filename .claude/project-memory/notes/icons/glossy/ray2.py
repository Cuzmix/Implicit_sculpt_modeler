# Renders the brush icons in the "grey ball, coloured effect" style: each brush's effect
# modelled as a signed distance field on a unit ball, ray marched, the effect in its own
# glossy colour, the ball matte grey, with a soft shadow and occlusion. Writes RGBA PNGs.
import numpy as np, os, sys
from PIL import Image
N=384; SS=2; R=1.0
BUMPS2=[]
def norm(v): v=np.asarray(v,float); return v/np.linalg.norm(v)
def L(p): return np.linalg.norm(p,axis=-1)
def smin(a,b,k):
    h=np.clip(0.5+0.5*(b-a)/k,0,1); return b*(1-h)+a*h-k*h*(1-h), h
def smax(a,b,k):
    d,h=smin(-a,-b,k); return -d,h
def cap(p,a,b,r):
    pa=p-a; ba=b-a; h=np.clip((pa@ba)/(ba@ba),0,1); return L(pa-h[...,None]*ba)-r
def rcone(p,a,b,r1,r2):
    ba=b-a; l2=ba@ba; rr=r1-r2; a2=l2-rr*rr; il2=1/l2
    pa=p-a; y=pa@ba; z=y-l2
    x=pa*l2-y[...,None]*ba; x2=(x*x).sum(-1); y2=y*y*l2; z2=z*z*l2
    k=np.sign(rr)*rr*rr*x2
    return np.where(np.sign(z)*a2*z2>k, np.sqrt(x2+z2)*il2-r2,
        np.where(np.sign(y)*a2*y2<k, np.sqrt(x2+y2)*il2-r1, (np.sqrt(np.maximum(x2*a2*il2,0))+y*rr)*il2-r1))
def onball(x,y,h=0.0):
    z=np.sqrt(max(R*R-x*x-y*y,0)); return norm([x,y,z])*(R+h)
_r=np.random.default_rng(5)
for _i in range(70):
    _d=_r.normal(size=3); _d/=np.linalg.norm(_d)
    if _d[2]>0.15 and _d[0]<-0.05: BUMPS2.append((_d*R,0.06+0.07*_r.random()))
COL={'clay':(0.36,0.52,0.98),'smooth':(0.86,0.88,0.92),'grab':(0.62,0.52,0.96),'flatten':(0.45,0.88,0.62),
     'draw':(0.93,0.93,0.97),'layer':(0.27,0.78,0.74),'clay_strips':(0.45,0.5,1.0),'mask':(0.13,0.15,0.2),
     'paint':(0.92,0.36,0.82),'cloth':(0.96,0.55,0.64),'history':(0.37,0.84,0.77),'morph':(0.71,0.88,0.42),'elastic':(0.56,0.6,1.0),
     'inflate':(0.98,0.78,0.36),'crease':(0.35,0.72,0.98),'pinch':(0.98,0.4,0.42),'trim':(0.98,0.5,0.32),'snake':(0.45,0.8,0.42),'tube':(0.99,0.66,0.2),
     'rotate':(0.98,0.42,0.62),'thumb':(0.52,0.82,0.98),'pose':(0.62,0.86,0.5)}
def cap_region(p,c,a0):
    # Distance, along the ball, from the round region of angle a0 about direction c.
    c=norm(c); return (np.arccos(np.clip((p@c)/(L(p)+1e-9),-1,1))-a0)*R
def scene(n,p):
    ball=L(p)-R; w=np.zeros(p.shape[:-1])
    if n=='clay':
        d=ball
        m0=norm([0.55,-0.75,0.35]); fwd=norm([0.1,0.25,1.0])
        for off in (-0.42,0.0,0.42):
            band=np.sqrt((p@m0-off)**2+(L(p)-R)**2)-0.15
            u=norm(np.cross(m0,fwd)); c=smax(smax(band,-(p@fwd-0.3),0.1)[0],np.abs(p@u-0.05)-0.62,0.12)[0]
            d,h=smin(d,c,0.04); w=np.maximum(w,np.clip((ball-c)*12+0.5,0,1))
        return d,w
    if n=='draw':
        c=np.full(ball.shape,9.0); prev=None
        for t in np.linspace(-0.68,0.68,17):
            q=onball(t,0.32*np.sin(t*4.2)-0.02,0.0)
            if prev is not None: c=np.minimum(c,cap(p,prev,q,0.11))
            prev=q
        d,_=smin(ball,c,0.12); return d, np.clip((ball-c)*8+0.2,0,1)
    if n=='layer':
        reg=cap_region(p,[-0.05,0.15,1],0.62)+0.05*np.sin(5*np.arctan2(p[...,1],p[...,0]))
        sh=smax(L(p)-(R+0.09),reg,0.04)[0]; d,_=smin(ball,sh,0.02)
        return d, np.clip((L(p)-R-0.03)*30,0,1)
    if n=='clay_strips':
        # Flat-topped strips with square ends, laid side by side across the ball.
        m0=norm([0.55,-0.75,0.35]); fwd=norm([0.1,0.25,1.0]); u=norm(np.cross(m0,fwd))
        d=ball; w=np.zeros(ball.shape)
        for off in (-0.2,0.2):
            st=np.maximum(np.maximum(np.abs(p@m0-off)-0.15,L(p)-(R+0.08)),np.abs(p@u-0.05)-0.55)
            st=np.maximum(st,-(p@fwd-0.2))
            d,_=smin(d,st,0.012); w=np.maximum(w,np.clip((ball-st)*20+0.3,0,1))
        return d,w
    if n=='mask':
        reg=cap_region(p,[0.1,0.2,1],0.75)+0.08*np.sin(6*np.arctan2(p[...,1]-0.2,p[...,0]-0.1))
        return ball, np.clip(-reg*12+0.5,0,1)
    if n=='paint':
        q=p[...,1]-0.3*np.sin(3*p[...,0])+0.1
        return ball, np.clip((0.22-np.abs(q))*16,0,1)
    if n=='cloth':
        ang=np.arctan2(p[...,2],p[...,0]); fold=0.045*np.sin(9*ang)*np.clip(0.6-p[...,1],0,1)
        sheet=np.abs(L(p)-(R+0.07+fold))-0.035
        hem=-(p[...,1]+0.15+0.08*np.sin(9*ang))
        cl=smax(sheet,hem,0.04)[0]; d,_=smin(ball,cl,0.02)
        return d, np.clip((ball-cl)*20+0.3,0,1)
    if n=='history':
        q=p[...,0]+0.25*np.sin(3*p[...,1])
        return ball, np.clip((q-0.05)*14+0.5,0,1)
    if n=='morph':
        d=ball
        for c,r in BUMPS2: d,_=smin(d,L(p-c)-r,0.05)
        q=p[...,0]-0.15*np.sin(3*p[...,1])
        return d, np.clip((q-0.05)*14+0.5,0,1)
    if n=='elastic':
        a=onball(0.2,0.25,-0.5); b=np.array([0.85,0.95,0.55])
        c=np.minimum(rcone(p,a,b,0.6,0.32),L(p-b)-0.34); d,_=smin(ball,c,0.55)
        return d, np.clip((ball-c)*3+0.15,0,1)
    if n=='smooth':
        q=p[...,1]+0.28*np.sin(3.2*p[...,0]+0.6)-0.05*p[...,0]
        return ball, np.clip((q-0.05)*14+0.5,0,1)
    if n=='grab':
        a=onball(0.35,0.4,-0.15); b=np.array([0.95,1.05,0.45])
        c=np.minimum(rcone(p,a,b,0.36,0.22),L(p-b)-0.33); d,h=smin(ball,c,0.38)
        return d, np.clip((ball-c)*5+0.2,0,1)
    if n=='flatten':
        nn=norm([0.42,0.55,0.72]); pl=p@nn-0.42; d,_=smax(ball,pl,0.03)
        return d, np.clip((p@nn-0.38)*40,0,1)
    if n=='inflate':
        c=L(p-np.array([0.5,0.55,0.55]))-0.55; d,h=smin(ball,c,0.3)
        return d, np.clip((ball-c)*4+0.3,0,1)
    if n=='crease':
        a=onball(0.5,0.75,0.0); m=onball(0.22,0.3,0.0); b=onball(-0.05,-0.25,0.0)
        g=np.minimum(rcone(p,a,m,0.13,0.08),rcone(p,m,b,0.08,0.02)); d,_=smax(ball,-g,0.015)
        return d, np.clip((0.05-g)*30,0,1)
    if n=='pinch':
        x,y,z=p[...,0],p[...,1],p[...,2]
        s=1+0.55*np.exp(-(y/0.4)**2)
        return (np.sqrt((x*s)**2+y*y+z*z)-R)/s*0.9, w
    if n=='trim':
        nn=norm([0.45,0.6,0.66]); pl=p@nn-0.48; d,_=smax(ball,pl,0.02)
        g=np.abs(p@nn-0.3)-0.025; d,_=smax(d,-np.maximum(g,ball+0.04),0.02)
        return d, np.clip((p@nn-0.32)*40,0,1)
    if n=='snake':
        pts=[onball(0.0,0.3,-0.12),np.array([0.35,0.85,0.7]),np.array([0.8,1.12,0.55]),np.array([1.18,1.0,0.5]),np.array([1.25,0.62,0.5]),np.array([1.0,0.42,0.55]),np.array([0.86,0.58,0.6])]
        rs=[0.34,0.25,0.19,0.15,0.12,0.09,0.07]; c=np.full(ball.shape,9.0)
        P=np.array(pts); Rr=np.array(rs); Q=[];RQ=[]
        for i in range(len(P)-1):
            p0=P[max(i-1,0)];p1=P[i];p2=P[i+1];p3=P[min(i+2,len(P)-1)]
            for t in np.linspace(0,1,5)[:-1]:
                Q.append(0.5*((2*p1)+(-p0+p2)*t+(2*p0-5*p1+4*p2-p3)*t*t+(-p0+3*p1-3*p2+p3)*t**3)); RQ.append(Rr[i]*(1-t)+Rr[i+1]*t)
        Q.append(P[-1]);RQ.append(Rr[-1])
        for i in range(len(Q)-1): c=np.minimum(c,rcone(p,Q[i],Q[i+1],RQ[i],RQ[i+1]))
        d,h=smin(ball,c,0.2)
        return d, np.clip((ball-c)*5+0.2,0,1)
    if n=='tube':
        # A round rope of clay laid along an S on the ball's front, sitting on it.
        c=np.full(ball.shape,9.0); prev=None
        for t in np.linspace(-0.62,0.62,25):
            q=onball(t,0.34*np.sin(t*4.0)+0.06,0.11)
            if prev is not None: c=np.minimum(c,cap(p,prev,q,0.15))
            prev=q
        d,_=smin(ball,c,0.05); return d, np.clip((ball-c)*14+0.3,0,1)
    if n=='rotate':
        # A patch of the ball's front turned about its middle: a coloured swirl, its arms
        # sweeping round, raised a little where it was turned.
        c=norm([0.12,0.22,1.0]); u=norm(np.cross(c,[0,1,0])); v=np.cross(c,u)
        x=p@u; y=p@v; r=np.sqrt(x*x+y*y); a=np.arctan2(y,x)+3.2*r
        arms=np.cos(3*a)*np.clip(1-r/0.75,0,1)
        reg=cap_region(p,c,0.7)
        sh=smax(L(p)-(R+0.04*np.clip(arms,0,1)),reg,0.04)[0]; d,_=smin(ball,sh,0.02)
        return d, np.clip((arms-0.15)*4,0,1)*np.clip(-reg*10,0,1)
    if n=='thumb':
        # A thumb's smear: a shallow flat groove pressed along the ball, the clay it pushed
        # piled at its end.
        a=onball(-0.55,-0.2,0.0); b=onball(0.3,0.35,0.0)
        g=rcone(p,a,b,0.2,0.24)
        d,_=smax(ball,-g,0.05)
        pile=L(p-onball(0.42,0.43,0.04))-0.2; d,_=smin(d,pile,0.12)
        return d, np.clip((0.06-g)*12,0,1)+np.clip((ball-pile)*8+0.2,0,1)*0.8
    if n=='pose':
        # A finger of clay out of the ball, bent at a joint toward the right: the part past
        # the joint turned whole, the joint rounded.
        a=onball(0.05,0.35,-0.2); j=np.array([0.2,0.95,0.6]); b=np.array([0.85,1.2,0.5])
        arm=np.minimum(rcone(p,a,j,0.3,0.22),rcone(p,j,b,0.22,0.17)); arm=np.minimum(arm,L(p-j)-0.23)
        d,_=smin(ball,arm,0.25)
        bent=np.clip((p@norm(b-j)-(j@norm(b-j))+0.1)*6,0,1)
        return d, np.clip((ball-arm)*5+0.2,0,1)*(0.35+0.65*bent)
def render(n):
    M=N*SS; s=(np.arange(M)+0.5)/M*2-1; sc=1.42
    X,Y=np.meshgrid(s*sc+0.08,-s*sc+0.12)
    o=np.stack([X,Y,np.full_like(X,4.0)],-1); rd=np.array([0,0,-1.0])
    t=np.zeros(X.shape); hit=np.zeros(X.shape,bool)
    for _ in range(160):
        p=o+t[...,None]*rd; d,_=scene(n,p); hit|=d<1e-3; t=np.where(hit|(t>8),t,t+d*0.7)
    p=o+t[...,None]*rd; e=1.5e-3
    nr=np.stack([scene(n,p+v*e)[0]-scene(n,p-v*e)[0] for v in np.eye(3)],-1); nr/=L(nr)[...,None]+1e-9
    _,w=scene(n,p)
    Ld=norm([-0.5,0.62,0.6]); dif=np.clip(nr@Ld,0,1)
    ao=np.ones(X.shape)
    for i in range(1,6): h=0.04*i; ao-=(h-scene(n,p+nr*h)[0])*(0.5**i)*2.4
    ao=np.clip(ao,0,1)
    sh=np.ones(X.shape); tt=np.full(X.shape,0.02)
    for _ in range(70):
        dd,_=scene(n,p+Ld*tt[...,None]); sh=np.minimum(sh,6*dd/tt); tt+=np.clip(dd,0.01,0.1)
    sh=np.clip(sh,0,1)
    hv=norm(Ld+np.array([0,0,1.0])); spec=np.clip(nr@hv,0,1)
    rim=(1-np.clip(nr[...,2],0,1))**2.5
    grey=np.array([0.5,0.5,0.53]); eff=np.array(COL[n])
    base=grey[None,None]*(1-w[...,None])+eff[None,None]*w[...,None]
    light=(0.22+0.2*w+0.85*dif*(0.35+0.65*sh))*(0.4+0.6*ao)
    col=base*light[...,None]
    gloss=(0.15+0.55*w)*spec**(20+60*w)*sh
    col+=gloss[...,None]+(0.12*rim*ao)[...,None]*np.array([0.85,0.88,0.95])
    col=np.clip(col,0,1)**(1/1.15)
    rgba=np.concatenate([col,hit[...,None].astype(float)],-1)
    img=Image.fromarray((rgba*255).astype(np.uint8),'RGBA').resize((N,N),Image.LANCZOS)
    return img
OUT=os.environ.get('GLOSSY_OUT','/mnt/project-files/notes/icons/glossy')
for n in sys.argv[1:]:
    render(n).save(f'{OUT}/{n}.png'); print(n,flush=True)
