import {cp,mkdir,access,writeFile,chmod} from 'node:fs/promises';
import {resolve,join,basename} from 'node:path';
import {fileURLToPath} from 'node:url';

const root=fileURLToPath(new URL('../',import.meta.url));
const [outputArg,bridgeArg]=process.argv.slice(2);
if(!outputArg||!bridgeArg)throw Error('Usage: node scripts/package-web-release.mjs <new-output-directory> <bridge-binary>');
const output=resolve(outputArg),bridge=resolve(bridgeArg);
await access(bridge);
// A fresh folder only: never merge stale packages or overwrite user data.
await mkdir(output,{recursive:false});
async function copy(path){
  await mkdir(resolve(output,path,'..'),{recursive:true});
  await cp(join(root,path),join(output,path),{recursive:true,filter:source=>!['target','node_modules','.git','.DS_Store','device_pool.json','.docleaf-data'].includes(basename(source))});
}
for(const path of ['app','public','db','drizzle','worker','examples','tests','sync',
  '.openai/hosting.json','build/sites-vite-plugin.ts','scripts',
  'integrations/fqapp/rust','integrations/fqapp/assets','integrations/fqapp/.cargo','integrations/fqapp/LICENSE',
  'package.json','package-lock.json','README.md','next.config.ts','vite.config.ts','tsconfig.json',
  'eslint.config.mjs','postcss.config.mjs','drizzle.config.ts','start-docleaf.ps1','setup-and-start-docleaf.ps1',
  '一键启动-Windows.bat','一键启动.command','dist'])await copy(path);
await cp(bridge,join(output,'integrations/fqapp',process.platform==='win32'?'docleaf_bridge.exe':'docleaf_bridge'));
if(process.platform!=='win32'){
  await chmod(join(output,'一键启动.command'),0o755);
  await chmod(join(output,'integrations/fqapp/docleaf_bridge'),0o755);
}
await writeFile(join(output,'运行说明.txt'),[
  'DocLeaf Sync · 网页同步试用版',
  'Windows：完整解压后双击 一键启动-Windows.bat。缺少 Node.js 时会通过 winget 安装。',
  'macOS：需要 Node.js 22.13+；在终端运行 bash 一键启动.command，或右键启动文件选择打开。',
  '此包已带番茄书源，不需要 Rust、Flutter 或 Visual Studio。',
  '首次安装网页依赖需要联网，之后可离线阅读已缓存正文；在线书源和云同步仍需网络。',
  '先关闭旧版 DocLeaf 的服务，再启动此包，避免 localhost:3000 仍然打开旧版。',
  '访问 http://localhost:3000/。关闭启动终端会停止服务。',
  '账号同步：与安卓版、股票工具登录同一账号；书籍正文和评论不整体上传。',
  '这是试用版，双端续读仍需实际验收。不要删除旧书架或卸载旧安卓软件。',
  '包含核心源码及 GPL-3.0 许可证；不包含用户书架、账号密码、令牌和签名私钥。',
].join('\n')+'\n');
console.log('Web release folder ready:',output);
