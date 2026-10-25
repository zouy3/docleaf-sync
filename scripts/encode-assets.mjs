// Generated asset transport for text-only GitHub MCP uploads. Never includes
// credentials, native libraries, build output, or ignored local files.
import {execFileSync} from 'node:child_process';
import {existsSync,mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
let previous=existsSync('sync/binary-assets.json')?JSON.parse(readFileSync('sync/binary-assets.json','utf8')):{files:{}};
if(previous.version===2)previous=JSON.parse(previous.parts.map(path=>readFileSync('sync/'+path,'utf8')).join(''));
const old=previous.files;
const paths=new Set([...Object.keys(old),...execFileSync('git',['ls-files','--cached','--others','--exclude-standard','-z'],{encoding:'utf8'}).split('\0').filter(Boolean)]);
const files={};
for(const path of paths){
  if(!/\.(png|webp|woff2|ico)$/.test(path))continue;
  const bytes=readFileSync(path);
  files[path]={sha256:createHash('sha256').update(bytes).digest('hex'),base64:bytes.toString('base64')};
}
const serialized=JSON.stringify({version:1,files}),parts=[];
mkdirSync('sync/binary-assets',{recursive:true});
for(let start=0;start<serialized.length;start+=64000){
  const name='binary-assets/'+String(parts.length).padStart(3,'0')+'.part';
  writeFileSync('sync/'+name,serialized.slice(start,start+64000));parts.push(name);
}
writeFileSync('sync/binary-assets.json',JSON.stringify({version:2,parts,sha256:createHash('sha256').update(serialized).digest('hex')}));
console.log('Encoded',Object.keys(files).length,'source assets');
