import {test,afterEach} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {transpileModule,ModuleKind} from 'typescript';

const source=transpileModule(readFileSync(new URL('../app/sync/client.ts',import.meta.url),'utf8'),{compilerOptions:{module:ModuleKind.ESNext}}).outputText;
const {ReadingSync,accountEmail,canonicalText,positionQuote}=await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
const clients=[];
afterEach(()=>{for(const client of clients)client.logout();clients.length=0;});
const book={book_id:'123',title:'测试书籍',author:'作者',cover:''};
const cursor=(offset)=>({version:1,chapter_id:'456',chapter_index:0,chapter_title:'第一章',paragraph_id:'1',ordinal:0,character_offset:offset,quote:'中文正文'});
function environment(){
  const storage=new Map(), rows=new Map();
  globalThis.localStorage={getItem:key=>storage.get(key)??null,setItem:(key,value)=>storage.set(key,String(value)),removeItem:key=>storage.delete(key)};
  let offline=false, pause=null;
  globalThis.fetch=async(url,options={})=>{
    if(offline)throw Error('offline');
    const payload=options.body?JSON.parse(options.body):null;
    const uid=options.headers?.Authorization?.replace('Bearer ','');
    let result;
    if(url.includes('/auth/'))result={access_token:payload.email,refresh_token:'refresh',expires_in:3600,user:{id:payload.email}};
    else if(url.includes('/rpc/')){
      const key=uid+':'+payload.p_book_id;
      const old=rows.get(key);
      if(payload.p_cursor&&old&&old.revision!==payload.p_expected_revision)result={status:'conflict',row:old};
      else {const row={...book,book_id:payload.p_book_id,cursor:payload.p_cursor??old?.cursor??null,revision:(old?.revision??0)+1,device_id:payload.p_device_id,updated_at:new Date().toISOString()};rows.set(key,row);result={status:'saved',row};}
      if(pause){const wait=pause;pause=null;await wait;}
    }else result=[...rows.entries()].filter(([key])=>key.startsWith(uid+':')).map(([,row])=>row);
    return new Response(JSON.stringify(result),{status:200,headers:{'Content-Type':'application/json'}});
  };
  return {storage,rows,setOffline:value=>{offline=value;},pause:value=>{pause=value;}};
}
function create(){const client=new ReadingSync();client.init();clients.push(client);return client;}

test('stock account convention and canonical UTF-16 text agree',()=>{
  assert.equal(accountEmail(' Reader_1 '),'reader_1@users.quiet-notes.invalid');
  assert.throws(()=>accountEmail('中文账号'));
  assert.equal(canonicalText('　中 文\n😀\u200b'),'中文😀');
});
test('emoji quotes never contain lone UTF-16 surrogates',()=>{
  assert.equal(positionQuote('中'.repeat(31)+'😀',0),'中'.repeat(31));
  assert.equal(positionQuote('😀正文',1),'😀正文');
});
test('bookshelf-only upload does not clear a reading cursor',async()=>{
  environment();const client=create();await client.login('reader','password');
  client.queue(book,cursor(20));await client.sync();
  client.queue(book,null);await client.sync();
  assert.equal(client.rows[0].cursor.character_offset,20);
  assert.equal(Object.keys(client.pending).length,0);
});
test('offline pending survives reload and stays isolated per account',async()=>{
  const env=environment();const first=create();await first.login('reader','password');
  env.setOffline(true);first.queue(book,cursor(17));await first.sync();
  const reloaded=create();assert.equal(reloaded.pending['123'].cursor.character_offset,17);
  env.setOffline(false);await reloaded.login('another','password');
  assert.equal(Object.keys(reloaded.pending).length,0);assert.equal(reloaded.rows.length,0);
  await reloaded.login('reader','password');assert.equal(reloaded.rows[0].cursor.character_offset,17);
});
test('stale device never silently overwrites newer cloud position',async()=>{
  environment();const first=create();await first.login('reader','password');
  const stale=create();await stale.login('reader','password');
  first.queue(book,cursor(80));await first.sync();
  await stale.sync();stale.queue(book,cursor(10));await stale.sync();
  assert.equal(stale.conflicts['123'].cursor.character_offset,80);
  assert.equal(stale.pending['123'].cursor.character_offset,10);
  await stale.resolve('123',false);assert.equal(stale.rows[0].cursor.character_offset,80);
  assert.equal(Object.keys(stale.pending).length,0);
});
test('new progress queued during an upload is not lost',async()=>{
  const env=environment();const first=create();await first.login('reader','password');
  first.queue(book,cursor(1));
  let release;env.pause(new Promise(resolve=>{release=resolve;}));
  const uploading=first.sync();await new Promise(resolve=>setImmediate(resolve));
  first.queue(book,cursor(99));release();await uploading;
  assert.equal(first.pending['123'].cursor.character_offset,99);
  assert.equal(first.pending['123'].base,1);
  await first.sync();assert.equal(first.rows[0].cursor.character_offset,99);
});
test('pending sequence remains monotonic after restart',async()=>{
  const env=environment();const first=create();await first.login('reader','password');
  for(let index=0;index<4;index++)first.queue(book,cursor(index));
  const reloaded=create();let release;env.pause(new Promise(resolve=>{release=resolve;}));
  const uploading=reloaded.sync();await new Promise(resolve=>setImmediate(resolve));
  reloaded.queue(book,cursor(100));release();await uploading;
  assert.equal(reloaded.pending['123'].cursor.character_offset,100);
});
