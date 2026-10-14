import networkFile from '../contracts/network.json';
import deployment from '../contracts/deployment.json';
import runtime from '../contracts/runtime.json';
import { keccak_256 } from '@noble/hashes/sha3.js';

export type Hex = `0x${string}`;
export type Provider = {
  request(args: { method: string; params?: readonly unknown[] | object }): Promise<unknown>;
  on?(event: string, listener: (...args: unknown[]) => void): unknown;
  removeListener?(event: string, listener: (...args: unknown[]) => void): unknown;
  disconnect?(): Promise<void>;
};
export const network = networkFile.network;
export const addChain = networkFile.walletAddChain;
export const PERK = deployment.contracts.find(c => c.name === 'PerkToken')!.address as Hex;
export const HOOK = deployment.contracts.find(c => c.name === 'PerkVaultHook')!.address as Hex;
export const IMD = network.pairToken.address as Hex;
export const ORACLE = 'https://api.imd.fun/oracle/requests';
export const hex = (n: bigint | number): Hex => `0x${n.toString(16)}`;
export const hash = (value: Uint8Array): Hex => `0x${Array.from(keccak_256(value), b => b.toString(16).padStart(2, '0')).join('')}`;
export function bytes(value: string): Uint8Array {
  if (!/^0x(?:[0-9a-f]{2})*$/i.test(value)) throw new Error('Malformed chain response. Refresh and try again.');
  return Uint8Array.from(value.slice(2).match(/../g) ?? [], pair => parseInt(pair, 16));
}
export const selector = (signature: string) => hash(new TextEncoder().encode(signature)).slice(0, 10);
export const topic = (signature: string) => hash(new TextEncoder().encode(signature));
export function data(signature: string, args: (bigint | string)[] = []): Hex {
  return (selector(signature) + args.map(arg => {
    const value = typeof arg === 'bigint' ? arg.toString(16) : arg.replace(/^0x/, '');
    if (!/^[0-9a-f]{1,64}$/i.test(value)) throw new Error('Invalid contract argument.');
    return value.padStart(64, '0');
  }).join('')) as Hex;
}
export function uint(value: unknown, index = 0): bigint {
  if (typeof value !== 'string' || !/^0x[0-9a-f]+$/i.test(value) || value.length < 66 + index * 64) throw new Error('Incomplete contract response. Refresh and try again.');
  return BigInt('0x' + value.slice(2 + index * 64, 66 + index * 64));
}
export const address = (value: unknown) => (`0x${uint(value).toString(16).padStart(40, '0')}`) as Hex;
export function stringValue(value: unknown): string {
  const encoded = String(value);
  const offset = Number(uint(encoded));
  const length = Number(uint(encoded, offset / 32));
  if (length > 16384 || encoded.length < 2 + (offset + 32 + length) * 2) throw new Error('Invalid text from contract.');
  return new TextDecoder().decode(bytes('0x' + encoded.slice(2 + (offset + 32) * 2, 2 + (offset + 32 + length) * 2)));
}
export function checksum(addr: string): string {
  const lower = addr.toLowerCase().slice(2);
  const digest = hash(new TextEncoder().encode(lower)).slice(2);
  return '0x' + Array.from(lower, (c, i) => parseInt(digest[i]!, 16) >= 8 ? c.toUpperCase() : c).join('');
}
export function formatUnits(value: bigint, decimals: number, grouping = true): string {
  const scale = 10n ** BigInt(decimals);
  const whole = (value / scale).toString();
  const fraction = (value % scale).toString().padStart(decimals, '0').replace(/0+$/, '');
  return (grouping ? whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',') : whole) + (fraction ? '.' + fraction : '');
}
export function parseAmount(value: string, decimals: number): bigint {
  if (!/^(?:0|[1-9]\d*)(?:\.\d+)?$/.test(value)) throw new Error('Enter a positive PERK amount using digits and a decimal point.');
  const [whole, fraction = ''] = value.split('.');
  if (fraction.length > decimals) throw new Error(`Use no more than ${decimals} decimal places.`);
  const amount = BigInt(whole!) * 10n ** BigInt(decimals) + BigInt(fraction.padEnd(decimals, '0') || '0');
  if (amount <= 0n) throw new Error('Enter an amount greater than zero.');
  if (amount > (1n << 256n) - 1n) throw new Error('This amount is too large for the token contract.');
  return amount;
}
export function marketFraction(sqrt: bigint, perkDecimals: number): [bigint, bigint] {
  // Uniswap orders currencies by address. Return raw IMD per one whole PERK.
  const scale = 10n ** BigInt(perkDecimals), squared = sqrt * sqrt, q192 = 1n << 192n;
  return BigInt(PERK) < BigInt(IMD) ? [squared * scale, q192] : [q192 * scale, squared];
}
export function ratio(numerator: bigint, denominator: bigint, decimals = 4): string {
  if (denominator === 0n) return 'Undefined';
  const n = numerator * 10n ** BigInt(decimals) / denominator;
  return n === 0n && numerator > 0n ? `<${formatUnits(1n, decimals)}` : formatUnits(n, decimals);
}
export class RpcError extends Error {
  constructor(message: string, public code?: number, public data?: unknown) { super(message); }
}
export async function jsonFetch(url: string, init?: RequestInit): Promise<unknown> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 12000);
  try {
    const response = await fetch(url, { ...init, signal: controller.signal });
    if (!response.ok) throw new Error(`Service returned HTTP ${response.status}.`);
    return await response.json();
  } finally { clearTimeout(timer); }
}
type Response = { result?: unknown; error?: { message: string; code: number; data?: unknown } };
export type Reader = (method: string, params?: readonly unknown[]) => Promise<unknown>;
let rpcId = 0;
export async function chooseReader(wallet?: Provider): Promise<Reader> {
  const readers: Reader[] = network.rpcUrls.map(url => async (method, params = []) => {
    const response = await jsonFetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method, params }) }) as Response;
    if (response.error) throw new RpcError(response.error.message, response.error.code, response.error.data);
    if (response.result === undefined) throw new Error('The RPC returned no result.');
    return response.result;
  });
  if (wallet) readers.push((method, params) => wallet.request({ method, params }));
  for (const read of readers) {
    try { if (BigInt(String(await read('eth_chainId'))) === BigInt(network.chainId)) return read; } catch { /* Try the next pinned RPC. */ }
  }
  throw new Error('Robinhood Chain is unreachable. Check your connection, then refresh figures.');
}
export const call = (read: Reader, to: string, signature: string, args: (string | bigint)[] = [], block = 'latest') => read('eth_call', [{ to, data: data(signature, args) }, block]);
const metricNames = ['floatBalance', 'pendingFloat', 'totalFloat', 'totalBurned', 'burnDue', 'totalTendered', 'bookValuePerPerk', 'lastAsk', 'totalAsked', 'ASK_INTERVAL', 'ASK_MINIMUM', 'ASK_PRICE', 'ASK_REWARD', 'FEE_BPS', 'POOL_FEE'] as const;
export type Snapshot = Record<typeof metricNames[number], bigint> & {
  read: Reader; block: string; timestamp: bigint; loadedAt: number;
  perkDecimals: number; imdDecimals: number; pool: string; body: string; intake: string;
  sqrt: bigint | null; liquidity: bigint | null; marketError: boolean;
  oraclePrice: bigint | null; balance: bigint | null; allowance: bigint | null;
  account?: string;
};
export async function snapshot(wallet?: Provider, account?: string): Promise<Snapshot> {
  const read = await chooseReader(wallet);
  const block = await read('eth_getBlockByNumber', ['latest', false]) as { number: string; timestamp: string } | null;
  if (!block?.number || !block.timestamp) throw new Error('Latest block unavailable. Refresh figures.');
  const at = block.number;
  const [perkCode, hookCode, imdCode] = await Promise.all([PERK, HOOK, IMD].map(a => read('eth_getCode', [a, at])));
  for (const [name, code] of [['PerkToken', perkCode], ['PerkVaultHook', hookCode]] as const) {
    if (hash(bytes(String(code))) !== runtime[name].codeHash) throw new Error('Contract identity check failed. Transactions are disabled.');
  }
  if (imdCode === '0x') throw new Error('IMD contract is unavailable on this chain.');
  const basics = await Promise.all([
    ...metricNames.map(name => call(read, HOOK, name + '()', [], at)),
    ...['perk', 'imd', 'poolManager', 'boundPool', 'BODY', 'INTAKE', 'ACTION'].map(name => call(read, HOOK, name + '()', [], at)),
    call(read, PERK, 'decimals()', [], at), call(read, IMD, 'decimals()', [], at)
  ]);
  const metrics = Object.fromEntries(metricNames.map((name, i) => [name, uint(basics[i])])) as Record<typeof metricNames[number], bigint>;
  const i = metricNames.length;
  if (address(basics[i]).toLowerCase() !== PERK || address(basics[i + 1]).toLowerCase() !== IMD || address(basics[i + 2]).toLowerCase() !== network.uniswapV4.poolManager) throw new Error('The hook’s currencies or PoolManager do not match this deployment.');
  const perkDecimals = Number(uint(basics[i + 7])), imdDecimals = Number(uint(basics[i + 8]));
  if (perkDecimals !== deployment.manifest.token.decimals || imdDecimals !== network.pairToken.decimals) throw new Error('Unexpected token decimals. Transactions are disabled.');
  const pool = String(basics[i + 3]), body = stringValue(basics[i + 4]), intake = address(basics[i + 5]);
  const optional = await Promise.allSettled([
    call(read, network.uniswapV4.stateView, 'getSlot0(bytes32)', [pool], at),
    call(read, network.uniswapV4.stateView, 'getLiquidity(bytes32)', [pool], at),
    call(read, address(basics[i + 5]), 'priceOf(bytes32,address)', [String(basics[i + 6]), IMD], at),
    account ? call(read, PERK, 'balanceOf(address)', [account], at) : Promise.resolve(null),
    account ? call(read, PERK, 'allowance(address,address)', [account, HOOK], at) : Promise.resolve(null)
  ]);
  const optionalUint = (i: number) => { const result = optional[i]!; try { return result.status === 'fulfilled' && result.value !== null ? uint(result.value) : null; } catch { return null; } };
  const sqrt = optionalUint(0), liquidity = optionalUint(1);
  return { ...metrics, read, block: at, timestamp: BigInt(block.timestamp), loadedAt: Date.now(), perkDecimals, imdDecimals, pool, body, intake, sqrt, liquidity, marketError: sqrt === null || sqrt === 0n, oraclePrice: optionalUint(2), balance: optionalUint(3), allowance: optionalUint(4), account };
}
export const fresh = (s: Snapshot | null) => s !== null && Date.now() - s.loadedAt < 90000;
export function askReason(s: Snapshot): string | null {
  if (s.lastAsk !== 0n && s.timestamp < s.lastAsk + s.ASK_INTERVAL) return `Available after ${new Date(Number(s.lastAsk + s.ASK_INTERVAL) * 1000).toUTCString()}.`;
  if (s.floatBalance < s.ASK_MINIMUM) return `The float needs at least ${formatUnits(s.ASK_MINIMUM, s.imdDecimals)} IMD to ask.`;
  if (s.oraclePrice === null) return 'The current oracle price could not be verified. Refresh figures to retry.';
  if (s.oraclePrice !== s.ASK_PRICE) return 'The oracle price has changed. This immutable hook cannot buy a report at the new price.';
  return null;
}

