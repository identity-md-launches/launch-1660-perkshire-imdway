import { readFile, writeFile, mkdir, rm, cp } from 'node:fs/promises';
import { join, resolve, dirname } from 'node:path';
import { createHash } from 'node:crypto';
import { requireTool, web, root } from './toolchain.mjs';
const { build } = requireTool('esbuild');
const sharp = requireTool('sharp');
const { keccak_256 } = requireTool('@noble/hashes/sha3.js');
const readJson = async path => JSON.parse(await readFile(path, 'utf8'));
const canonical = x => Array.isArray(x) ? x.map(canonical) : x && typeof x === 'object' ? Object.fromEntries(Object.keys(x).sort().map(k => [k, canonical(x[k])])) : x;
const keccak = value => Buffer.from(keccak_256(value)).toString('hex');
const dep = await readJson(join(web, 'contracts/deployment.json'));
const { network } = await readJson(join(web, 'contracts/network.json'));
for (const contract of dep.contracts) {
  const abi = await readJson(join(web, `contracts/${contract.name}.abi.json`));
  if (keccak(new TextEncoder().encode(JSON.stringify(canonical(abi)))) !== contract.abiHash) throw new Error(`${contract.name} ABI does not match the pinned deployment.`);
}
const addresses = Object.fromEntries(dep.contracts.map(c => [c.name, c.address]));
const checksum = address => {
  const lower = address.slice(2).toLowerCase(), h = keccak(new TextEncoder().encode(lower));
  return '0x' + [...lower].map((c, i) => parseInt(h[i], 16) >= 8 ? c.toUpperCase() : c).join('');
};
const PERK = addresses.PerkToken, HOOK = addresses.PerkVaultHook, IMD = network.pairToken.address;
const values = {
  PERK: checksum(PERK), HOOK: checksum(HOOK), IMD: checksum(IMD),
  PERK_EXPLORER: `${network.explorer}/token/${PERK}`,
  HOOK_EXPLORER: `${network.explorer}/address/${HOOK}#code`,
  IMD_EXPLORER: `${network.explorer}/token/${IMD}`,
  TRADE_URL: `https://app.uniswap.org/swap?chain=robinhood&inputCurrency=${IMD}&outputCurrency=${PERK}`,
  LAUNCH_URL: `https://explorer.imd.fun/token/${PERK}`,
  SOURCE_URL: `${dep.repoUrl}/tree/${dep.sourceCommit}`
};
const dist = resolve(root, 'dist');
await rm(dist, { recursive: true, force: true });
await mkdir(join(dist, 'assets'), { recursive: true });
const html = (await readFile(join(web, 'index.html'), 'utf8')).replace(/\{\{(\w+)\}\}/g, (_, key) => {
  if (!(key in values)) throw new Error(`Unknown HTML binding ${key}`);
  return values[key].replace(/&/g, '&amp;').replace(/"/g, '&quot;');
});
await writeFile(join(dist, 'index.html'), html);
await cp(join(web, 'style.css'), join(dist, 'style.css'));
await cp(join(web, 'assets'), join(dist, 'assets'), { recursive: true });
await cp(join(root, 'logo.svg'), join(dist, 'logo.svg'));
await sharp(join(root, 'logo.svg')).resize(512, 512).png({ compressionLevel: 9, palette: true }).toFile(join(root, 'logo-512.png'));
await cp(join(root, 'logo-512.png'), join(dist, 'logo-512.png'));
const result = await build({
  entryPoints: [join(web, 'src/app.ts')], outdir: join(dist, 'assets'),
  entryNames: 'app', chunkNames: '[name]-[hash]', assetNames: '[name]-[hash]',
  bundle: true, splitting: true, format: 'esm', platform: 'browser', target: ['es2022'],
  minify: true, sourcemap: false, legalComments: 'linked', metafile: true,
  nodePaths: [join(process.env.PERK_TOOLCHAIN || web, 'node_modules')],
  logLevel: 'info'
});
const outputs = Object.entries(result.metafile.outputs).map(([path, info]) => ({ path: path.replace(root + '/', ''), bytes: info.bytes }));
// Retain full licenses for the dependency code actually present in the browser bundles.
const notices = new Map();
for (const input of Object.keys(result.metafile.inputs)) {
  if (!input.includes('node_modules/')) continue;
  let directory = dirname(resolve(root, input));
  while (directory.includes('node_modules')) {
    try {
      const pkg = await readJson(join(directory, 'package.json'));
      if (pkg.name) {
        const id = `${pkg.name}@${pkg.version}`;
        if (!notices.has(id)) for (const name of ['LICENSE', 'LICENSE.md', 'LICENSE.txt', 'license', 'license.md']) {
          try { notices.set(id, await readFile(join(directory, name), 'utf8')); break; } catch { /* Try the package's next license filename. */ }
        }
        break;
      }
    } catch { /* Continue to the package root. */ }
    directory = dirname(directory);
  }
}
await writeFile(join(dist, 'assets/licenses/bundled-dependencies.txt'), [...notices].sort(([a], [b]) => a.localeCompare(b)).map(([name, license]) => `${name}\n${'='.repeat(name.length)}\n${license.trim()}\n`).join('\n'));
const sourceHashes = {};
for (const name of ['PerkToken', 'PerkVaultHook', 'IIntake']) sourceHashes[`src/${name}.sol`] = createHash('sha256').update(await readFile(join(root, `src/${name}.sol`))).digest('hex');
await mkdir(join(root, 'artifacts'), { recursive: true });
await mkdir(join(web, 'validation'), { recursive: true });
const report = JSON.stringify({ sourceCommit: dep.sourceCommit, abiHashesVerified: dep.contracts.map(c => ({ name: c.name, abiHash: c.abiHash })), sourceHashes, outputs }, null, 2) + '\n';
await writeFile(join(root, 'artifacts/build.json'), report);
await writeFile(join(web, 'validation/build.json'), report);
console.log('Production export: dist/. Both ABI hashes verified. Relative assets, local logo, no source maps.');
