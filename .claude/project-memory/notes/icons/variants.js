const fs=require('fs');const {chromium}=require('playwright');
const OUT='/mnt/project-files/notes/icons/variants/';
// Each brush as parts: body (closed form), shade (inside the body), detail and accent lines.
const B={
 clay:{name:'Clay',tint:'#ff9f5a',
  body:'M5 14.5c-.6-3.8 1.6-7.4 5-8.4 2.2-.7 3.8 0 5.6-.4 2.4-.5 4.6 1.2 5 3.6.3 1.8-.4 3.2 0 4.8.5 2.4-.8 4.8-3.4 5.8-2 .8-4 .4-6 .8-2.6.5-5.4-1-6-3.6z',
  shade:'M14 11c2-1 4.2-1.6 6.6-1.4.3 1.6-.3 2.8.1 4.2.5 2.4-.8 4.8-3.4 5.8-.6-3-1.4-6-3.3-8.6z',
  detail:['M7.5 15.5c2 .4 3.8 0 5.2-1','M14 11c-1.6-.9-3.4-1.3-5.4-1.2'],accent:[]},
 smooth:{name:'Smooth',tint:'#5ed6c4',
  body:'M17.5 12.5a7 7 0 1 1-14 0a7 7 0 1 1 14 0z',
  shade:'M16.9 9.7a7 7 0 0 1-12.8 6.7 8.4 8.4 0 0 0 12.8-6.7z',
  detail:['M7.2 9.8a4.2 4.2 0 0 1 2.4-1.9'],accent:['M19.6 8a8.6 8.6 0 0 1 0 9','M22.2 6.4a11.4 11.4 0 0 1 0 12.2']},
 grab:{name:'Grab',tint:'#c99bff',
  body:'M2 21c3.5-.4 5.5-2 6.8-5 1.2-2.6 1.6-6.2 3.4-9 .7-1.1 1.8-1.8 2.8-1.6-.7 2-.6 4.6.3 7.2 1 3 2.8 5.6 6.1 6.9L22 21z',
  shade:'M15 5.4c-.7 2-.6 4.6.3 7.2 1 3 2.8 5.6 6.1 6.9-3 .5-5.6-1.4-6.8-4.4-.9-2.4-.8-6.2.4-9.7z',
  detail:['M9 15.5c1-2.4 1.5-5.4 2.8-7.8'],accent:['M19.5 10.5V3.5','M17 6l2.5-2.5L22 6']},
};
const LINE='stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"';
const lines=(a,extra='')=>a.map(d=>`<path d="${d}" fill="none" ${LINE} ${extra}/>`).join('');
const svg=(inner,s)=>`<svg xmlns="http://www.w3.org/2000/svg" width="${s}" height="${s}" viewBox="0 0 24 24">${inner}</svg>`;
const STYLES={
 A:{title:'A. Line only',note:'Lucide weight, ink only. Sits exactly with the rest of the app.',
  f:b=>`<path d="${b.body}" fill="none" ${LINE}/>`+lines(b.detail)+lines(b.accent)},
 B:{title:'B. Line + clay',note:'Lucide outline, flat clay fill and one flat shade: the clay colour of our viewport.',
  f:b=>`<path d="${b.body}" fill="#d3a690"/><path d="${b.shade}" fill="#a87563"/><path d="${b.body}" fill="none" ${LINE}/>`+lines(b.detail,'stroke-width="1.25" stroke-opacity=".55"')+lines(b.accent)},
 C:{title:'C. Line + clay on a tinted disc',note:'B on a soft disc in its family colour (the Lens tints), the reference set\'s colour coding toned down.',
  f:b=>`<circle cx="12" cy="12" r="11.5" fill="${b.tint}" fill-opacity=".22"/><g transform="translate(12 12) scale(.82) translate(-12 -12)"><path d="${b.body}" fill="#d3a690"/><path d="${b.shade}" fill="#a87563"/><path d="${b.body}" fill="none" ${LINE}/>${lines(b.detail,'stroke-width="1.25" stroke-opacity=".55"')}${lines(b.accent,`stroke="${b.tint}"`)}</g>`},
 D:{title:'D. Soft clay, ink accents',note:'Shaded clay with no outline, like the stroke pictures; only the motion is drawn in line.',
  f:(b,k)=>`<defs><linearGradient id="g${k}" x1=".15" y1=".1" x2=".85" y2=".95"><stop offset="0" stop-color="#ead0c2"/><stop offset=".6" stop-color="#c9967f"/><stop offset="1" stop-color="#94604c"/></linearGradient></defs><path d="${b.body}" fill="url(#g${k})"/><path d="${b.shade}" fill="#7d4f3e" fill-opacity=".45"/>`+lines(b.detail,'stroke="#fff" stroke-opacity=".45" stroke-width="1.1"')+lines(b.accent)},
};
// Write every SVG.
let n=0;for(const [sk,st] of Object.entries(STYLES))for(const [bk,b] of Object.entries(B)){fs.writeFileSync(`${OUT}${sk}-${bk}.svg`,svg(st.f(b,sk+bk+(n++)),24).replace('<svg ','<svg fill="none" ')); }
// The Lens theme's shelf, with two existing Lucide tiles beside them for context.
const T={frame:'#0d0f12',surface:'#161a1f',text:'#e9ecef',sec:'#a7aeb8',chosen:'#1c3b37',onChosen:'#5ed6c4',border:'#2a3038'};
const tile=(icon,name,on)=>`<div class="tile ${on?'on':''}"><div class="ic">${icon}</div><div class="nm">${name}</div></div>`;
const lu=(cp,name)=>tile(`<span class="lu">&#x${cp};</span>`,name,false);
let rows='';let k=0;
for(const [sk,st] of Object.entries(STYLES)){
 const big=Object.values(B).map(b=>svg(st.f(b,'big'+(k++)),72)).join('');
 const tiles=Object.entries(B).map(([bk,b],i)=>tile(svg(st.f(b,'t'+(k++)),20),b.name,i==0)).join('');
 rows+=`<div class="row"><div class="lab"><b>${st.title}</b><span>${st.note}</span></div><div class="big">${big}</div><div class="shelf">${tiles}${lu('e349','Inflate')}${lu('e220','Pinch')}${lu('e522','Crease')}</div></div>`;
}
const html=`<html><head><style>@font-face{font-family:Lu;src:url(file:///home/user/Implicit_sculpt_modeler/assets/fonts/Lucide.ttf)}
body{margin:0;background:${T.frame};font:13px Inter,system-ui,sans-serif;color:${T.text};padding:20px 28px}
.row{display:grid;grid-template-columns:230px 260px 1fr;align-items:center;gap:24px;padding:16px 0;border-bottom:1px solid ${T.border}}
.lab b{display:block;font-size:14px;margin-bottom:4px}.lab span{color:${T.sec};font-size:12px;line-height:1.4}
.big{display:flex;gap:14px;color:${T.text}}
.shelf{display:flex;gap:0;background:${T.surface};border:1px solid ${T.border};border-radius:14px;padding:6px 8px;width:max-content}
.tile{width:64px;height:58px;display:flex;flex-direction:column;align-items:center;border-radius:10px;color:${T.sec}}
.tile.on{background:${T.chosen};color:${T.onChosen}}.ic{height:30px;display:flex;align-items:center;justify-content:center;margin-top:4px}
.nm{font-size:11px}.lu{font-family:Lu;font-size:20px}</style></head><body>${rows}</body></html>`;
fs.writeFileSync(OUT+'sheet.html',html);
(async()=>{const br=await chromium.launch();const p=await br.newPage({viewport:{width:1080,height:400},deviceScaleFactor:2});
await p.goto('file://'+OUT+'sheet.html');await p.waitForTimeout(300);await p.screenshot({path:OUT+'variants.png',fullPage:true});await br.close();})();
