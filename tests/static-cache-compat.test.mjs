import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {normalizeStaticCache} from '../scripts/vinext-static-cache-compat.mjs';

test('Windows cache keys become URL paths without changing disk paths or headers',()=>{
  const entry={original:{path:'C:\\reader\\dist\\client\\assets\\app.css',headers:{'Content-Type':'text/css'}}};
  const cache={entries:new Map([['/assets\\app.css',entry],['/.vite\\manifest.json',{}],['/.VITE/secret.json',{}]])};
  normalizeStaticCache(cache);
  assert.equal(cache.entries.get('/assets/app.css'),entry);
  assert.equal(entry.original.path,'C:\\reader\\dist\\client\\assets\\app.css');
  assert.equal(cache.entries.size,1);
  normalizeStaticCache(cache);assert.equal(cache.entries.size,1);
});
test('POSIX resource keys stay unchanged and unsupported caches fail explicitly',()=>{
  const entry={};const cache={entries:new Map([['/assets/app.js',entry]])};
  assert.equal(normalizeStaticCache(cache).entries.get('/assets/app.js'),entry);
  assert.throws(()=>normalizeStaticCache({}),/Unsupported/);
});
test('production HTML actually loads CSS and JavaScript',()=>{
  execFileSync(process.execPath,['scripts/check-production-assets.mjs'],{cwd:new URL('../',import.meta.url),timeout:45000,stdio:'pipe'});
});
