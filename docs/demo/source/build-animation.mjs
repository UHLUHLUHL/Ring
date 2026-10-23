import { createRequire } from 'node:module';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
const require = createRequire(process.env.NODE_PATH ? resolve(process.env.NODE_PATH.split(':')[0], '../package.json') : import.meta.url);
const sharp = require('sharp');
const root = resolve(import.meta.dirname, '..');
const W=1440, H=960, FPS=30, END=720;
const assets=[], layers=[];
let index=0;
const fixed = k => ({a:0,k});
const ease = {i:{x:[0.68],y:[1]},o:{x:[0.22],y:[0]}};
function keys(points) {
  return {a:1,k:points.map(([t,s],i)=>i===points.length-1 ? {t,s:Array.isArray(s)?s:[s]} : {t,s:Array.isArray(s)?s:[s],...ease})};
}
function fade(start,end,inFrames=5,outFrames=5) {
  return keys([[start,0],[start+inFrames,100],[end-outFrames,100],[end,0]]);
}
function transform({x=0,y=0,anchor=[0,0,0],scale=100,opacity=100,position}={}) {
  return {o:typeof opacity==='object'?opacity:fixed(opacity),r:fixed(0),p:position||fixed([x,y,0]),a:fixed(anchor),s:typeof scale==='object'?scale:fixed([scale,scale,100])};
}
async function asset(name,buffer) {
  const bytes=buffer||await readFile(resolve(root,'source/backplate',name+'.png'));
  const m=await sharp(bytes).metadata();
  const id='asset_'+assets.length;
  assets.push({id,w:m.width,h:m.height,u:'',p:'data:image/png;base64,'+bytes.toString('base64'),e:1});
  return id;
}
function image(name,ref,start=0,end=END,opts={}) {
  layers.push({ddd:0,ind:++index,ty:2,nm:name,refId:ref,sr:1,ks:transform(opts),ao:0,ip:start,op:end,st:0,bm:0});
}
function shape(name,shapes,start,end,opts={}) {
  layers.push({ddd:0,ind:++index,ty:4,nm:name,sr:1,ks:transform(opts),ao:0,ip:start,op:end,st:0,bm:0,shapes});
}
function stroke(c,w){return {ty:'st',c:fixed(c),o:fixed(100),w:fixed(w),lc:2,lj:2,ml:4};}
const fill=c=>({ty:'fl',c:fixed(c),o:fixed(100),r:1});
const rect=(w,h,r=0)=>({ty:'rc',d:1,s:fixed([w,h]),p:fixed([0,0]),r:fixed(r)});
const ellipse=(d)=>({ty:'el',d:1,s:fixed([d,d]),p:fixed([0,0])});
function click(t,x,y,right=false){
  shape(right?'Right click':'Click',[ellipse(44),stroke(right?[.83,.90,1,1]:[.35,.74,1,1],2.5)],t,t+15,{x,y,opacity:keys([[t,80],[t+15,0]]),scale:keys([[t,[35,35,100]],[t+15,[150,150,100]]])});
}

image('Finder desktop',await asset('background'));
const jpg=await asset('jpg'),webp=await asset('webp'),menu=await asset('context-menu');
for (const [n,a,b] of [[1,0,230],[2,230,588],[3,588,END]]) image('Step '+n,await asset('caption-'+n),a,b,{opacity:fade(a,b)});
image('PNG context menu',menu,54,97,{opacity:fade(54,97,4,3)});
image('Video context menu',menu,245,281,{y:140,opacity:fade(245,281,4,3)});
image('JPG saved beside source',jpg,191,END,{opacity:keys([[191,0],[203,100]])});
image('WebP saved beside source',webp,584,END,{opacity:keys([[584,0],[596,100]])});

const ringTop=[730,283];
const crops={1:'Image ring',2:'JPG hover',3:'Native success',4:'Video ring',5:'WebP hover'};
const rings={};
for(const n of [1,2,3,4,5]){
  const bytes=await readFile(resolve(root,'source/captures/native-'+n+'.png'));
  const m=await sharp(bytes).metadata(),ratio=m.width/560;
  const cropped=await sharp(bytes).extract({left:Math.round(80*ratio),top:Math.round(130*ratio),width:Math.round(400*ratio),height:Math.round(400*ratio)}).resize(440,440).png().toBuffer();
  rings[n]=await asset(crops[n],cropped);
}
const ringOpts=(a,b)=>({x:ringTop[0],y:ringTop[1],opacity:fade(a,b,5,4)});
image('Open image ring',rings[1],97,142,{...ringOpts(97,142),x:950,y:503,anchor:[220,220,0],scale:keys([[97,[92,92,100]],[106,[101,101,100]],[113,[100,100,100]]])});
image('Hover JPG',rings[2],136,165,ringOpts(136,165));
image('Image saved check',rings[3],174,202,ringOpts(174,202));
image('Open video ring',rings[4],281,328,{...ringOpts(281,328),x:950,y:503,anchor:[220,220,0],scale:keys([[281,[92,92,100]],[290,[101,101,100]],[297,[100,100,100]]])});
image('Hover WEBP',rings[5],321,350,ringOpts(321,350));
image('Video saved check',rings[3],570,600,ringOpts(570,600));

