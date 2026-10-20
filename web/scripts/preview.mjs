import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { root } from './toolchain.mjs';

export function preview(port = 0) {
  const server = createServer(async (req, res) => {
    const path = new URL(req.url, 'http://localhost').pathname;
    const known = ['/', '/index.html', '/preview/', '/preview/index.html', '/404.html', '/preview/404.html'];
    const rules = path === '/_redirects' || path === '/preview/_redirects';
    const content = await readFile(join(root, 'dist', rules ? '_redirects' : known.includes(path) ? 'index.html' : '404.html'));
    res.writeHead(known.includes(path) || rules ? 200 : 404, {
      'Content-Type': rules ? 'text/plain; charset=utf-8' : 'text/html; charset=utf-8',
      'Cache-Control': 'no-store'
    });
    res.end(content);
  });
  return new Promise(resolve => server.listen(port, '127.0.0.1', () => resolve({
    server, url: `http://127.0.0.1:${server.address().port}/preview/`
  })));
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const flag = process.argv.indexOf('--port');
  const { url } = await preview(flag === -1 ? 4173 : Number(process.argv[flag + 1]));
  console.log(`Previewing production export at ${url}`);
}
