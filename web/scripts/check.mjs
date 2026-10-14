import assert from 'node:assert/strict';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { requireTool, web, root } from './toolchain.mjs';
import { preview } from './preview.mjs';

const { chromium, webkit } = requireTool('playwright');
const { default: AxeBuilder } = requireTool('@axe-core/playwright');
const { keccak_256 } = requireTool('@noble/hashes/sha3.js');
const fixture = JSON.parse(await readFile(join(web, 'test/contract-fixture.json'), 'utf8'));
const deployment = JSON.parse(await readFile(join(web, 'contracts/deployment.json'), 'utf8'));
const { network } = JSON.parse(await readFile(join(web, 'contracts/network.json'), 'utf8'));
const token = deployment.contracts[0].address, hook = deployment.contracts[1].address;
const unit = 10n ** 18n, chainId = '0x1237', account = '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266';
const source = await readFile(join(root, 'src/PerkVaultHook.sol'), 'utf8');
const intakeAddress = source.match(/INTAKE = IIntake\((0x[0-9a-fA-F]{40})\)/)[1].toLowerCase();
const hash = s => '0x' + Buffer.from(keccak_256(new TextEncoder().encode(s))).toString('hex');
const sig = s => hash(s).slice(0, 10);
const word = n => BigInt(n).toString(16).padStart(64, '0');
const encoded = (...values) => '0x' + values.map(word).join('');
const empty = '0x' + '0'.repeat(64);
const txHash = '0x' + 'bc'.repeat(32), requestId = hash('synthetic intake request in isolated test');
const oracleId = '34567890-abcd-4234-abcd-123456789abc';
const block = BigInt(deployment.contracts[1].blockNumber) + 100n, timestamp = 1800000000n;
const bodyHex = fixture.body.slice(2), bodyLength = Number(BigInt('0x' + bodyHex.slice(64, 128)));
const body = JSON.parse(Buffer.from(bodyHex.slice(128, 128 + bodyLength * 2), 'hex').toString());
const results = [];
const record = (name, result = 'passed', details) => { results.push({ name, result, ...(details ? { details } : {}) }); console.log(`${result}: ${name}${details ? ` (${details})` : ''}`); };
const { server, url } = await preview();
const screenshotDir = join(root, 'test/scratch/interactions'); await mkdir(screenshotDir, { recursive: true });
async function waitText(page, id, pattern) {
  try { await page.waitForFunction(({ id, pattern }) => new RegExp(pattern).test(document.getElementById(id).textContent), { id, pattern: pattern.source }, { timeout: 12000 }); }
  catch (error) { throw new Error(`${id} expected ${pattern}; actual: ${await page.locator('#' + id).textContent()}; report: ${await page.locator('#report-status').textContent()}`, { cause: error }); }
}
async function enabled(page, id, value = true) { await page.waitForFunction(({ id, value }) => document.getElementById(id).disabled === !value, { id, value }, { timeout: 12000 }); }

