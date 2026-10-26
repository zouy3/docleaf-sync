// Run after APK signing and verification. Upload both APKs first, then this
// manifest LAST to the same new GitHub Release; web-only releases need no file.
import {readFile,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';
const folder=resolve(process.argv[2]||'outputs/android-update');
const spec=await readFile(new URL('../android-app/pubspec.yaml',import.meta.url),'utf8');
const version=spec.match(/^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$/m);
if(!version)throw Error('Invalid Android pubspec version');
const assets=[];
for(const abi of ['arm64-v8a','armeabi-v7a']){
  const name=`DocLeaf-Sync-${version[1]}-${abi}.apk`;
  const bytes=await readFile(resolve(folder,name));
  if(bytes[0]!==0x50||bytes[1]!==0x4b)throw Error('Not an APK ZIP: '+name);
  assets.push({abi,name,size:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')});
}
const manifest={schema:1,packageName:'com.fqapp.fqapp',versionName:version[1],versionCode:Number(version[2]),assets};
await writeFile(resolve(folder,'android-update.json'),JSON.stringify(manifest,null,2)+'\n',{flag:'wx'});
console.log('Created android-update.json for',version[1],version[2]);