type OracleRecord = {
  id: string; chainId: number; question: string; answerType: string; status: string;
  consumer?: unknown; createdAt: string; attestedAt?: string;
  attestation?: { requestId?: string; chainId?: number; answerType?: string; answer?: string; fromBlock?: number; toBlock?: number };
  computed?: { answer?: string | number };
  window?: { fromBlock?: number; toBlock?: number };
};
export type Report = { message: string; amount?: bigint; url?: string; window?: string };
export async function loadReport(s: Snapshot): Promise<Report> {
  if (s.lastAsk === 0n) return { message: 'No report has been commissioned yet. The first question can be asked when the float covers its cost.' };
  const question = (JSON.parse(s.body) as { question: string }).question;
  // Bound the search by time, then verify the precise Asked request ID onchain.
  let low = BigInt(deployment.contracts[1]!.blockNumber), high = BigInt(s.block);
  while (low < high) {
    const mid = (low + high) / 2n;
    const b = await s.read('eth_getBlockByNumber', [hex(mid), false]) as { timestamp: string } | null;
    if (!b) throw new Error('The report’s block could not be read.');
    if (BigInt(b.timestamp) < s.lastAsk) low = mid + 1n; else high = mid;
  }
  const from = low;
  high = BigInt(s.block);
  // Several L2 blocks can share a timestamp. Include every block in that second.
  while (low < high) {
    const mid = (low + high + 1n) / 2n;
    const b = await s.read('eth_getBlockByNumber', [hex(mid), false]) as { timestamp: string } | null;
    if (!b) throw new Error('The report’s block range could not be read.');
    if (BigInt(b.timestamp) > s.lastAsk) high = mid - 1n; else low = mid;
  }
  const logs = await s.read('eth_getLogs', [{ address: HOOK, fromBlock: hex(from), toBlock: hex(low), topics: [topic('Asked(bytes32,address)')] }]) as { topics: string[]; blockNumber: string; logIndex: string; transactionHash: string }[];
  const last = logs.sort((a, b) => Number(BigInt(b.blockNumber) - BigInt(a.blockNumber)) || Number(BigInt(b.logIndex) - BigInt(a.logIndex)))[0];
  const requestId = last?.topics[1]?.toLowerCase();
  if (!requestId || !last?.transactionHash || !/^0x[0-9a-f]{64}$/i.test(last.transactionHash)) throw new Error('The latest Asked event could not be located.');
  // Intake IDs and oracle UUIDs intentionally differ. Resolve the exact event through
  // the public intake read; never guess a UUID or match only by question or date.
  type Entry = { requestId: string; payer: string; intake: string; state: string; reason?: string; admission?: { result?: { kind: string; requestId: string } } };
  const intake = await jsonFetch(`https://api.imd.fun/intake/${network.chainId}/${last.transactionHash}`) as { chainId: number; transactionHash: string; entries?: Entry[] };
  if (intake.chainId !== network.chainId || intake.transactionHash?.toLowerCase() !== last.transactionHash.toLowerCase() || !Array.isArray(intake.entries)) throw new Error('The oracle’s intake record does not match the onchain transaction.');
  const entry = intake.entries.find(e => e.requestId?.toLowerCase() === requestId && e.payer?.toLowerCase() === HOOK && e.intake?.toLowerCase() === s.intake.toLowerCase());
  if (!entry) return { message: 'The question is onchain, but its intake record is not indexed yet. Refresh the report later.' };
  if (entry.state === 'refused' || entry.state === 'failed') return { message: `The latest question ${entry.state}. The oracle payment was spent without an answer. ${entry.reason ? `Reason: ${entry.reason}.` : ''}` };
  const result = entry.admission?.result;
  if (result?.kind !== 'oracle' || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(result.requestId)) return { message: 'The question is paid and awaiting oracle admission. Refresh the report later.' };
  const url = `${ORACLE}/${result.requestId}`;
  const r = await jsonFetch(url) as OracleRecord;
  if (r.id !== result.requestId || r.chainId !== network.chainId || r.question !== question || r.answerType !== 'uint256') throw new Error('The oracle response does not match the hook’s question.');
  if (r.status !== 'attested') return { message: `The latest request is ${r.status}. The oracle has not published an attested answer.`, url };
  const a = r.attestation;
  const oracleId = '0x' + result.requestId.replace(/-/g, '').padEnd(64, '0');
  if (a?.requestId?.toLowerCase() !== oracleId || a?.chainId !== network.chainId || a.answerType !== 'uint256' || !a.answer || !/^(0x[0-9a-f]{64}|\d+)$/i.test(a.answer)) throw new Error('The oracle answer could not be decoded or matched to the request.');
  const amount = BigInt(a.answer);
  if (amount < 0n || amount >= 1n << 256n) throw new Error('Oracle answer is outside uint256.');
  return { message: 'IMD sent to the dead address across Robinhood Chain in the report’s window (oracle-reported).', amount, url, window: `Blocks ${a.fromBlock ?? r.window?.fromBlock ?? 'unavailable'} to ${a.toBlock ?? r.window?.toBlock ?? 'unavailable'}. Report published ${r.attestedAt ? new Date(r.attestedAt).toUTCString() : 'at an unreported time'}.` };
}
