const fs=require('fs');const {chromium}=require('playwright');
const D='/mnt/project-files/notes/icons/glossy/';
// Every brush, in the Library's categories: Clay, Crease, Smooth, Move, Cloth, Mask, Paint, History.
const B=[['draw','Draw'],['clay','Clay'],['inflate','Inflate'],['layer','Layer'],['clay_strips','Clay strips'],['crease','Crease'],['pinch','Pinch'],['smooth','Smooth'],['flatten','Flatten'],
['trim','Trim dynamic'],['grab','Grab'],['snake','Snake hook'],['elastic','Elastic'],['cloth','Cloth'],['mask','Mask'],['paint','Paint'],['history','History'],['morph','Morph']];
// Pinch's arrows are drawn over the render: its pull has no surface of its own to colour.
const arrow=(x,dir)=>`<g transform="translate(${x} 24) scale(${dir} 1)"><path d="M-5 -2.2h4v-3.4l5.6 5.6-5.6 5.6v-3.4h-4z" fill="#ff6b6e" stroke="#ffd0d1" stroke-width=".8" stroke-linejoin="round"/></g>`;
// History's mark: a turning-back arrow round the ball's lower left, as undo draws it.
const OVER={pinch:arrow(6.5,1)+arrow(41.5,-1),
 history:'<path d="M8.5 31a17 17 0 0 0 22 9" fill="none" stroke="#bff3ea" stroke-width="2.4" stroke-linecap="round"/><path d="M4.6 30.4 8.4 26.2l3.4 4.6z" fill="#bff3ea" stroke="#bff3ea" stroke-width="1.4" stroke-linejoin="round"/>'};
const svg=(n,s)=>`<svg xmlns="http://www.w3.org/2000/svg" width="${s}" height="${s}" viewBox="0 0 48 48"><image href="data:image/png;base64,${fs.readFileSync(D+n+'.png').toString('base64')}" width="48" height="48"/>${OVER[n]||''}</svg>`;
for(const [n] of B)fs.writeFileSync(D+n+'.svg',svg(n,48));
const T={frame:'#0d0f12',surface:'#161a1f',text:'#e9ecef',sec:'#a7aeb8',chosen:'#1c3b37',onChosen:'#5ed6c4',border:'#2a3038'};
const grid=B.map(([n,l])=>`<div class="cell">${svg(n,130)}<div>${l}</div></div>`).join('');
const tl=(icon,name,on)=>`<div class="tile ${on?'on':''}"><div class="ic">${icon}</div><div class="nm">${name}</div></div>`;
const shelf=B.slice(0,12).map(([n,l],j)=>tl(svg(n,32),l,j==0)).join('');
const small=B.map(([n])=>[20,26].map(s=>svg(n,s)).join('')).join('<span style="width:10px"></span>');
const html=`<html><head><style>body{margin:0;background:${T.frame};font:13px Inter,system-ui,sans-serif;color:${T.text};padding:24px 28px}
.grid{display:grid;grid-template-columns:repeat(9,130px);gap:4px;margin-bottom:22px}.cell{display:flex;flex-direction:column;align-items:center;gap:2px;color:${T.sec}}
.small{display:flex;gap:4px;align-items:flex-end;margin-bottom:16px}
.shelf{display:flex;background:${T.surface};border:1px solid ${T.border};border-radius:14px;padding:6px 8px;width:max-content}
.tile{width:64px;height:58px;display:flex;flex-direction:column;align-items:center;border-radius:10px;color:${T.sec}}
.tile.on{background:${T.chosen};color:${T.onChosen}}.ic{height:36px;display:flex;align-items:center;justify-content:center;margin-top:2px}
.nm{font-size:11px;white-space:nowrap;overflow:hidden;max-width:62px;text-overflow:ellipsis}</style></head><body><div class="grid">${grid}</div><div class="small">${small}</div><div class="shelf">${shelf}</div></body></html>`;
fs.writeFileSync(D+'sheet.html',html);
(async()=>{const br=await chromium.launch();const p=await br.newPage({viewport:{width:1300,height:300},deviceScaleFactor:2});
await p.goto('file://'+D+'sheet.html');await p.waitForTimeout(300);await p.screenshot({path:D+'glossy.png',fullPage:true});await br.close();})();
