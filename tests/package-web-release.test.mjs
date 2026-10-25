import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,access,readdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';

test('release package has compiled web, source, assets, license and no local data',async()=>{
  const temp=await mkdtemp(join(tmpdir(),'docleaf-web-package-test-'));
  const bridge=join(temp,'bridge-fixture');await writeFile(bridge,'test fixture');
  const output=join(temp,'DocLeaf-Sync');
  execFileSync(process.execPath,['scripts/package-web-release.mjs',output,bridge],{cwd:new URL('../',import.meta.url)});
  for(const file of ['dist/server/index.js','app/sync/client.ts','integrations/fqapp/rust/Cargo.lock','integrations/fqapp/LICENSE','一键启动.command','一键启动-Windows.bat','sync/binary-assets.json','运行说明.txt'])await access(join(output,file));
  const binary=join(output,'integrations/fqapp',process.platform==='win32'?'docleaf_bridge.exe':'docleaf_bridge');
  assert.equal(await readFile(binary,'utf8'),'test fixture');
  const files=await readdir(output);
  for(const name of ['node_modules','.git','.env','outputs','work','android-app'])assert.ok(!files.includes(name));
  await assert.rejects(access(join(output,'integrations/fqapp/rust/target')));
  assert.match(await readFile(join(output,'一键启动.command'),'utf8'),/npm run start/);
  assert.throws(()=>execFileSync(process.execPath,['scripts/package-web-release.mjs',output,bridge],{cwd:new URL('../',import.meta.url),stdio:'pipe'}));
});
