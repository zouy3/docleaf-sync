import {parseArgs} from 'node:util';
import {fileURLToPath} from 'node:url';
import {installStaticCacheCompatibility} from './vinext-static-cache-compat.mjs';

const {values} = parseArgs({options:{port:{type:'string',short:'p'}}});
const port = Number(values.port ?? process.env.PORT ?? 3000);
if (!Number.isInteger(port) || port < 0 || port > 65535) throw Error('Invalid reader port');
await installStaticCacheCompatibility();
const {startProdServer} = await import('vinext/server/prod-server');
await startProdServer({port,host:'127.0.0.1',outDir:fileURLToPath(new URL('../dist/',import.meta.url))});
console.log('[DocLeaf] Windows-compatible static resource paths enabled.');
