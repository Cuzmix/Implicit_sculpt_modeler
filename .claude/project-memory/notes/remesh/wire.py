"""Draws an OBJ (any face sizes) as an orthographic wireframe of its front-facing faces, seen from +Z, into a PNG."""
import sys, numpy as np
from PIL import Image, ImageDraw
def load(p):
    V=[];F=[]
    for line in open(p, errors="replace"):
        if line.startswith("v "): V.append([float(x) for x in line.split()[1:4]])
        elif line.startswith("f "):
            F.append([ (int(t.split("/")[0])-1) for t in line.split()[1:]])
    return np.array(V), F
def draw(p, out, size=900, title=""):
    V,F=load(p)
    c=(V.max(0)+V.min(0))/2; V=V-c; s=0.46*size/np.abs(V).max()
    # a slight turn so the pole/seam structure shows
    a=np.radians(25); b=np.radians(-30)
    Ry=np.array([[np.cos(b),0,np.sin(b)],[0,1,0],[-np.sin(b),0,np.cos(b)]]); Rx=np.array([[1,0,0],[0,np.cos(a),-np.sin(a)],[0,np.sin(a),np.cos(a)]])
    V=V@Ry.T@Rx.T
    img=Image.new("RGB",(size,size),(246,244,240)); d=ImageDraw.Draw(img)
    faces=[]
    for f in F:
        P=V[f]; n=np.cross(P[1]-P[0],P[2]-P[0])
        if n[2]<=0: continue
        faces.append((P[:,2].mean(), f, len(f)))
    faces.sort(key=lambda t:t[0])
    for _,f,k in faces:
        P=V[f]; pts=[(size/2+x*s, size/2-y*s) for x,y,_ in P]
        fill=(228,222,210) if k==4 else ((206,170,160) if k==3 else (180,196,220))
        d.polygon(pts, fill=fill, outline=(40,38,36))
    d.text((12,8), title, fill=(30,30,30))
    img.save(out); print(out, len(F), "faces drawn", len(faces))
if __name__=="__main__":
    draw(sys.argv[1], sys.argv[2], title=sys.argv[3] if len(sys.argv)>3 else "")