async function scenario(browser, options = {}) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, ...(options.mobile ? { userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148', isMobile: true, hasTouch: true } : {}) });
  const page = await context.newPage(); page.setDefaultTimeout(12000);
  const s = { float: 100n * unit, book: unit / 100n, balance: 100n * unit, allowance: 0n, pending: 2n * unit, burnDue: unit, burned: 3n * unit, totalTendered: 0n, lastAsk: 0n, totalAsked: 0n, oraclePrice: unit / 2n, chain: chainId, reject: false, rejectSwitch: false, unknownChain: false, readFailure: false, corruptCode: false, poolFailure: false, zeroBurn: false, oracleStatus: 'attested', mismatchOracle: false, intakeFailure: false, quoted: null, account, sent: [], calls: [], receipt: null, ...options };
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  page.on('requestfailed', r => console.log('Fixture request failed:', r.url(), r.failure()?.errorText));
  page.on('console', m => { if (m.type() === 'error') console.log('Fixture browser error:', m.text()); });
  function rpc(method, params = []) {
    if (s.readFailure) throw { code: -32000, message: 'Fixture RPC unavailable' };
    if (method === 'eth_chainId') return chainId;
    if (method === 'eth_getBlockByNumber') { const number = params[0] === 'latest' ? block : BigInt(params[0]); return { number: '0x' + number.toString(16), timestamp: '0x' + (timestamp - (block - number) * 2n).toString(16) }; }
    if (method === 'eth_getCode') return params[0].toLowerCase() === token ? s.corruptCode ? '0x00' : fixture.codes.PerkToken : params[0].toLowerCase() === hook ? fixture.codes.PerkVaultHook : '0x6000';
    if (method === 'eth_estimateGas') return '0x186a0';
    if (method === 'eth_gasPrice') return '0x3b9aca00';
    if (method === 'eth_getTransactionReceipt') { if (s.receiptFailure) throw { code: -32000, message: 'Fixture receipt read failed' }; return s.receiptPending ? null : s.receipt; }
    if (method === 'eth_getLogs') return [{ address: hook, topics: [hash('Asked(bytes32,address)'), requestId, encoded(BigInt(account))], data: '0x', blockNumber: '0x' + block.toString(16), logIndex: '0x1', transactionHash: txHash }];
    if (method !== 'eth_call') throw Error(`Unexpected RPC ${method}`);
    const call = params[0], selector = call.data.slice(0, 10), amount = call.data.length >= 74 ? BigInt('0x' + call.data.slice(-64)) : 0n;
    const values = {
      'floatBalance()': s.float, 'pendingFloat()': s.pending, 'totalFloat()': 120n * unit, 'totalBurned()': s.burned,
      'burnDue()': s.burnDue, 'totalTendered()': s.totalTendered, 'bookValuePerPerk()': s.book,
      'lastAsk()': s.lastAsk, 'totalAsked()': s.totalAsked, 'ASK_INTERVAL()': 604800n,
      'ASK_MINIMUM()': 600000000000000000n, 'ASK_PRICE()': 500000000000000000n,
      'ASK_REWARD()': 100000000000000000n, 'FEE_BPS()': 100n, 'POOL_FEE()': 12500n,
      'perk()': BigInt(token), 'imd()': BigInt(network.pairToken.address), 'poolManager()': BigInt(network.uniswapV4.poolManager),
      'INTAKE()': BigInt(intakeAddress), 'decimals()': 18n, 'priceOf(bytes32,address)': s.oraclePrice,
      'balanceOf(address)': s.balance, 'allowance(address,address)': s.allowance, 'getLiquidity(bytes32)': 1000n,
      'boundPool()': BigInt(hash('synthetic pool')),
      'quoteTender(uint256)': s.quoted ?? amount * s.book / unit,
      'approve(address,uint256)': 1n, 'tender(uint256)': s.quoted ?? amount * s.book / unit,
      'redeemPendingFees()': s.pending, 'burn()': s.zeroBurn ? 0n : s.burnDue, 'ask()': BigInt(requestId)
    };
    if (selector === sig('BODY()')) return fixture.body;
    if (selector === sig('ACTION()')) return '0x' + Buffer.from('oracle.request@oracle-1').toString('hex').padEnd(64, '0');
    if (selector === sig('getSlot0(bytes32)')) { if (s.poolFailure) throw { code: -32000, message: 'Fixture pool unavailable' }; return encoded(1n << 96n, 0n, 0n, 12500n); }
    for (const [signature, value] of Object.entries(values)) if (selector === sig(signature)) return encoded(value);
    throw Error(`Unexpected selector ${selector}`);
  }
  await context.route('**/*', async route => {
    const u = route.request().url();
    if (new URL(u).origin === new URL(url).origin) return await route.continue();
    const respond = options => route.fulfill({ headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS' }, ...options });
    if (route.request().method() === 'OPTIONS') return await respond({ status: 204, body: '' });
    if (network.rpcUrls.includes(u.replace(/\/$/, ''))) {
      const req = route.request().postDataJSON();
      try { return await respond({ json: { jsonrpc: '2.0', id: req.id, result: rpc(req.method, req.params) } }); }
      catch (e) { return await respond({ json: { jsonrpc: '2.0', id: req.id, error: { code: e.code ?? -32000, message: e.message, data: e.data } } }); }
    }
    if (u.startsWith('https://api.imd.fun/intake/')) {
      if (s.intakeFailure) return await respond({ status: 503, json: { error: 'unavailable' } });
      return await respond({ json: { chainId: 4663, transactionHash: txHash, entries: [{ requestId, payer: hook, intake: intakeAddress, state: 'completed', admission: { result: { kind: 'oracle', requestId: oracleId } } }] } });
    }
    if (u.startsWith('https://api.imd.fun/oracle/requests/')) return await respond({ json: { id: oracleId, chainId: s.mismatchOracle ? 1 : 4663, question: body.question, answerType: 'uint256', status: s.oracleStatus, attestedAt: '2027-01-15T08:00:00Z', attestation: { requestId: '0x' + oracleId.replaceAll('-', '').padEnd(64, '0'), chainId: 4663, answerType: 'uint256', answer: encoded(123456789000000000000n), fromBlock: 1, toBlock: 2 } } });
    // Isolation is strict. A mock signing test never reaches a public RPC or wallet backend.
    console.log('Blocked unexpected fixture URL:', u);
    return await route.abort();
  });
  await page.exposeFunction('__walletRequest', async ({ method, params = [] }) => {
    s.calls.push({ method, params });
    if (method === 'eth_requestAccounts') { if (s.hangConnection) return await new Promise(resolve => { s.resumeConnection = () => resolve([s.account]); }); if (s.reject) throw { code: 4001, message: 'User rejected request' }; return [s.account]; }
    if (method === 'eth_accounts') return [s.account];
    if (method === 'eth_chainId') return s.chain;
    if (method === 'wallet_switchEthereumChain') {
      if (s.rejectSwitch) throw { code: 4001, message: 'User rejected network switch' };
      if (s.unknownChain) throw { code: 4902, message: 'Unknown chain' };
      s.chain = params[0].chainId; return null;
    }
    if (method === 'wallet_addEthereumChain') { s.unknownChain = false; return null; }
    if (method !== 'eth_sendTransaction') return rpc(method, params);
    if (s.reject) throw { code: 4001, message: 'User rejected transaction' };
    const tx = params[0]; s.sent.push(tx);
    const amount = tx.data.length >= 74 ? BigInt('0x' + tx.data.slice(-64)) : 0n; const selector = tx.data.slice(0, 10);
    const log = (signature, values, topics = []) => ({ address: hook, topics: [hash(signature), ...topics], data: encoded(...values) });
    let logs = [];
    if (selector === sig('approve(address,uint256)')) s.allowance = amount;
    if (selector === sig('tender(uint256)')) { const payout = s.quoted ?? amount * s.book / unit; s.balance -= amount; s.allowance -= amount; s.float -= payout; s.totalTendered += amount; logs = [log('Tendered(address,uint256,uint256)', [amount, payout], [encoded(BigInt(account))])]; }
    if (selector === sig('redeemPendingFees()')) { logs = [log('PendingFeesRedeemed(address,uint256)', [s.pending], [encoded(BigInt(account))])]; s.pending = 0n; }
    if (selector === sig('burn()')) { logs = [log('Burned(uint256)', [s.burnDue])]; s.burned += s.burnDue; s.burnDue = 0n; }
    if (selector === sig('ask()')) { s.lastAsk = timestamp; s.totalAsked++; s.float -= 600000000000000000n; logs = [log('Asked(bytes32,address)', [], [requestId, encoded(BigInt(account))])]; }
    s.receipt = { status: s.revertReceipt ? '0x0' : '0x1', blockNumber: '0x' + block.toString(16), logs };
    return txHash;
  });
  await page.addInitScript(({ mobile, icon }) => {
    if (mobile) return;
    const listeners = new Map();
    const provider = { request: async args => {
      try { return await window.__walletRequest(args); }
      catch (e) { const message = e.message || ''; const code = /Unknown chain/.test(message) ? 4902 : /rejected/.test(message) ? 4001 : -32000; throw Object.assign(new Error(message), { code }); }
    }, on: (event, fn) => { const set = listeners.get(event) || new Set(); set.add(fn); listeners.set(event, set); }, removeListener: (event, fn) => listeners.get(event)?.delete(fn) };
    window.__emit = (event, value) => listeners.get(event)?.forEach(fn => fn(value));
    const announce = () => window.dispatchEvent(new CustomEvent('eip6963:announceProvider', { detail: { info: { uuid: 'test-wallet-id', rdns: 'test.perkshire.wallet', name: 'Test browser wallet', icon }, provider } }));
    window.addEventListener('eip6963:requestProvider', announce); announce();
  }, { mobile: options.mobile, icon: 'data:image/svg+xml,' + encodeURIComponent(await readFile(join(web, 'assets/browser-wallet.svg'), 'utf8')) });
  await page.goto(url);
  if (!options.readFailure && !options.corruptCode) await waitText(page, 'read-status', /Read at block/);
  return { page, s, errors, close: () => context.close() };
}
async function connect(page) { await page.locator('#connect').click(); await page.getByRole('button', { name: 'Test browser wallet · connect free' }).click(); await page.waitForFunction(() => !document.querySelector('#wallet-dialog').open); }
async function sign(page, id, expected) { await enabled(page, id); await page.locator('#' + id).click(); await page.waitForFunction(() => document.querySelector('#review-dialog').open); assert.match(await page.locator('#review-body').innerText(), expected); await page.locator('#confirm-transaction').click(); }

try {
  for (const [name, type] of [['Chromium', chromium], ['WebKit', webkit]]) {
    let browser;
    try { browser = await type.launch(); } catch (error) { record(`${name} browser launch`, 'unperformed', error.message.split('\n').find(l => l.includes('missing') || l.includes('not found')) || error.message.slice(0, 300)); process.exitCode = 1; continue; }
    try {
      let t = await scenario(browser); let { page, s } = t;
      assert.equal(await page.locator('table').count(), 1);
      assert.match(await page.locator('#price-to-book').innerText(), /100×/);
      assert.match(await page.locator('#market-price').innerText(), /1 IMD/);
      for (const width of [320, 390, 610, 768, 1440]) {
        await page.setViewportSize({ width, height: 844 });
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `overflow at ${width}`);
      }
      await page.setViewportSize({ width: 390, height: 844 });
      assert.ok((await page.locator('#tender-button').boundingBox()).y + 44 < 844);
      record(`${name}: one table, spot-price math, reflow at 320/390/610/768/1440, primary action on first screen`);
      await page.locator('#connect').click(); await page.keyboard.press('Escape');
      await page.waitForFunction(() => !document.querySelector('#wallet-dialog').open && document.activeElement.id === 'connect');
      assert.equal(await page.evaluate(() => document.activeElement.id), 'connect');
      await connect(page); await page.locator('#amount').fill('10.000000000000000001');
      await waitText(page, 'quote', /0.1 IMD/); await enabled(page, 'approve');
      await sign(page, 'approve', /exactly 10.000000000000000001 PERK/);
      await waitText(page, 'transaction-status', /Approval confirmed/);
      assert.equal(s.sent[0].to, token); assert.equal(s.sent[0].value, '0x0'); assert.equal(s.sent[0].chainId, chainId);
      assert.equal(s.sent[0].data, sig('approve(address,uint256)') + word(BigInt(hook)) + word(10n * unit + 1n));
      await sign(page, 'tender-button', /Permanently burn 10.000000000000000001 PERK/);
      await waitText(page, 'transaction-status', /Tender confirmed/);
      assert.equal(s.sent[1].to, hook); assert.equal(s.sent[1].data, sig('tender(uint256)') + word(10n * unit + 1n));
      assert.match(await page.locator('#transaction-status').innerText(), /0.1 IMD paid/);
      record(`${name}: EIP-6963, keyboard dismissal/focus return, exact approval, tender calldata, simulation, receipt and actual payout`);
      await sign(page, 'redeem', /pending claims/); await waitText(page, 'transaction-status', /redeemed into the hook/);
      await sign(page, 'burn', /Attempt to burn/); await waitText(page, 'transaction-status', /1 IMD burned/);
      await sign(page, 'ask', /Spend 0.6 IMD.*0.5 IMD.*0.1 IMD/); await waitText(page, 'transaction-status', /Weekly question commissioned/);
      await waitText(page, 'report-answer', /123.456789 IMD/);
      assert.equal(await page.locator('#ask').isDisabled(), true);
      assert.match(await page.locator('#report-link').getAttribute('href'), new RegExp(oracleId));
      record(`${name}: redeem, burn, ask costs/reward, cooldown and exact Asked → Intake → oracle report linkage`);
      const axe = await new AxeBuilder({ page }).analyze();
      assert.deepEqual(axe.violations.map(v => ({ id: v.id, impact: v.impact })), []);
      record(`${name}: axe accessibility scan of loaded page`, 'passed', `${axe.passes.length} rules passed; no violations`);
      assert.deepEqual(t.errors, []); await t.close();

      t = await scenario(browser, { chain: '0x1', unknownChain: true }); ({ page, s } = t);
      await connect(page); await waitText(page, 'connect', /Switch to Robinhood Chain/);
      await page.locator('#amount').fill('2'); await waitText(page, 'quote', /0.02 IMD/);
      assert.equal(await page.locator('#approve').isDisabled(), true);
      await page.locator('#connect').click(); await waitText(page, 'wallet-hint', /Robinhood Chain · ETH/);
      await enabled(page, 'approve');
      const add = s.calls.find(c => c.method === 'wallet_addEthereumChain');
      assert.equal(add.params[0].chainId, chainId); assert.deepEqual(add.params[0].rpcUrls, network.rpcUrls);
      s.account = token; await page.evaluate(address => window.__emit('accountsChanged', [address]), token);
      await waitText(page, 'connect', /0x2b2E/);
      record(`${name}: wrong-network action gate, 4902 add-chain fallback, pinned parameters and account-change refresh`);
      await t.close();

      t = await scenario(browser, { hangConnection: true }); ({ page, s } = t);
      await page.locator('#connect').click(); await page.getByRole('button', { name: 'Test browser wallet · connect free' }).click();
      await waitText(page, 'wallet-status', /Opening/); await page.locator('#close-wallet').click();
      await page.waitForFunction(() => !document.querySelector('#wallet-dialog').open);
      s.hangConnection = false; await connect(page); s.resumeConnection();
      await waitText(page, 'wallet-hint', /Robinhood Chain · ETH/); assert.equal(s.sent.length, 0);
      record(`${name}: dismissed unresolved wallet request can retry; late connection response ignored`); await t.close();

      t = await scenario(browser); ({ page, s } = t); await connect(page);
      for (const invalid of ['0', '-1', '1e5', '0.0000000000000000001', '999999999999999999999999999999999999999999999999999999999999999999999999999999999']) {
        await page.locator('#amount').fill(invalid); await waitText(page, 'amount-error', /Enter|decimal|large/); assert.equal(await page.locator('#approve').isDisabled(), true);
      }
      await page.locator('#amount').fill('101'); await waitText(page, 'amount-error', /exceeds your PERK balance/);
      await page.locator('#amount').fill('2'); await waitText(page, 'quote', /0.02 IMD/);
      s.reject = true; await sign(page, 'approve', /Approve exactly 2 PERK/); await waitText(page, 'transaction-status', /declined|rejected/);
      assert.equal(s.sent.length, 0); s.reject = false;
      await sign(page, 'approve', /Approve exactly 2 PERK/); await waitText(page, 'transaction-status', /Approval confirmed/);
      await page.locator('#tender-button').click(); await page.waitForFunction(() => document.querySelector('#review-dialog').open);
      s.quoted = 30000000000000000n; await page.locator('#confirm-transaction').click(); await waitText(page, 'review-warning', /payout changed/);
      assert.equal(s.sent.length, 1); await page.locator('#cancel-transaction').click();
      s.zeroBurn = true; await page.locator('#burn').click(); await waitText(page, 'transaction-status', /move no IMD/);
      assert.equal(s.sent.length, 1);
      record(`${name}: invalid/dust/oversized/over-balance input, signature rejection/retry, quote-change review and no-op burn prevention`);
      await t.close();

      t = await scenario(browser, { float: 0n, book: 0n }); ({ page } = t);
      assert.equal(await page.locator('#price-to-book').innerText(), 'Undefined'); await connect(page);
      await page.locator('#amount').fill('10'); await waitText(page, 'amount-error', /zero IMD/);
      assert.equal(await page.locator('#approve').isDisabled(), true); assert.equal(await page.locator('#ask').isDisabled(), true);
      record(`${name}: zero book value/float, zero-payout tender and insufficient-float ask`); await t.close();
      t = await scenario(browser, { oraclePrice: unit }); ({ page } = t); await connect(page); assert.equal(await page.locator('#ask').isDisabled(), true); assert.match(await page.locator('#ask-eligibility').innerText(), /price has changed/); await t.close();
      t = await scenario(browser, { lastAsk: timestamp - 604799n, totalAsked: 1n }); ({ page } = t); await connect(page); assert.equal(await page.locator('#ask').isDisabled(), true); await t.close();
      t = await scenario(browser, { lastAsk: timestamp - 604800n, totalAsked: 1n }); ({ page } = t); await connect(page); await enabled(page, 'ask'); await t.close();
      record(`${name}: oracle price change and exact seven-day eligibility boundary`);
      t = await scenario(browser, { corruptCode: true }); ({ page } = t); await waitText(page, 'read-status', /identity check failed/); await connect(page); assert.equal(await page.locator('#burn').isDisabled(), true); await t.close();
      t = await scenario(browser, { poolFailure: true }); ({ page } = t); assert.equal(await page.locator('#price-to-book').innerText(), 'Unavailable'); assert.match(await page.locator('[data-value="floatBalance"]').innerText(), /100 IMD/); await t.close();
      t = await scenario(browser, { readFailure: true }); ({ page } = t); await waitText(page, 'read-status', /unreachable/); assert.equal(await page.locator('#price-to-book').innerText(), 'Unavailable'); assert.equal(await page.locator('#connect').isEnabled(), true); assert.match(await page.locator('#ask').innerText(), /cost unavailable/); t.s.readFailure = false; await page.locator('#refresh').click(); await waitText(page, 'read-status', /Read at block/); await t.close();
      record(`${name}: bytecode mismatch fail-closed, partial pool failure and RPC outage/recovery`);
      t = await scenario(browser, { lastAsk: timestamp, totalAsked: 1n, mismatchOracle: true }); ({ page } = t); await waitText(page, 'report-status', /does not match/); assert.equal(await page.locator('#report-answer').isHidden(), true); await t.close();
      t = await scenario(browser, { lastAsk: timestamp, totalAsked: 1n, oracleStatus: 'running' }); ({ page } = t); await waitText(page, 'report-status', /running/); assert.equal(await page.locator('#report-answer').isHidden(), true); await t.close();
      record(`${name}: unrelated oracle answer rejected; report pending state`);
      t = await scenario(browser, { receiptFailure: true }); ({ page, s } = t); await connect(page);
      await page.locator('#amount').fill('1'); await waitText(page, 'quote', /0.01 IMD/);
      await sign(page, 'approve', /Approve exactly 1 PERK/); await waitText(page, 'transaction-status', /receipt could not be read/);
      assert.equal(await page.locator('#approve').isDisabled(), true);
      await page.locator('#stop-tracking').click(); await page.waitForFunction(() => document.querySelector('#tracking-dialog').open);
      assert.match(await page.locator('#tracking-dialog').innerText(), /does not cancel/);
      await page.locator('#keep-tracking').click(); s.receiptFailure = false;
      await page.locator('#check-receipt').click(); await waitText(page, 'transaction-status', /Approval confirmed/);
      assert.equal(s.sent.length, 1); await t.close();
      t = await scenario(browser, { receiptPending: true }); ({ page, s } = t); await connect(page);
      await page.locator('#amount').fill('1'); await waitText(page, 'quote', /0.01 IMD/);
      await sign(page, 'approve', /Approve exactly 1 PERK/); await waitText(page, 'transaction-status', /submitted/);
      s.receiptPending = false; await page.reload(); await waitText(page, 'transaction-status', /Approval confirmed/);
      assert.equal(s.sent.length, 1); await t.close();
      t = await scenario(browser, { revertReceipt: true }); ({ page, s } = t); await connect(page);
      await page.locator('#amount').fill('1'); await waitText(page, 'quote', /0.01 IMD/);
      await sign(page, 'approve', /Approve exactly 1 PERK/); await waitText(page, 'transaction-status', /reverted onchain/);
      assert.doesNotMatch(await page.locator('#transaction-status').innerText(), /Approval confirmed/); await t.close();
      record(`${name}: receipt failure/retry, tracking warning, pending reload without rebroadcast and onchain revert`);
      t = await scenario(browser, { mobile: true }); ({ page } = t); await page.locator('#connect').click();
      for (const wallet of ['MetaMask', 'Coinbase Wallet', 'Phantom']) assert.ok(await page.getByRole('link', { name: `Open in ${wallet} · free`, exact: true }).getAttribute('href'));
      assert.equal(await page.getByRole('button', { name: 'Coinbase Smart Wallet · connect free' }).count(), 1);
      await page.screenshot({ path: join(screenshotDir, `${name.toLowerCase()}-wallet.png`) });
      await page.keyboard.press('Escape');
      await page.evaluate(() => document.documentElement.style.fontSize = '200%');
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      record(`${name}: mobile wallet deep links, Smart Wallet entry and 200% text enlargement`); await t.close();
    } finally { await browser.close(); }
  }
} catch (error) { record('Interaction suite', 'failed', error.stack); process.exitCode = 1; }
finally {
  server.close();
  const report = JSON.stringify({ isolation: 'Synthetic JSON-RPC and EIP-1193 wallet; all external calls intercepted. No live signing or funds used.', results }, null, 2) + '\n';
  await mkdir(join(root, 'artifacts'), { recursive: true }); await mkdir(join(web, 'validation'), { recursive: true });
  await writeFile(join(root, 'artifacts/interactions.json'), report); await writeFile(join(web, 'validation/interactions.json'), report);
}
