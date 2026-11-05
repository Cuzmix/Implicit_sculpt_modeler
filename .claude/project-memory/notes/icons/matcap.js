const fs=require('fs');const {chromium}=require('playwright');
const OUT='/mnt/project-files/notes/icons/matcap/';
// Shared look: a grey clay sphere filling the tile from the lower right, light from the top left.
const defs=k=>`<defs>
<radialGradient id="${k}s" cx=".3" cy=".25" r=".85"><stop offset="0" stop-color="#7c7c80"/><stop offset=".55" stop-color="#4a4a4e"/><stop offset="1" stop-color="#2a2a2d"/></radialGradient>
<linearGradient id="${k}f" x1=".1" y1="0" x2=".8" y2="1"><stop offset="0" stop-color="#f4f4f4"/><stop offset=".55" stop-color="#bdbdbf"/><stop offset="1" stop-color="#6e6e72"/></linearGradient>
<linearGradient id="${k}d" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#9a9a9e"/><stop offset="1" stop-color="#4e4e52"/></linearGradient>
<radialGradient id="${k}b" cx=".35" cy=".3" r=".7"><stop offset="0" stop-color="#e8e8ea"/><stop offset=".6" stop-color="#9c9ca0"/><stop offset="1" stop-color="#55555a"/></radialGradient>
<filter id="${k}sh" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="1.2"/></filter>
</defs>`;
const sphere=k=>`<circle cx="30" cy="33" r="29" fill="url(#${k}s)"/>`;
const ART={
 clay:{name:'Clay',f:k=>sphere(k)+`
  <path d="M8 31c7-7 19-13 30-14.5 3-.4 4.6 1.4 3 3.6-5.6 6.4-17.6 13-27.6 15-3.6.7-6.4-1.8-5.4-4.1z" fill="#000" opacity=".45" filter="url(#${k}sh)" transform="translate(1.5 4)"/>
  <path d="M8 26.5c7-7 19-13 30-14.5 3-.4 4.6 1.4 3 3.6v4.6c-5.6 6.4-17.6 13-27.6 15-3.6.7-6.4-1.8-5.4-4.1z" fill="url(#${k}d)"/>
  <path d="M8 26.5c7-7 19-13 30-14.5 3-.4 4.6 1.4 3 3.6-5.6 6.4-17.6 13-27.6 15-3.6.7-6.4-1.8-5.4-4.1z" fill="url(#${k}f)"/>
  <path d="M11 26.4c6.4-5.6 16.4-10.6 25.6-12" fill="none" stroke="#fff" stroke-width="1" stroke-linecap="round" opacity=".7"/>`},
 smooth:{name:'Smooth',f:k=>sphere(k)+`
  ${[[10,30,4.2],[17,36,3.6],[9,40,3],[24,42,3.2],[15,44,2.6],[30,46,2.4],[22,30,2.4]].map(([x,y,r])=>`<circle cx="${x+.8}" cy="${y+1.2}" r="${r}" fill="#000" opacity=".35"/><circle cx="${x}" cy="${y}" r="${r}" fill="url(#${k}b)"/>`).join('')}
  <path d="M26 33c3-9 11-15 19-15v24c-6 4-14 4-19-1-1.6-2.4-1.4-5 0-8z" fill="url(#${k}f)" opacity=".95"/>
  <path d="M8 18c6-9 18-13 30-10" fill="none" stroke="#f08a5d" stroke-width="2.6" stroke-linecap="round"/>`},
 grab:{name:'Grab',f:k=>sphere(k)+`
  <path d="M6 46c6-2 10-6 12.6-12.4 2.6-6.6 4.4-14.6 10.6-19.8 2-1.7 4.6-2.4 6.4-1.6-1.6 4.4-1.4 10 .8 15.6 2.4 6.4 7 11 12.6 13.2V50H6z" fill="url(#${k}f)"/>
  <path d="M36.4 12.2c-1.6 4.4-1.4 10 .8 15.6 2.4 6.4 7 11 12.6 13.2-6.6.6-12-3.6-14.4-10-1.8-5-1.6-12.4 1-18.8z" fill="#5a5a5e" opacity=".55"/>
  <path d="M31 13.5 37.5 8" fill="none" stroke="#f2c94c" stroke-width="2.6" stroke-linecap="round"/>
  <path d="M33 7.4 39.6 6.4l-1.2 6.4z" fill="#f2c94c" stroke="#f2c94c" stroke-width="1.6" stroke-linejoin="round"/>`},
};
const tile=(art,k,shape,s)=>`<svg xmlns="http://www.w3.org/2000/svg" width="${s}" height="${s}" viewBox="0 0 48 48">${defs(k)}<clipPath id="${k}c">${shape=='square'?'<rect width="48" height="48" rx="6"/>':'<circle cx="24" cy="24" r="23.5"/>'}</clipPath><g clip-path="url(#${k}c)"><rect width="48" height="48" fill="#2b2b2e"/>${art.f(k)}</g></svg>`;
let i=0;for(const [bk,a] of Object.entries(ART))for(const sh of ['square','round'])fs.writeFileSync(`${OUT}${sh}-${bk}.svg`,tile(a,bk+sh,sh,48));
const T={frame:'#0d0f12',surface:'#161a1f',text:'#e9ecef',sec:'#a7aeb8',chosen:'#1c3b37',onChosen:'#5ed6c4',border:'#2a3038'};
const tl=(icon,name,on)=>`<div class="tile ${on?'on':''}"><div class="ic">${icon}</div><div class="nm">${name}</div></div>`;
let rows='';
for(const sh of ['square','round']){
 const big=Object.entries(ART).map(([bk,a])=>tile(a,'B'+bk+sh+(i++),sh,110)).join('');
 const small=Object.entries(ART).map(([bk,a])=>[20,26,32].map(s=>tile(a,'s'+bk+sh+(i++),sh,s)).join('')).join('<span style="width:14px"></span>');
 const shelf=Object.entries(ART).map(([bk,a],j)=>tl(tile(a,'t'+bk+sh+(i++),sh,28),a.name,j==0)).join('')+['Inflate','Pinch'].map(n=>tl(`<span class="lu">${n=='Inflate'?'&#xe349;':'&#xe220;'}</span>`,n,false)).join('');
 rows+=`<div class="row"><div class="lab"><b>${sh=='square'?'Square tiles (Blender-like)':'Round tiles (ZBrush iPad-like)'}</b></div><div class="big">${big}</div><div><div class="small">${small}</div><div class="shelf">${shelf}</div></div></div>`;
}
const html=`<html><head><style>@font-face{font-family:Lu;src:url(file:///home/user/Implicit_sculpt_modeler/assets/fonts/Lucide.ttf)}
body{margin:0;background:${T.frame};font:13px Inter,system-ui,sans-serif;color:${T.text};padding:20px 28px}
.row{display:grid;grid-template-columns:150px 380px 1fr;align-items:center;gap:24px;padding:16px 0;border-bottom:1px solid ${T.border}}
.big{display:flex;gap:12px}.small{display:flex;gap:6px;align-items:flex-end;margin-bottom:14px}
.shelf{display:flex;background:${T.surface};border:1px solid ${T.border};border-radius:14px;padding:6px 8px;width:max-content}
.tile{width:64px;height:58px;display:flex;flex-direction:column;align-items:center;border-radius:10px;color:${T.sec}}
.tile.on{background:${T.chosen};color:${T.onChosen}}.ic{height:34px;display:flex;align-items:center;justify-content:center;margin-top:3px}
.nm{font-size:11px}.lu{font-family:Lu;font-size:20px}</style></head><body>${rows}</body></html>`;
fs.writeFileSync(OUT+'sheet.html',html);
(async()=>{const br=await chromium.launch();const p=await br.newPage({viewport:{width:1060,height:300},deviceScaleFactor:2});
await p.goto('file://'+OUT+'sheet.html');await p.waitForTimeout(300);await p.screenshot({path:OUT+'matcap.png',fullPage:true});await br.close();})();
