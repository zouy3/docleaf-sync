import assert from 'node:assert/strict';
import test from 'node:test';

test('reader server renders the account entry and document shell', async () => {
  const {default: worker} = await import('../dist/server/index.js');
  const response = await worker.fetch(new Request('http://localhost/', {headers:{accept:'text/html'}}),
    {ASSETS:{fetch:async()=>new Response('Not found',{status:404})}},
    {waitUntil(){},passThroughOnException(){}});
  assert.equal(response.status,200);
  const html=await response.text();
  assert.match(html,/账号同步/);
  assert.match(html,/DocLeaf/);
  assert.doesNotMatch(html,/Your site is taking shape|codex-preview/);
});
