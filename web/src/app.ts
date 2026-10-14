import { HOOK, PERK, network, data, uint, formatUnits, parseAmount, marketFraction, ratio, snapshot, fresh, askReason, call, loadReport, topic, hex, checksum, type Snapshot, type Hex } from './chain';
import { current, el, initWallet, errorText } from './wallet';

type Action = 'approve' | 'tender' | 'redeem' | 'burn' | 'ask';
type Transaction = { from: string; to: string; data: Hex; value: '0x0'; gas?: Hex };
type Prepared = { kind: Action; amount: bigint; quote: bigint; tx: Transaction; s: Snapshot; gas: bigint; gasPrice: bigint; account: string };
type Pending = { hash: string; kind: Action; account: string };
type Log = { address: string; topics: string[]; data: string };
type Receipt = { status: string; blockNumber: string; logs: Log[] };
let state: Snapshot | null = null, failed = false, refreshing = false, refreshAgain = false;
let quotedAmount: bigint | null = null, quotedPayout: bigint | null = null, quoteId = 0;
let busy = false, prepared: Prepared | null = null, pending: Pending | null = null;
let reportId = 0, reportKey = '', polling = false;
const input = el<HTMLInputElement>('amount');
const button = (id: string) => el<HTMLButtonElement>(id);
const imd = (value: bigint, s = state!) => `${formatUnits(value, s.imdDecimals)} IMD`;
const perk = (value: bigint, s = state!) => `${formatUnits(value, s.perkDecimals)} PERK`;
const status = (message: string, error = false) => { el('transaction-status').textContent = message; el('transaction-status').classList.toggle('error', error); };
const canTransact = () => !failed && fresh(state) && !!current().account && current().correctChain && state?.account?.toLowerCase() === current().account?.toLowerCase() && !busy && !pending;
const review = () => el<HTMLDialogElement>('review-dialog');
function setTerm(name: string, value: string) { document.querySelectorAll(`[data-term="${name}"]`).forEach(node => { node.textContent = value; }); }
function date(value: bigint) { return new Date(Number(value) * 1000).toUTCString(); }