for(const [file,a,b] of [['panel-640',350,446],['panel-480',443,548]]) {
  const bytes=await readFile(resolve(root,'source/captures/'+file+'.png'));
  const m=await sharp(bytes).metadata(),ratio=m.width/560;
  const cropped=await sharp(bytes).extract({left:Math.round(24*ratio),top:Math.round(26*ratio),width:Math.round(512*ratio),height:Math.round(674*ratio)}).resize(490,645).png().toBuffer();
  image(file,await asset(file,cropped),a,b,{x:705,y:160,opacity:fade(a,b,5,4)});
}

// This is a paced illustration, not a conversion benchmark.
for(const [a,b] of [[165,177],[548,573]]){
  shape('Processing hub background',[ellipse(145),fill([.15,.19,.24,1])],a,b,{x:950,y:470});
  shape('Processing progress',[ellipse(144),stroke([.13,.55,1,1],3),{ty:'tm',s:fixed(0),e:keys([[a,0],[b,95]]),o:fixed(-90),m:1}],a,b,{x:950,y:470});
}
const badgeSvg=`<svg xmlns="http://www.w3.org/2000/svg" width="440" height="70"><rect width="440" height="70" rx="35" fill="#182433"/><path d="M38 25l14 10-14 10zm17 0l14 10-14 10z" fill="#c3d7ec"/><text x="250" y="44" font-family="Apple SD Gothic Neo" font-size="23" font-weight="600" text-anchor="middle" fill="#c3d7ec">처리 구간 빠르게 재생</text></svg>`;
const badge=await asset('Processing accelerated',await sharp(Buffer.from(badgeSvg)).png().toBuffer());
image('Accelerated processing label',badge,548,573,{x:730,y:575,opacity:fade(548,573,2,2)});

// Full visible pointer path. Dwell around every click gives the viewer time to follow it.
const pointerPoints=[
 [0,[1210,690,0]],[12,[1210,690,0]],[45,[490,375,0]],[58,[490,375,0]],
 [80,[629,529,0]],[97,[629,529,0]],[132,[950,348,0]],[164,[950,348,0]],
 [188,[1080,605,0]],[210,[1080,605,0]],[240,[490,560,0]],[251,[490,560,0]],
 [272,[629,669,0]],[281,[629,669,0]],[318,[950,585,0]],[347,[950,585,0]],
 [382,[1100,588,0]],[418,[1100,588,0]],[440,[1038,676,0]],[455,[1038,676,0]],
 [497,[1148,768,0]],[548,[1148,768,0]],[577,[1210,720,0]],[END,[1210,720,0]]
];
const vertices=[[0,0],[0,31],[7.9,23.4],[14.2,37.8],[20.7,34.9],[14.2,21.3],[25,21.1]];
const path={c:true,v:vertices,i:vertices.map(()=>[0,0]),o:vertices.map(()=>[0,0])};
shape('macOS pointer',[{ty:'sh',ks:fixed(path)},fill([.035,.043,.055,1]),stroke([1,1,1,1],2)],0,END,{position:keys(pointerPoints),scale:keys([[0,[105,105,100]],[48,[105,105,100]],[52,[92,92,100]],[57,[105,105,100]],[END,[105,105,100]]])});
for(const [t,x,y,right] of [[52,490,375,true],[95,629,529],[161,950,348],[243,490,560,true],[279,629,669],[345,950,585],[443,1038,676],[546,1148,768]]) click(t,x,y,right);

// Lottie paints the first layer last; reverse our back-to-front authoring order.
const animation={v:'5.13.0',fr:FPS,ip:0,op:END,w:W,h:H,nm:'Ring 0.2.6 — image to JPG, video to WebP',ddd:0,assets,layers:layers.reverse(),markers:[
 {tm:0,cm:'Image → JPG',dr:230},{tm:230,cm:'Video → WEBP · 640 → 480px',dr:318},
 {tm:548,cm:'Processing accelerated; timing is illustrative',dr:25},{tm:588,cm:'Originals preserved',dr:132}
],meta:{g:'Ring documentation capture + deterministic Lottie authoring',sourceCommit:'4f3ae6d6937f29bbd41c0b7844ecf3666ddc61ec',note:'Native production views; composed Finder; animated pointer; accelerated processing, not a benchmark.'}};
await writeFile(resolve(root,'ring-demo.json'),JSON.stringify(animation));
await writeFile(resolve(root,'animation-data.js'),'window.RING_DEMO='+JSON.stringify(animation)+';\n');
console.log(JSON.stringify({frames:END,seconds:END/FPS,assets:assets.length,layers:layers.length}));
