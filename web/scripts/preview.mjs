import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { join, resolve, extname } from 'node:path';
import { root } from './toolchain.mjs';
export function preview(port = 0) {
  const dist = join(root, 'dist');
  const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png' };
  const server = createServer(async (req, res) => {
    try {
      const path = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
      if (path === '/') { res.writeHead(302, { Location: '/preview/' }); res.end(); return; }
      if (!path.startsWith('/preview/')) throw new Error('not found');
      const file = resolve(dist, path.slice('/preview/'.length) || 'index.html');
      if (!file.startsWith(dist + '/')) throw new Error('not found');
      const content = await readFile(file);
      res.writeHead(200, { 'Content-Type': types[extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' }); res.end(content);
    } catch { res.writeHead(404); res.end('Not found'); }
  });
  return new Promise(resolve => server.listen(port, '127.0.0.1', () => resolve({ server, url: `http://127.0.0.1:${server.address().port}/preview/` })));
}
if (process.argv[1] === new URL(import.meta.url).pathname) {
  const { url } = await preview(Number(process.env.PORT || 4173));
  console.log(`Previewing production export at ${url}`);
}
