import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import { requireTool, root, web } from './toolchain.mjs';
const { keccak_256 } = requireTool('@noble/hashes/sha3.js');
const json = async path => JSON.parse(await readFile(path, 'utf8'));
const dep = await json(join(web, 'contracts/deployment.json'));
const { network } = await json(join(web, 'contracts/network.json'));
const pins = await json(join(web, 'contracts/runtime.json'));
const canonical = x => Array.isArray(x) ? x.map(canonical) : x && typeof x === 'object' ? Object.fromEntries(Object.keys(x).sort().map(k => [k, canonical(x[k])])) : x;
const hash = data => Buffer.from(keccak_256(data)).toString('hex');
const rpc = (method, params = []) => {
  const response = JSON.parse(execFileSync('curl', ['--fail', '-sS', '--max-time', '20', '-H', 'Content-Type: application/json', '-d', JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }), network.rpcUrls[0]], { encoding: 'utf8' }));
  if (response.error) throw new Error(JSON.stringify(response.error));
  return response.result;
};
assert.equal(BigInt(rpc('eth_chainId')), BigInt(dep.chainId));
const block = rpc('eth_getBlockByNumber', ['latest', false]);
const contracts = [];
for (const contract of dep.contracts) {
  const compiled = await json(join(root, `test/scratch/foundry-out/${contract.name}.sol/${contract.name}.json`));
  const abiHash = hash(new TextEncoder().encode(JSON.stringify(canonical(compiled.abi))));
  assert.equal(abiHash, contract.abiHash, 'Compiled ABI must match deployment pin');
  const delivered = await json(join(web, `contracts/${contract.name}.abi.json`));
  assert.deepEqual(compiled.abi, delivered);
  const code = rpc('eth_getCode', [contract.address, block.number]);
  const mask = value => {
    const chars = value.slice(2).split('');
    for (const refs of Object.values(compiled.deployedBytecode.immutableReferences)) for (const { start, length } of refs) chars.fill('0', start * 2, (start + length) * 2);
    return chars.join('');
  };
  assert.equal(mask(code), mask(compiled.deployedBytecode.object), 'Deployed bytecode must match compiled runtime except constructor immutables');
  const codeHash = '0x' + hash(Buffer.from(code.slice(2), 'hex'));
  assert.equal(codeHash, pins[contract.name].codeHash, 'Browser runtime pin must match deployed code');
  contracts.push({ name: contract.name, address: contract.address, abiHash, codeHash, deployedBytes: (code.length - 2) / 2, compiledRuntimeMatchedExceptImmutables: true, browserRuntimePinMatched: true });
}
const report = { chainId: dep.chainId, sourceCommit: dep.sourceCommit, blockNumber: Number(BigInt(block.number)), blockTimestamp: new Date(Number(BigInt(block.timestamp)) * 1000).toISOString(), contracts };
await mkdir(join(web, 'validation'), { recursive: true });
await writeFile(join(web, 'validation/contracts.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
