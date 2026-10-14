import { addChain, checksum, network, type Provider } from './chain';

export const el = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id)! as T;
type Wallet = { id: string; name: string; icon: string; provider: Provider };
type Announcement = { info: { uuid: string; name: string; icon: string; rdns: string }; provider: Provider };
declare global { interface Window { ethereum?: Provider; } }
const wallets = new Map<string, Wallet>();
const dialog = () => el<HTMLDialogElement>('wallet-dialog');
const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const mobile = () => /Android|iPhone|iPad|iPod/i.test(navigator.userAgent);
const key = 'perkshire.wallet';
let active: Wallet | undefined, account: string | undefined, chain: string | undefined, connecting = false;
let pendingWallet: Wallet | undefined;
let onChange: () => void;
let walletGeneration = 0;
export const current = () => ({ provider: active?.provider, account, correctChain: chain ? BigInt(chain) === BigInt(network.chainId) : false });
function remember(id?: string) { try { if (id) localStorage.setItem(key, id); else localStorage.removeItem(key); } catch { /* Private browsing can refuse persistence. */ } }
function remembered() { try { return localStorage.getItem(key); } catch { return null; } }
export function errorText(error: unknown): string {
  const e = error as { code?: number; message?: string; data?: { originalError?: { code?: number } } };
  if (e.code === 4001 || e.data?.originalError?.code === 4001) return 'Request declined in your wallet. Nothing was submitted; you can try again.';
  if (e.code === -32002) return 'A wallet request is already open. Finish or dismiss it in your wallet, then retry.';
  if (e.code === 4900 || e.code === 4901) return 'Your wallet is disconnected from this chain. Reconnect and try again.';
  return e.message?.slice(0, 360) || 'The request failed. Refresh figures and try again.';
}
function update() {
  const state = current();
  el<HTMLButtonElement>('connect').textContent = account
    ? state.correctChain ? `${short(checksum(account))} · Wallet` : 'Switch to Robinhood Chain · free'
    : 'Connect wallet · free';
  el('wallet-hint').textContent = account ? state.correctChain ? 'Robinhood Chain · ETH for gas' : 'Transactions paused on this network.' : 'No signature to connect.';
  el('connected-details').hidden = !account;
  el('connected-address').textContent = account ? checksum(account) : '';
  el('wallet-title').textContent = account ? 'Your wallet' : 'Connect a wallet';
  onChange?.();
}
const accountsChanged = (...args: unknown[]) => {
  const values = args[0];
  account = Array.isArray(values) && typeof values[0] === 'string' && /^0x[0-9a-f]{40}$/i.test(values[0]) ? values[0] : undefined;
  if (!account) remember();
  walletGeneration++; update();
};
const chainChanged = (...args: unknown[]) => {
  chain = typeof args[0] === 'string' && /^0x[0-9a-f]+$/i.test(args[0]) ? args[0] : undefined;
  walletGeneration++; update();
};
const disconnected = () => { detach(); active = undefined; account = undefined; chain = undefined; walletGeneration++; remember(); update(); };
function detach() {
  active?.provider.removeListener?.('accountsChanged', accountsChanged);
  active?.provider.removeListener?.('chainChanged', chainChanged);
  active?.provider.removeListener?.('disconnect', disconnected);
}
async function connect(wallet: Wallet, silent = false) {
  if (connecting) return;
  connecting = true;
  pendingWallet = wallet;
  const generation = ++walletGeneration;
  if (!silent) el('wallet-status').textContent = `Opening ${wallet.name}. Connection is free.`;
  renderWallets(wallet.id);
  try {
    const accounts = await wallet.provider.request({ method: silent ? 'eth_accounts' : 'eth_requestAccounts' });
    const chainId = await wallet.provider.request({ method: 'eth_chainId' });
    if (generation !== walletGeneration) return;
    if (!Array.isArray(accounts) || !/^0x[0-9a-f]{40}$/i.test(String(accounts[0]))) throw new Error('No account was connected. Select an account in your wallet and try again.');
    if (!/^0x[0-9a-f]+$/i.test(String(chainId))) throw new Error('Your wallet returned an invalid network.');
    detach(); active = wallet; account = String(accounts[0]); chain = String(chainId);
    active.provider.on?.('accountsChanged', accountsChanged);
    active.provider.on?.('chainChanged', chainChanged);
    active.provider.on?.('disconnect', disconnected);
    remember(wallet.id); dialog().close(); el('wallet-status').textContent = ''; update();
  } catch (error) { if (!silent && generation === walletGeneration) el('wallet-status').textContent = errorText(error); }
  finally { if (generation === walletGeneration) { connecting = false; pendingWallet = undefined; renderWallets(); } }
}
async function switchChain() {
  if (!active || connecting) return;
  connecting = true; el<HTMLButtonElement>('connect').disabled = true;
  try {
    try { await active.provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: addChain.chainId }] }); }
    catch (error) {
      const e = error as { code?: number; data?: { originalError?: { code?: number } } };
      if (e.code !== 4902 && e.data?.originalError?.code !== 4902) throw error;
      await active.provider.request({ method: 'wallet_addEthereumChain', params: [addChain] });
      await active.provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: addChain.chainId }] });
    }
    chain = String(await active.provider.request({ method: 'eth_chainId' }));
    if (BigInt(chain) !== BigInt(network.chainId)) throw new Error('The wallet has not switched. Select Robinhood Chain, then retry.');
    el('transaction-status').textContent = 'Wallet switched to Robinhood Chain. No transaction was sent.';
  } catch (error) { el('transaction-status').textContent = errorText(error); }
  finally { connecting = false; el<HTMLButtonElement>('connect').disabled = false; update(); }
}
export const openLinks = (url: string) => [
  { id: 'metamask', name: 'MetaMask', href: `https://link.metamask.io/dapp/${url.replace(/^https?:\/\//, '')}` },
  { id: 'coinbase', name: 'Coinbase Wallet', href: `https://go.cb-w.com/dapp?cb_url=${encodeURIComponent(url)}` },
  { id: 'phantom', name: 'Phantom', href: `https://phantom.app/ul/browse/${encodeURIComponent(url)}?ref=${encodeURIComponent(new URL(url).origin)}` }
];
function row(label: string, icon: string, href?: string) {
  const node = document.createElement(href ? 'a' : 'button');
  node.className = 'wallet-row';
  if (node instanceof HTMLAnchorElement) node.href = href!;
  else { node.type = 'button'; node.disabled = connecting; }
  const image = document.createElement('img'); image.src = icon; image.alt = ''; image.width = 28; image.height = 28;
  const text = document.createElement('span'); text.textContent = label; node.append(image, text);
  return node;
}
function renderWallets(pending?: string) {
  const list = el('wallet-list'); list.replaceChildren(); list.hidden = !!account;
  const entries = Array.from(wallets.values());
  if (!entries.length && window.ethereum) entries.push({ id: 'browser', name: 'Browser wallet', icon: './assets/browser-wallet.svg', provider: window.ethereum });
  for (const wallet of entries) {
    const button = row(wallet.name + (pending === wallet.id ? ' · opening…' : ' · connect free'), wallet.icon);
    button.addEventListener('click', () => void connect(wallet)); list.append(button);
  }
  if (mobile() && !entries.length) for (const wallet of openLinks(location.href)) list.append(row(`Open in ${wallet.name} · free`, `./assets/${wallet.id}.svg`, wallet.href));
  if (!mobile() && !entries.length) {
    const note = document.createElement('p'); note.className = 'small'; note.textContent = 'No browser extension found. Unlock an installed wallet, or use Coinbase Wallet below.'; list.append(note);
  }
  const coinbase = row(`${mobile() ? 'Coinbase Smart Wallet' : 'Coinbase Wallet / Smart Wallet'}${pending === 'coinbase' ? ' · opening…' : ' · connect free'}`, './assets/coinbase.svg');
  coinbase.addEventListener('click', async () => {
    if (connecting) return;
    coinbase.setAttribute('disabled', '');
    el('wallet-status').textContent = 'Loading Coinbase Wallet…';
    try { const { coinbaseProvider } = await import('./coinbase'); if (dialog().open) await connect({ id: 'coinbase', name: 'Coinbase Wallet', icon: './assets/coinbase.svg', provider: coinbaseProvider(mobile()) }); }
    catch (error) { el('wallet-status').textContent = `${errorText(error)} If Coinbase does not support Robinhood Chain, choose a browser wallet.`; }
    finally { coinbase.removeAttribute('disabled'); }
  });
  list.append(coinbase);
}
export function initWallet(change: () => void) {
  onChange = change;
  window.addEventListener('eip6963:announceProvider', event => {
    const detail = (event as CustomEvent<Announcement>).detail;
    if (!detail?.info || typeof detail.provider?.request !== 'function' || typeof detail.info.rdns !== 'string') return;
    const id = detail.info.rdns;
    if (wallets.has(id)) return;
    const icon = typeof detail.info.icon === 'string' && /^data:image\/(svg\+xml|png|webp|jpeg)[;,]/i.test(detail.info.icon) ? detail.info.icon : './assets/browser-wallet.svg';
    const wallet = { id, name: String(detail.info.name).slice(0, 80), icon, provider: detail.provider };
    wallets.set(id, wallet); if (dialog().open) renderWallets();
    if (!active && remembered() === id) void connect(wallet, true);
  });
  window.dispatchEvent(new Event('eip6963:requestProvider'));
  if (remembered() === 'browser' && window.ethereum) void connect({ id: 'browser', name: 'Browser wallet', icon: './assets/browser-wallet.svg', provider: window.ethereum }, true);
  if (remembered() === 'coinbase') void import('./coinbase').then(({ coinbaseProvider }) => connect({ id: 'coinbase', name: 'Coinbase Wallet', icon: './assets/coinbase.svg', provider: coinbaseProvider(mobile()) }, true)).catch(() => {});
  el('connect').addEventListener('click', () => {
    if (account && !current().correctChain) { void switchChain(); return; }
    renderWallets(); dialog().showModal();
  });
  el('close-wallet').addEventListener('click', () => dialog().close());
  dialog().addEventListener('close', () => {
    // Some wallets leave eth_requestAccounts unresolved after their popup closes.
    // Closing our chooser abandons that connection attempt without losing retry.
    if (connecting && !account && pendingWallet) {
      const abandoned = pendingWallet;
      walletGeneration++; connecting = false; pendingWallet = undefined;
      if (abandoned.id === 'coinbase') void abandoned.provider.disconnect?.().catch(() => {});
      el('wallet-status').textContent = 'Connection dismissed. Close any remaining wallet prompt before trying again.';
      renderWallets();
    }
    el('connect').focus();
  });
  dialog().addEventListener('click', e => { if (e.target === dialog()) { const r = dialog().getBoundingClientRect(); if (e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom) dialog().close(); } });
  el('disconnect').addEventListener('click', () => { const provider = active?.id === 'coinbase' ? active.provider : undefined; disconnected(); dialog().close(); void provider?.disconnect?.().catch(() => {}); });
  update();
}