function controls() {
  const ready = canTransact();
  const valid = ready && quotedAmount !== null && quotedPayout !== null && quotedPayout > 0n && state!.balance !== null && quotedAmount <= state!.balance && state!.allowance !== null;
  button('approve').disabled = !valid || state!.allowance! >= quotedAmount!;
  button('tender-button').disabled = !valid || state!.allowance! < quotedAmount!;
  button('redeem').disabled = !ready || state!.pendingFloat === 0n;
  button('burn').disabled = !ready || state!.burnDue === 0n;
  button('ask').disabled = !ready || askReason(state!) !== null;
  button('refresh').disabled = refreshing;
  input.disabled = busy || !!pending;
  if (pending) el('action-gate').textContent = 'A submitted transaction is awaiting confirmation.';
  else if (busy) el('action-gate').textContent = 'Finish the current transaction review first.';
  else if (failed || !fresh(state)) el('action-gate').textContent = 'Fresh, verified chain data is required. Refresh figures to retry.';
  else if (!current().account) el('action-gate').textContent = 'Connect a wallet on Robinhood Chain to use the vault.';
  else if (!current().correctChain) el('action-gate').textContent = 'Switch your wallet to Robinhood Chain using the wallet control.';
  else el('action-gate').textContent = 'Wallet ready. Review each action and its gas cost before signing.';
}
function render(s: Snapshot) {
  document.querySelectorAll<HTMLElement>('[data-value]').forEach(node => {
    const key = node.dataset.value as keyof Snapshot;
    const value = s[key];
    if (typeof value === 'bigint') node.textContent = key === 'totalTendered' ? perk(value, s) : imd(value, s);
  });
  if (s.sqrt !== null && s.sqrt > 0n) {
    const [n, d] = marketFraction(s.sqrt, s.perkDecimals);
    const raw = n / d;
    el('market-price').textContent = raw === 0n && n > 0n ? `<${imd(1n, s)}` : `${imd(raw, s)}`;
    el('price-to-book').textContent = s.bookValuePerPerk === 0n ? 'Undefined' : `≈ ${ratio(n, d * s.bookValuePerPerk)}×`;
    el('valuation-note').textContent = s.bookValuePerPerk === 0n ? 'Book value is zero. There is no funded floor.' : 'Spot-price ratio, rounded down. Not an execution quote.';
    el('market-note').textContent = s.liquidity === 0n ? 'No active liquidity at this tick. The spot price may not be executable.' : s.liquidity === null ? 'Active liquidity could not be checked.' : '';
  } else {
    el('market-price').textContent = 'Unavailable'; el('price-to-book').textContent = 'Unavailable';
    el('valuation-note').textContent = 'The pool price could not be read. Refresh figures to retry.';
    el('market-note').textContent = 'No price is substituted when the pool read fails.';
  }
  const poolLink = el<HTMLAnchorElement>('pool-link');
  poolLink.href = `https://app.uniswap.org/explore/pools/robinhood/${s.pool}`; poolLink.hidden = false;
  el('last-ask').textContent = s.lastAsk === 0n ? 'Never asked' : date(s.lastAsk);
  el('total-asked').textContent = s.totalAsked.toString();
  el('ask-terms').textContent = `Spends ${imd(s.ASK_MINIMUM, s)} from the float: ${imd(s.ASK_PRICE, s)} for the oracle and ${imd(s.ASK_REWARD, s)} paid to you. You pay ETH gas.`;
  button('ask').textContent = `Ask · ${imd(s.ASK_MINIMUM, s)} from float + gas`;
  el('ask-eligibility').textContent = askReason(s) ?? 'The time and float requirements are met. Anyone may ask.';
  setTerm('hook-fee', `${formatUnits(s.FEE_BPS, 2)}%`);
  setTerm('pool-fee', `${formatUnits(s.POOL_FEE, 4)}%`);
  setTerm('total-fee', `${formatUnits(s.FEE_BPS * 100n + s.POOL_FEE, 4)}%`);
  setTerm('ask-days', `${ratio(s.ASK_INTERVAL, 86400n)} days`);
  for (const [term, value] of [['ask-minimum', s.ASK_MINIMUM], ['ask-price', s.ASK_PRICE], ['ask-reward', s.ASK_REWARD]] as const) setTerm(term, imd(value, s));
  el('read-status').textContent = `Read at block ${BigInt(s.block).toLocaleString('en-US')} · ${date(s.timestamp)}. Refreshes every 30 seconds while visible.`;
  el('read-status').classList.remove('error');
  el('balance').textContent = !current().account ? 'Connect to check your PERK balance and allowance.'
    : s.balance === null || s.allowance === null ? 'Wallet balance or allowance unavailable. Refresh figures before signing.'
    : `Your balance: ${perk(s.balance, s)}. Approved to the hook: ${perk(s.allowance, s)}.`;
}
async function refresh() {
  if (refreshing) { refreshAgain = true; return; }
  refreshing = true; controls();
  const wallet = current();
  try {
    const next = await snapshot(wallet.correctChain ? wallet.provider : undefined, wallet.account);
    if (current().account !== wallet.account || current().correctChain !== wallet.correctChain) { refreshAgain = true; return; }
    state = next; failed = false; render(next);
    await quote();
    const key = `${next.lastAsk}:${next.totalAsked}`;
    if (reportKey !== key) { reportKey = key; void report(); }
  } catch (error) {
    failed = true;
    el('read-status').textContent = `${state ? 'Last reading is stale; transactions are paused. ' : ''}${errorText(error)}`;
    el('read-status').classList.add('error');
    el('valuation-note').textContent = state ? 'Last successful reading. Refresh failed; actions are paused.' : 'Live data is unavailable. Refresh figures below.';
    el('ask-eligibility').textContent = 'Fresh chain data is unavailable. Refresh figures to check eligibility.';
    if (!state) {
      document.querySelectorAll('[data-value]').forEach(node => { node.textContent = 'Unavailable'; });
      for (const id of ['price-to-book', 'market-price', 'last-ask', 'total-asked']) el(id).textContent = 'Unavailable';
      el('report-status').textContent = 'The chain could not be read. Refresh figures before looking up the latest report.';
      el('ask-terms').textContent = 'The report’s cost could not be read. Refresh figures before asking.';
      button('ask').textContent = 'Ask weekly question · cost unavailable';
    }
    quotedPayout = null; el('quote').textContent = 'Unavailable; refresh figures';
  } finally {
    refreshing = false; controls();
    if (refreshAgain) { refreshAgain = false; void refresh(); }
  }
}
async function quote() {
  const id = ++quoteId; quotedAmount = null; quotedPayout = null;
  input.removeAttribute('aria-invalid'); el('amount-error').textContent = ''; controls();
  if (!input.value.trim()) { el('quote').textContent = 'Enter an amount'; return; }
  if (!state || failed || !fresh(state)) { el('quote').textContent = 'Waiting for fresh chain data'; return; }
  const s = state;
  try {
    const amount = parseAmount(input.value.trim(), s.perkDecimals);
    el('quote').textContent = 'Reading quote…';
    const payout = uint(await call(s.read, HOOK, 'quoteTender(uint256)', [amount], s.block));
    if (id !== quoteId || state !== s) return;
    quotedAmount = amount; quotedPayout = payout;
    el('quote').textContent = imd(payout, s);
    if (payout === 0n) el('amount-error').textContent = 'This amount currently pays zero IMD and cannot be tendered. Wait for the float to grow or try a larger amount.';
    else if (s.balance !== null && amount > s.balance) { el('amount-error').textContent = 'This exceeds your PERK balance. Enter a smaller amount.'; input.setAttribute('aria-invalid', 'true'); }
  } catch (error) {
    if (id !== quoteId) return;
    el('quote').textContent = 'Unavailable'; el('amount-error').textContent = errorText(error); input.setAttribute('aria-invalid', 'true');
  } finally { if (id === quoteId) controls(); }
}
async function report() {
  if (!state || failed) { el('report-status').textContent = 'Refresh figures first to locate the latest question.'; return; }
  const id = ++reportId, s = state;
  button('retry-report').disabled = true;
  el('report-status').textContent = 'Reading the latest question and oracle records…';
  el('report-answer').hidden = true; el('report-window').hidden = true;
  try {
    const r = await loadReport(s);
    if (id !== reportId) return;
    el('report-status').textContent = r.message;
    if (r.amount !== undefined) { el('report-answer').textContent = imd(r.amount, s); el('report-answer').hidden = false; }
    if (r.window) { el('report-window').textContent = r.window; el('report-window').hidden = false; }
    el<HTMLAnchorElement>('report-link').href = r.url ?? 'https://api.imd.fun/oracle/requests';
  } catch (error) { if (id === reportId) el('report-status').textContent = `Report unavailable. ${errorText(error)} Use “Refresh report” to retry.`; }
  finally { if (id === reportId) button('retry-report').disabled = false; }
}
function actionError(error: unknown) {
  const e = error as { data?: unknown; message?: string };
  const detail = JSON.stringify(e.data ?? '') + (e.message ?? '');
  const errors: [string, string][] = [
    ['ZeroPayout()', 'The tender now pays zero IMD. Refresh the quote before trying again.'],
    ['InsufficientBalance()', 'Your PERK balance is too small. Enter a smaller amount.'],
    ['InsufficientAllowance()', 'Approve this PERK amount to the hook before tendering.'],
    ['NothingToRedeem()', 'No pending fees can be redeemed now. The PoolManager may not hold enough IMD yet.'],
    ['TransferFailed()', 'IMD or PERK refused the transfer. A transfer switch or blocklist may prevent this action.'],
    ['AskTooSoon(uint256)', 'A weekly question was already asked. Refresh to see the next eligible time.'],
    ['FloatTooSmall(uint256)', 'The float no longer covers the weekly question. Refresh figures.']
  ];
  for (const [signature, message] of errors) if (detail.includes(data(signature).slice(2))) return message;
  return errorText(error);
}
async function verifyWallet(expected?: string) {
  const wallet = current();
  if (!wallet.provider || !wallet.account) throw new Error('Connect your wallet first.');
  const [chainId, accounts] = await Promise.all([
    wallet.provider.request({ method: 'eth_chainId' }), wallet.provider.request({ method: 'eth_accounts' })
  ]);
  if (BigInt(String(chainId)) !== BigInt(network.chainId)) throw new Error('Switch your wallet to Robinhood Chain before signing.');
  if (!Array.isArray(accounts) || String(accounts[0]).toLowerCase() !== (expected ?? wallet.account).toLowerCase()) throw new Error('The selected wallet account changed. Review the action again.');
  return { provider: wallet.provider, account: wallet.account };
}
async function prepare(kind: Action) {
  if (!canTransact()) { status('Connect on Robinhood Chain and refresh figures before using the vault.', true); return; }
  busy = true; controls(); status('Checking the current state and estimating gas…');
  try {
    const wallet = await verifyWallet();
    const s = await snapshot(wallet.provider, wallet.account);
    state = s; failed = false; render(s);
    const amount = kind === 'approve' || kind === 'tender' ? parseAmount(input.value.trim(), s.perkDecimals) : 0n;
    let payout = 0n;
    if (amount > 0n) {
      if (s.balance === null || s.allowance === null) throw new Error('Your balance and allowance could not be checked. Refresh figures.');
      if (amount > s.balance) throw new Error('This amount exceeds your PERK balance.');
      payout = uint(await call(s.read, HOOK, 'quoteTender(uint256)', [amount], s.block));
      if (payout === 0n) throw new Error('The quote is zero IMD. This amount cannot be tendered yet.');
      if (kind === 'approve' && s.allowance >= amount) throw new Error('This amount is already approved. Use the tender button.');
      if (kind === 'tender' && s.allowance < amount) throw new Error('Approve this PERK amount first.');
    }
    if (kind === 'ask' && askReason(s)) throw new Error(askReason(s)!);
    if (kind === 'redeem' && s.pendingFloat === 0n) throw new Error('There are no pending fees to redeem.');
    if (kind === 'burn' && s.burnDue === 0n) throw new Error('No IMD is due to the burn.');
    const tx: Transaction = { from: wallet.account, to: kind === 'approve' ? PERK : HOOK, value: '0x0', data: kind === 'approve' ? data('approve(address,uint256)', [HOOK, amount]) : kind === 'tender' ? data('tender(uint256)', [amount]) : data(kind === 'redeem' ? 'redeemPendingFees()' : `${kind}()`) };
    const simulation = await s.read('eth_call', [tx, 'latest']);
    if (kind === 'tender') payout = uint(simulation);
    if (kind === 'burn' && uint(simulation) === 0n) throw new Error('The burn would move no IMD right now. IMD may be refusing the transfer; no transaction was sent.');
    const [gasResult, gasPriceResult] = await Promise.all([s.read('eth_estimateGas', [tx]), s.read('eth_gasPrice')]);
    const gas = (BigInt(String(gasResult)) * 120n + 99n) / 100n, gasPrice = BigInt(String(gasPriceResult));
    tx.gas = hex(gas);
    await verifyWallet(wallet.account);
    prepared = { kind, amount, quote: payout, tx, s, gas, gasPrice, account: wallet.account };
    showReview(prepared); status('Review the action and cost. Your wallet has not been asked to sign yet.'); review().returnValue = ''; review().showModal();
  } catch (error) { busy = false; status(actionError(error), true); if (kind === 'tender' || kind === 'approve') void quote(); }
  finally { controls(); }
}
function showReview(p: Prepared) {
  const descriptions: Record<Action, string> = {
    approve: `Approve exactly ${perk(p.amount, p.s)} to the PerkVaultHook. Approval spends no PERK and transfers no IMD. A separate tender transaction is required.`,
    tender: `Permanently burn ${perk(p.amount, p.s)} and receive a currently simulated ${imd(p.quote, p.s)} from the float.`,
    redeem: `Redeem as much of the ${imd(p.s.pendingFloat, p.s)} pending claims as is available into the hook, then attempt the burn. You receive no payment.`,
    burn: `Attempt to burn the ${imd(p.s.burnDue, p.s)} owed by the hook by sending available reserved IMD to the dead address. You receive no payment.`,
    ask: `Spend ${imd(p.s.ASK_MINIMUM, p.s)} from the float to commission the weekly report. The oracle receives ${imd(p.s.ASK_PRICE, p.s)} and you receive ${imd(p.s.ASK_REWARD, p.s)}. An answer is not guaranteed.`
  };
  el('review-title').textContent = `Review ${p.kind === 'redeem' ? 'pending fee redemption' : p.kind === 'ask' ? 'weekly question' : p.kind === 'approve' ? 'PERK approval' : p.kind === 'burn' ? 'IMD burn' : 'PERK tender'}`;
  el('review-body').textContent = descriptions[p.kind];
  el('review-gas').textContent = `Estimated gas budget: ${formatUnits(p.gas * p.gasPrice, network.nativeCurrency.decimals)} ETH (includes a 20% gas-unit buffer at the current gas price). Your wallet shows the final fee. No ETH is sent to the contract.`;
  el('review-recipient').textContent = `Robinhood Chain (${network.chainId}) · From ${checksum(p.account)} · Contract ${checksum(p.tx.to)}${p.kind === 'approve' ? ` · Spender ${checksum(HOOK)}` : ''}`;
  el('review-warning').textContent = p.kind === 'tender' ? 'This burn cannot be undone. The payout may change before inclusion and the contract has no minimum-payout protection. A failed transaction can still cost gas.' : 'State and gas prices can change before inclusion. A failed transaction can still cost gas.';
  button('confirm-transaction').textContent = p.kind === 'approve' ? 'Sign exact approval · ETH gas' : p.kind === 'tender' ? 'Sign PERK burn for IMD · ETH gas' : p.kind === 'ask' ? `Sign question · ${imd(p.s.ASK_MINIMUM, p.s)} from float + gas` : p.kind === 'burn' ? 'Sign IMD burn · ETH gas only' : 'Sign fee redemption · ETH gas only';
}
async function submit() {
  const p = prepared;
  if (!p || button('confirm-transaction').disabled) return;
  button('confirm-transaction').disabled = true; button('cancel-transaction').disabled = true;
  try {
    const wallet = await verifyWallet(p.account);
    // Repeat the read-only simulation immediately before the wallet opens.
    const s = await snapshot(wallet.provider, wallet.account);
    if (p.kind === 'ask' && askReason(s)) throw new Error(askReason(s)!);
    const result = await s.read('eth_call', [p.tx, 'latest']);
    if (p.kind === 'burn' && uint(result) === 0n) throw new Error('The burn now moves no IMD. Refresh figures before trying again.');
    if (p.kind === 'tender' && uint(result) !== p.quote) {
      p.quote = uint(result); p.s = s; showReview(p);
      el('review-warning').textContent = 'The payout changed while you reviewed. Read the new quote, then sign again if you accept it. There is no minimum-payout protection.';
      return;
    }
    await verifyWallet(p.account);
    review().close('sign'); status('Waiting for your wallet. Check the action, Robinhood Chain and gas fee before signing.');
    const hash = await wallet.provider.request({ method: 'eth_sendTransaction', params: [{ ...p.tx, chainId: hex(network.chainId) }] });
    if (typeof hash !== 'string' || !/^0x[0-9a-f]{64}$/i.test(hash)) throw new Error('The wallet returned no valid transaction hash. Check your wallet activity before retrying.');
    pending = { hash, kind: p.kind, account: p.account }; persistPending();
    displayPending(); prepared = null; void pollReceipt();
  } catch (error) { review().close('error'); status(actionError(error), true); }
  finally { button('confirm-transaction').disabled = false; button('cancel-transaction').disabled = false; if (!review().open) { busy = false; prepared = null; } controls(); }
}
const pendingKey = 'perkshire.pending';
function persistPending() { try { if (pending) localStorage.setItem(pendingKey, JSON.stringify(pending)); else localStorage.removeItem(pendingKey); } catch { /* The explorer link remains available. */ } }
function displayPending() {
  if (!pending) return;
  status('Transaction submitted; awaiting inclusion on Robinhood Chain. Do not submit it again.');
  const link = el<HTMLAnchorElement>('transaction-link'); link.href = `${network.explorer}/tx/${pending.hash}`; link.hidden = false;
  button('check-receipt').hidden = false; controls();
}
function eventAmounts(receipt: Receipt, signature: string, index = 0) {
  return receipt.logs.filter(log => log.address.toLowerCase() === HOOK && log.topics[0]?.toLowerCase() === topic(signature)).reduce((sum, log) => sum + uint(log.data, index), 0n);
}
async function checkReceipt(): Promise<boolean> {
  if (!pending) return true;
  const tx = pending;
  const read = state?.read ?? (await snapshot(current().correctChain ? current().provider : undefined)).read;
  const receipt = await read('eth_getTransactionReceipt', [tx.hash]) as Receipt | null;
  if (!receipt) return false;
  if (pending?.hash !== tx.hash) return true;
  pending = null; persistPending(); button('check-receipt').hidden = true; button('stop-tracking').hidden = true;
  if (BigInt(receipt.status) === 0n) status('Transaction reverted onchain. No contract action completed; gas was spent. Refresh figures and review your wallet’s transaction details.', true);
  else {
    await refresh();
    const blockText = ` Included at block ${BigInt(receipt.blockNumber).toLocaleString('en-US')}.`;
    if (tx.kind === 'approve') status('Approval confirmed. Review the current quote, then use the tender button.' + blockText);
    else if (tx.kind === 'tender' && state) status(`Tender confirmed. ${perk(eventAmounts(receipt, 'Tendered(address,uint256,uint256)'), state)} burned; ${imd(eventAmounts(receipt, 'Tendered(address,uint256,uint256)', 1), state)} paid to ${checksum(tx.account)}.` + blockText);
    else if (tx.kind === 'burn' && state) { const amount = eventAmounts(receipt, 'Burned(uint256)'); status(amount > 0n ? `${imd(amount, state)} burned.` + blockText : 'Transaction confirmed, but no IMD was burned. The transfer may have been refused.' + blockText); }
    else if (tx.kind === 'redeem' && state) status(`${imd(eventAmounts(receipt, 'PendingFeesRedeemed(address,uint256)'), state)} redeemed into the hook.` + blockText);
    else if (tx.kind === 'ask') status('Weekly question commissioned. Check the report section for its eventual answer.' + blockText);
    else status('Transaction confirmed. Refresh figures to read the result.' + blockText);
  }
  controls(); return true;
}
async function pollReceipt() {
  if (polling) return;
  polling = true; button('check-receipt').disabled = true;
  try {
    for (let attempt = 0; attempt < 40 && pending; attempt++) {
      if (await checkReceipt()) return;
      await new Promise(resolve => setTimeout(resolve, 3000));
    }
    if (pending) { status('Confirmation is taking longer than expected. The transaction may still be pending or replaced. Check the explorer or use “Check transaction status”; do not resubmit blindly.'); button('stop-tracking').hidden = false; }
  } catch (error) { status(`The transaction was submitted, but its receipt could not be read. ${errorText(error)} Check the explorer or retry the status check.`, true); button('stop-tracking').hidden = !pending; }
  finally { polling = false; button('check-receipt').disabled = false; controls(); }
}
let quoteTimer: ReturnType<typeof setTimeout>;
input.addEventListener('input', () => { ++quoteId; quotedAmount = null; quotedPayout = null; controls(); clearTimeout(quoteTimer); quoteTimer = setTimeout(() => void quote(), 300); });
el('tender-form').addEventListener('submit', e => { e.preventDefault(); if (!button('tender-button').disabled) void prepare('tender'); else { void quote(); input.focus(); } });
for (const kind of ['approve', 'redeem', 'burn', 'ask'] as const) button(kind).addEventListener('click', () => void prepare(kind));
button('refresh').addEventListener('click', () => void refresh());
button('retry-report').addEventListener('click', () => void report());
button('confirm-transaction').addEventListener('click', () => void submit());
button('cancel-transaction').addEventListener('click', () => review().close('cancel'));
review().addEventListener('cancel', event => { if (button('confirm-transaction').disabled) event.preventDefault(); });
review().addEventListener('close', () => { if (review().returnValue !== 'sign' && review().returnValue !== 'error' && !button('confirm-transaction').disabled) { prepared = null; busy = false; status('Review cancelled. No transaction was submitted.'); controls(); } });
button('check-receipt').addEventListener('click', () => void pollReceipt());
button('stop-tracking').addEventListener('click', () => el<HTMLDialogElement>('tracking-dialog').showModal());
button('keep-tracking').addEventListener('click', () => el<HTMLDialogElement>('tracking-dialog').close());
button('confirm-stop').addEventListener('click', () => {
  pending = null; persistPending(); button('check-receipt').hidden = true; button('stop-tracking').hidden = true;
  el<HTMLDialogElement>('tracking-dialog').close(); status('Local tracking cleared. The transaction has not been cancelled. Check your wallet’s activity before taking another action.'); controls();
});
initWallet(() => { quotedPayout = null; ++quoteId; if (review().open) review().close(); controls(); void refresh(); });
try {
  const stored = JSON.parse(localStorage.getItem(pendingKey) ?? 'null') as Pending | null;
  if (stored && /^0x[0-9a-f]{64}$/i.test(stored.hash) && /^0x[0-9a-f]{40}$/i.test(stored.account) && ['approve', 'tender', 'redeem', 'burn', 'ask'].includes(stored.kind)) { pending = stored; displayPending(); void pollReceipt(); }
} catch { /* No stored pending transaction. */ }
setInterval(() => { controls(); if (document.visibilityState === 'visible' && !busy) void refresh(); }, 30000);
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && !busy) void refresh(); });
