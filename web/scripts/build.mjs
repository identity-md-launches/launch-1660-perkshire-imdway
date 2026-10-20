import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { root, web } from './toolchain.mjs';
import { assertRedirect, destination } from './redirect.mjs';

const html = await readFile(join(web, 'index.html'), 'utf8');
assertRedirect(html);
const dist = join(root, 'dist');
await rm(dist, { recursive: true, force: true });
await mkdir(dist, { recursive: true });
await writeFile(join(dist, 'index.html'), html);
// Same document for static hosts/gateways that support a custom not-found page.
await writeFile(join(dist, '404.html'), html);
// Hosts/gateways supporting _redirects send old paths directly to the new site.
await writeFile(join(dist, '_redirects'), `/* ${destination} 301\n`);
console.log('Production export: dist/index.html, identical 404.html, and catch-all _redirects. No app bundles or styles.');
