// vinext 0.0.50 indexes Windows paths with backslashes, but lookup receives
// URL paths. Normalize only cache keys; never change disk paths or request ACLs.
export function normalizeStaticCache(cache) {
  if (!(cache.entries instanceof Map)) throw Error('Unsupported vinext static cache; review compatibility adapter');
  const entries = new Map();
  for (const [key, entry] of cache.entries) {
    const url = key.replaceAll('\\', '/');
    // Windows also bypassed the upstream POSIX-only .vite filter.
    if (/^\/\.vite(?:\/|$)/i.test(url)) continue;
    if (entries.has(url) && entries.get(url) !== entry) throw Error('Duplicate static URL: '+url);
    entries.set(url, entry);
  }
  cache.entries = entries;
  return cache;
}

export async function installStaticCacheCompatibility() {
  const module = new URL('./static-file-cache.js', import.meta.resolve('vinext/server/prod-server'));
  const {StaticFileCache} = await import(module.href);
  const installed = Symbol.for('docleaf.static-cache-compat');
  if (StaticFileCache[installed]) return;
  const create = StaticFileCache.create.bind(StaticFileCache);
  StaticFileCache.create = async (...args) => normalizeStaticCache(await create(...args));
  StaticFileCache[installed] = true;
}
