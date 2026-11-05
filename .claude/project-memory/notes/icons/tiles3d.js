const fs=require('fs');const {chromium}=require('playwright');
const D='/mnt/project-files/notes/icons/render3d/';
// The rendered form under the brush's motion mark, in a round tile; the SVG carries the
// render as an embedded picture so one file holds the icon.
const ACC={clay:'',
 smooth:'<path d="M9 17c5-8 15-12 25-10" fill="none" stroke="#f08a5d" stroke-width="2.6" stroke-linecap="round"/>',
 grab:'<path d="M27 20.5 33 15" fill="none" stroke="#f2c94c" stroke-width="2.6" stroke-linecap="round"/><path d="M29 12.6l6-1.2-1 6z" fill="#f2c94c" stroke="#f2c94c" stroke-width="1.6" stroke-linejoin="round"/>'};
const svg=(n,s)=>`<svg xmlns="http://www.w3.org/2000/svg" width="${s}" height="${s}" viewBox="0 0 48 48"><clipPath id="c${n}${s}"><circle cx="24" cy="24" r="23.5"/></clipPath><image href="data:image/png;base64,${fs.readFileSync(D+n+'.png').toString('base64')}" width="48" height="48" clip-path="url(#c${n}${s})"/>${ACC[n]}</svg>`;
for(const n of Object.keys(ACC))fs.writeFileSync(D+n+'.svg',svg(n,48));
const T={frame:'#0d0f12',surface:'#161a1f',text:'#e9ecef',sec:'#a7aeb8',chosen:'#1c3b37',onChosen:'#5ed6c4',border:'#2a3038'};
const names={clay:'Clay',smooth:'Smooth',grab:'Grab'};
const tl=(icon,name,on)=>`<div class="tile ${on?'on':''}"><div class="ic">${icon}</div><div class="nm">${name}</div></div>`;
const big=Object.keys(ACC).map(n=>svg(n,150)).join('');
const small=Object.keys(ACC).map(n=>[20,26,32].map(s=>svg(n,s)).join('')).join('<span style="width:16px"></span>');
const shelf=Object.keys(ACC).map((n,j)=>tl(svg(n,30),names[n],j==0)).join('')+tl('<span class="lu">&#xe349;</span>','Inflate')+tl('<span class="lu">&#xe220;</span>','Pinch');
const html=`<html><head><style>@font-face{font-family:Lu;src:url(file:///home/user/Implicit_sculpt_modeler/assets/fonts/Lucide.ttf)}
body{margin:0;background:${T.frame};font:13px Inter,system-ui,sans-serif;color:${T.text};padding:24px 28px;display:flex;gap:40px;align-items:center}
.big{display:flex;gap:16px}.small{display:flex;gap:6px;align-items:flex-end;margin-bottom:16px}
.shelf{display:flex;background:${T.surface};border:1px solid ${T.border};border-radius:14px;padding:6px 8px;width:max-content}
.tile{width:64px;height:58px;display:flex;flex-direction:column;align-items:center;border-radius:10px;color:${T.sec}}
.tile.on{background:${T.chosen};color:${T.onChosen}}.ic{height:35px;display:flex;align-items:center;justify-content:center;margin-top:3px}
.nm{font-size:11px}.lu{font-family:Lu;font-size:20px}</style></head><body><div class="big">${big}</div><div><div class="small">${small}</div><div class="shelf">${shelf}</div></div></body></html>`;
fs.writeFileSync(D+'sheet.html',html);
(async()=>{const br=await chromium.launch();const p=await br.newPage({viewport:{width:1040,height:220},deviceScaleFactor:2});
await p.goto('file://'+D+'sheet.html');await p.waitForTimeout(300);await p.screenshot({path:D+'render3d.png',fullPage:true});await br.close();})();
