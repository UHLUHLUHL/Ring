import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { readFile,writeFile,mkdir } from 'node:fs/promises';
import { resolve,extname } from 'node:path';
import { spawn } from 'node:child_process';
const require=createRequire(process.env.NODE_PATH?resolve(process.env.NODE_PATH.split(':')[0],'../package.json'):import.meta.url);
const {chromium}=require('playwright');
const root=resolve(import.meta.dirname,'..'),work=resolve(root,'../../.work/usage-demo/frames');
await mkdir(work,{recursive:true});
const mime={'.html':'text/html','.js':'text/javascript','.json':'application/json','.png':'image/png','.webp':'image/webp'};
const server=createServer(async(req,res)=>{try{const file=resolve(root,'.'+decodeURIComponent(req.url.split('?')[0]==='/'?'/index.html':req.url.split('?')[0]));if(!file.startsWith(root+'/'))throw Error();res.setHeader('Content-Type',mime[extname(file)]||'application/octet-stream');res.end(await readFile(file));}catch{res.writeHead(404);res.end()}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const browser=await chromium.launch({headless:true,executablePath:process.env.RING_DEMO_CHROME||'/Applications/Chrome.app/Contents/MacOS/Google Chrome'});
try{
 const page=await browser.newPage({viewport:{width:1440,height:1040},deviceScaleFactor:1});
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto('http://127.0.0.1:'+server.address().port+'/?canvas');
 await page.waitForFunction(()=>window.demoReady);
 await page.evaluate(()=>{demoAnimation.pause();demoAnimation.setSubframe(true)});
 const fps=24,count=24*fps,args=['-loop','0','-mixed','-q','84','-m','4'];
 for(let i=0;i<count;i++){
  const data=await page.evaluate(f=>window.renderDemoFrame(f),i*30/fps);
  const file=resolve(work,String(i).padStart(4,'0')+'.png');
  await writeFile(file,Buffer.from(data.split(',')[1],'base64'));
  args.push('-d',String(Math.round((i+1)*1000/fps)-Math.round(i*1000/fps)),file);
  if(i%120===0)console.log('Rendered '+i+'/'+count);
 }
 args.push('-o',resolve(root,'ring-demo.webp'));
 if(errors.length)throw Error(errors.join('\n'));
 await writeFile(resolve(work,'encode-args.json'),JSON.stringify(args));
 const encoder=spawn('img2webp',args,{stdio:'inherit'});await new Promise((r,j)=>{encoder.on('error',j);encoder.on('exit',c=>c?j(Error('img2webp exit '+c)):r())});
 const metadata={seconds:24,frames:count,width:1440,height:960,exportFPS:fps,lottieFPS:30,browserErrors:errors,sourceCommit:'4f3ae6d6937f29bbd41c0b7844ecf3666ddc61ec'};
 await writeFile(resolve(root,'validation.json'),JSON.stringify(metadata,null,2)+'\n');
 console.log(JSON.stringify(metadata));
}finally{await browser.close();server.close()}
