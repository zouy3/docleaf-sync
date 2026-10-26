// Run after APK signing and verification. Upload both APKs first, then this
// manifest LAST to the same new GitHub Release; web-only releases need no file.
import {readFile,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const folder=resolve(process.argv[2]||'outputs/android-update');
const sdk=process.env.ANDROID_HOME||process.env.ANDROID_SDK_ROOT;
if(!sdk)throw Error('ANDROID_HOME is required to inspect actual split APK versions');
const aapt=resolve(sdk,'build-tools/36.0.0',process.platform==='win32'?'aapt.exe':'aapt');
const spec=await readFile(new URL('../android-app/pubspec.yaml',import.meta.url),'utf8');
const version=spec.match(/^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$/m);
if(!version)throw Error('Invalid Android pubspec version');
const assets=[];
for(const abi of ['arm64-v8a','armeabi-v7a']){
  const name=`DocLeaf-Sync-${version[1]}-${abi}.apk`;
  const bytes=await readFile(resolve(folder,name));
  if(bytes[0]!==0x50||bytes[1]!==0x4b)throw Error('Not an APK ZIP: '+name);
  const info=execFileSync(aapt,['dump','badging',resolve(folder,name)],{encoding:'utf8'}).match(/package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'/);
  if(!info||info[1]!=='com.fqapp.fqapp'||info[3]!==version[1]||Number(info[2])<Number(version[2]))throw Error('APK identity/version mismatch: '+name);
  assets.push({abi,name,versionCode:Number(info[2]),size:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')});
}
const manifest={schema:1,packageName:'com.fqapp.fqapp',versionName:version[1],versionCode:Number(version[2]),assets};
await writeFile(resolve(folder,'android-update.json'),JSON.stringify(manifest,null,2)+'\n',{flag:'wx'});
console.log('Created android-update.json for',version[1],version[2]);
