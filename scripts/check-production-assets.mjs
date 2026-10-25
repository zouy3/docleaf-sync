import {spawn} from 'node:child_process';
import {resolve} from 'node:path';
import {readFile} from 'node:fs/promises';

const root = resolve(process.argv[2] || '.');
const pkg = JSON.parse(await readFile(resolve(root,'package.json'),'utf8'));
if(pkg.scripts.start !== 'node scripts/start-reader.mjs')throw Error('Production launcher is not the compatibility launcher');
const child = spawn(process.execPath,[resolve(root,'scripts/start-reader.mjs'),'--port','0'],{cwd:root,stdio:['ignore','pipe','pipe']});
let output='';
const exited = new Promise(resolveExit=>child.once('exit',(code,signal)=>resolveExit({code,signal})));
try{
  const base = await new Promise((done,fail)=>{
    const timer=setTimeout(()=>fail(Error('Server startup timed out: '+output)),30000);
    const inspect=data=>{output+=data.toString();const match=output.match(/Production server running at (http:\/\/127\.0\.0\.1:\d+)/);if(match){clearTimeout(timer);done(match[1]);}};
    child.stdout.on('data',inspect);child.stderr.on('data',inspect);
    child.once('error',error=>{clearTimeout(timer);fail(error);});
    child.once('exit',code=>{clearTimeout(timer);fail(Error('Server exited '+code+': '+output));});
  });
  const htmlResponse=await fetch(base,{signal:AbortSignal.timeout(10000)});
  if(htmlResponse.status!==200)throw Error('HTML status '+htmlResponse.status);
  const html=await htmlResponse.text();
  const css=[...new Set([...html.matchAll(/<link\b[^>]*href="([^\"]+\.css)"/g)].map(m=>m[1]))];
  const scripts=[...new Set(html.match(/\/assets\/[A-Za-z0-9_.-]+\.js/g)||[])];
  if(!css.length||!scripts.length)throw Error('Page is missing CSS or JavaScript references');
  for(const path of [...css,...scripts]){
    const response=await fetch(new URL(path,base),{signal:AbortSignal.timeout(10000)});
    const type=response.headers.get('content-type')||'',body=await response.text();
    const cssFile=path.endsWith('.css');
    if(response.status!==200 || !(cssFile?/^text\/css\b/:/^(application|text)\/javascript\b/).test(type) || body.length<100 || /^\s*<!doctype/i.test(body))throw Error('Invalid production asset: '+path+' '+response.status+' '+type);
    console.log('PASS',path,response.status,type);
  }
  const privateManifest=await fetch(base+'/.vite/manifest.json',{signal:AbortSignal.timeout(10000)});
  if(privateManifest.status===200)throw Error('Private Vite manifest must not be served');
  console.log('PASS: HTML, stylesheet, JavaScript and private-manifest guard on '+process.platform);
}finally{
  child.kill();
  await Promise.race([exited,new Promise(resolveWait=>{const timer=setTimeout(()=>{child.kill('SIGKILL');resolveWait();},5000);timer.unref();})]);
}
