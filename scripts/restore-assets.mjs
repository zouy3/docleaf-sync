import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
let manifest=JSON.parse(await readFile(new URL('../sync/binary-assets.json',import.meta.url),'utf8'));
if(manifest.version===2){
  let serialized='';
  for(const part of manifest.parts){
    if(!/^binary-assets\/[0-9]+\.part$/.test(part))throw Error('Unsafe asset part');
    serialized+=await readFile(new URL('../sync/'+part,import.meta.url),'utf8');
  }
  if(createHash('sha256').update(serialized).digest('hex')!==manifest.sha256)throw Error('Corrupt asset manifest');
  manifest=JSON.parse(serialized);
}
if(manifest.version!==1)throw Error('Unknown source asset format');
for(const [path,entry] of Object.entries(manifest.files)){
  if(!/^(android-app|integrations\/fqapp)\/[a-zA-Z0-9_./-]+\.(png|webp|woff2|ico)$/.test(path)||path.split('/').includes('..'))throw Error('Unsafe asset path');
  const bytes=Buffer.from(entry.base64,'base64'),target=resolve(root,path);
  if(createHash('sha256').update(bytes).digest('hex')!==entry.sha256)throw Error('Corrupt asset: '+path);
  let old;try{old=await readFile(target);}catch(error){if(error.code!=='ENOENT')throw error;}
  if(old){if(!old.equals(bytes))throw Error('Existing asset differs; preserve your changes: '+path);continue;}
  await mkdir(dirname(target),{recursive:true});await writeFile(target,bytes,{flag:'wx'});
}
console.log('[DocLeaf Sync] Source assets ready');
