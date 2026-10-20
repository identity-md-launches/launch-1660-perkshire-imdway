# Perkshire IMDway (PERK)

The **perk** site is an immediate redirect to **https://perkshire-imdway-perk-on-robinho.sites.imd.fun/**. Its only HTML source is `web/index.html`. The head contains a zero-delay meta refresh and a synchronous `location.replace`; the body contains one plain fallback link. No former app, wallet code, styles, logos or local runtime assets remain in the export.

Launch 1660 on Robinhood Chain (4663) is unchanged. This change does not deploy or transact with any contract. The destination is the creator's supplied delegate-wallet site; verifying the delegation is outside this website change.

## Install, rebuild and preview

Requires Node.js 22+ and npm. The production build itself uses only Node built-ins and needs no installation:

```sh
node web/scripts/build.mjs
node web/scripts/preview.mjs
```

Open `http://127.0.0.1:4173/preview/` to exercise the actual redirect. Stop preview with Ctrl-C; `--port 4174` selects another port. Preview also returns the redirect document for unknown paths, with status 404.

Install the existing locked development tools in disposable scratch space to run the checks:

```sh
mkdir -p test/scratch/toolchain
cp web/package.json web/package-lock.json test/scratch/toolchain/
npm ci --prefix test/scratch/toolchain --cache test/scratch/npm-cache
node web/scripts/typecheck.mjs --toolchain test/scratch/toolchain
PLAYWRIGHT_BROWSERS_PATH=test/scratch/browsers node test/scratch/toolchain/node_modules/playwright/cli.js install chromium webkit
PLAYWRIGHT_BROWSERS_PATH=test/scratch/browsers node web/scripts/check.mjs --toolchain test/scratch/toolchain
```

The existing `web/package.json`, lockfile and TypeScript configuration are preserved. Their wallet dependencies are no longer imported or bundled. `--toolchain` accepts a directory containing the installed development packages; omit it when the packages are installed beside `web/package.json`. The preserved npm build, typecheck, check and preview scripts still invoke these same scripts. The typecheck uses TypeScript strict/checkJs/noEmit on the actual inline script and syntax-checks the Node scripts.

`check.mjs` starts and closes its own preview and intercepts external navigation. It tests the production HTML, script-only history behavior, JavaScript-disabled meta refresh, old paths and the fallback link. For fallback inspection only, its test response suppresses the two redirect directives without changing the link or metadata. It tests both Chromium and WebKit by default; `--engine chromium` or `--engine webkit` selects one. A missing requested browser fails the command.

## Static export and old paths

The build replaces `dist/` completely and produces only:

- `index.html`: a byte-for-byte copy of the single source page.
- `404.html`: an identical copy of that page for custom not-found handling.
- `_redirects`: `/* https://perkshire-imdway-perk-on-robinho.sites.imd.fun/ 301` for hosts/gateways supporting this convention.

The previous export had only one HTML page, so its section anchors and query URLs all enter the same redirect. The new destination is always the exact root URL above; old queries and fragments are discarded. The script replaces the history entry so Back does not return to the redirect.

Serve the complete `dist/` contents. Unknown paths redirect when the host honors `_redirects` or serves `404.html` for missing paths. A host supporting neither must map all old paths to this index; static HTML alone cannot set an arbitrary server's routing policy. Deployment, gateway policy and live routing after publication were not exercised by this change.

There are no local runtime asset URLs to break at a gateway subpath. The required head-only favicon and `og:image` reference the destination's existing `assets/investor-pepe.png` by absolute URL; that image is not included in the page body or copied into this export. It returned HTTP 200 as `image/png` during validation. Its future availability and social-crawler behavior are external dependencies.

## Actual website validation

Production build and strict inline-script typecheck passed. The locked toolchain was installed successfully. **Seven grouped checks passed in Chromium**, including real production navigation, meta-only navigation with JavaScript disabled, script-only replacement/history, old paths, keyboard Enter, reflow at 320/390/768/1440, 200% text enlargement, and five applicable axe rules with zero violations. The browser tool also followed the actual export to the supplied live URL and confirmed the 390px fallback and visible focus screenshots.

WebKit was attempted but could not launch its runtime; its interaction and rendering checks remain unperformed. The pinned design probe on the redirecting export reported 14/16: automatic navigation leaves no original body or head to measure, so `render` and `share` failed. A separately identified test-only fallback fixture passed 16/16; that result is not a full-export probe pass.

See [VALIDATION.md](VALIDATION.md) for commands, review coverage, findings and limitations, and [DESIGN.md](DESIGN.md) for the final source's deliberately absent styling system. Screenshots, browser downloads, dependency installations, caches and raw reports stay in disposable `test/scratch/`. No ignore-file changes, dependency archives, generated package trees or submodules are submitted. Original contract documentation follows; its historical contract test results were not rerun for this website-only change.

## Token and Retained Earnings Vault hook

Foundry project for the Perkshire IMDway token and its Uniswap v4 hook on Robinhood Chain
(chain id 4663), paired with IMD. The hook is also the project's vault: it collects a 1% IMD fee on
every swap, burns half of it, keeps half as the insurance float, lets any holder tender PERK to the
float at book value, and once a week buys one answer from the IdentityMD oracle.

Parody only: not affiliated with Berkshire Hathaway, Warren Buffett or Charlie Munger. PERK is not a
share or equity in any company. No emissions, rebases, staking APY, admin keys or promised yield.

| Contract | File | Role |
| --- | --- | --- |
| `PerkToken` | `src/PerkToken.sol` | The launch token: name `Perkshire IMDway`, symbol `PERK`, 18 decimals, 1,000,000,000 tokens minted once to the deployer (the factory). |
| `PerkVaultHook` | `src/PerkVaultHook.sol` | The pool's hook and the vault: 1% IMD fee, burn, float, tender, ask. |
| `IIntake` | `src/IIntake.sol` | The oracle Intake's interface, as the `oracle-consumer` reference gives it. |
| `HookFlags` | `src/HookFlags.sol` | Internal library with the v4 permission bits (tests and address mining). |

## What the hook does

### 1. Binding: exactly one pool

`beforeInitialize` admits one pool and only one. It requires, in order:

- the initializer (`sender`) is the launch factory (`factory`, a constructor argument written `$factory`);
- the pool's currencies are exactly PERK (`perk`, `$token`) and IMD (`imd`), in either sort order;
- the LP fee is 12500 (1.25%) and static: a dynamic-fee flag or any other fee reverts (`WrongFee`);
- no pool is bound yet (`AlreadyBound` otherwise).

It then records the pool id in `boundPool` and emits `PoolBound(poolId, tickSpacing)`. Tick spacing
is not checked: the factory's choice (60 for this launch) is accepted as is. Every other
initialization reverts: a non-factory sender, a look-alike token paired with IMD, a pool without
IMD or with native ETH, a wrong or dynamic fee, a second PERK/IMD pool at another spacing, or the
bound pool again. `beforeSwap` and `afterSwap` also refuse any key that is not the bound pool. This
is deliberately not #1330's open binding, which let anyone open more IMD pools on its hook.

### 2. The float: 1% of the IMD side, half burned, half kept

The fee logic is launch #1330's `RnnnFeeHook` at commit `7001624`
(`identity-md-launches/launch-1330-launch-rnnn-bid-community-token`), unchanged: `simulateSwap`, the
specified/unspecified return deltas, deferral as ERC-6909 claims, `redeemPendingFees`, and the same
five permission bits. The only difference is the recipient: the hook itself.

On every swap in the bound pool the hook takes 1% of the IMD the pool moves, as #1330 measures it:

| Swap | IMD amount the fee is 1% of | Where it is taken |
| --- | --- | --- |
| Buy, exact input (pay N IMD) | N | `beforeSwap`, specified delta (after a simulation of the fill) |
| Buy, exact output (want M PERK) | the IMD the pool charges for M | `afterSwap`, unspecified delta |
| Sell, exact input (pay M PERK) | the IMD the pool pays out | `afterSwap`, unspecified delta |
| Sell, exact output (want N IMD) | N | `beforeSwap`, specified delta (after a simulation) |

On a short fill (price limit, or no liquidity in that direction) it is 1% of the IMD actually
moved; a swap that moves no IMD pays nothing. Rounding is down. The fee is on top of the pool's
1.25% LP fee, which the hook never touches. It is taken in IMD and never in PERK. On the requester's
explicit instruction the fee stays in IMD (the vault's asset) and is not sold for ETH, departing
from the IMD default of settling hook fees in ETH.

**Split.** Each fee is split once, at the moment it is taken, whether it was paid out or deferred:
`fee / 2` (rounded down) is added to `burnOwed`, the rest to `totalFloat`, and `FloatCollected(poolId,
amount, toBurn, toFloat, paidNow)` is emitted. Nothing is counted again at redemption.

**Paid or deferred.** Inside `afterSwap` the hook takes the fee from the PoolManager
(`poolManager.take(imd, address(this), fee)`) when the manager's IMD balance at that moment covers
it and IMD accepts the transfer. Routers settle the swap's input after the hook runs, so every sell
is paid at once and a buy is paid at once only when the manager already holds at least the fee in
IMD. On the launch pool, seeded with PERK only, the first buys are deferred: the hook mints itself an
ERC-6909 claim on IMD for the fee. `pendingFloat()` is the deferred amount. The next swap that finds
enough IMD in the manager flushes pending claims to the hook, and anyone may call
`redeemPendingFees()` at any time. Pending claims do not back tenders until redeemed.

A deferred fee's burn half is recorded twice over: in `burnOwed`, like every burn half, and in
`deferredBurn`, which says how much of `burnOwed` is still waiting for its claim. The burn never
pays that part out of IMD the hook already holds: it is paid when the claim is redeemed (by
`redeemPendingFees()` or by the next swap's flush), out of the redeemed IMD first. So a deferred
fee, whether it happens on the launch pool's first buys or is forced by a swapper that empties the
manager's IMD inside its own unlock before swapping, leaves the float on hand, `bookValuePerPerk`,
`quoteTender`, tenders and asks exactly where they were, and only raises them once redeemed.
`burnDue()` is `burnOwed - deferredBurn`, the part the burn can take now.

`pendingFloat()` reads the hook's ERC-6909 IMD balance. Anyone who pays IMD into the manager inside
an unlock can mint such a claim to the hook; it shows in `pendingFloat()`, is redeemed like a fee,
and reaches the float with `totalFloat`, `burnOwed` and `totalBurned` unchanged: it is a donation
and can only raise book value (`deferredBurn` is released against it first, which burns no more
than was already owed). Only in that case does `pendingFloat()` exceed the deferred fees.

**Burn.** `_burn()` sends `min(burnOwed - deferredBurn, hook's IMD balance)` to
`0x000000000000000000000000000000000000dEaD`, lowers `burnOwed`, raises `totalBurned` and emits
`Burned`. It runs after every fee that reaches the hook, after every redeem, at the start of every
tender and ask, and whenever anyone calls `burn()`. If IMD refuses the transfer (the live IMD has an
admin blocklist), the amount stays owed and nothing reverts; the next trigger retries.

### 3. Tender: PERK for IMD at book value

`tender(amount)`:

1. runs the burn;
2. computes `payout = amount * (hook's IMD balance - burnDue) / (totalSupply - PERK held by dEaD)`,
   rounded down, with the dead balance read before this tender, where `burnDue` is `burnOwed`
   less the burn halves of fees still pending as claims (those are paid from the claims, not from
   the balance);
3. reverts with `ZeroPayout` if that is zero (no float yet, a dust amount, or `amount == 0`);
4. moves `amount` PERK from the caller to 0x…dEaD (`transferFrom(msg.sender, dEaD, amount)`: the
   caller needs an allowance to the hook), adds it to `totalTendered`;
5. transfers the payout in IMD to the caller and emits `Tendered(holder, perkAmount, imdPaid)`.

Because the payout rounds down, book value per PERK never falls on a tender; it stays equal or
rises by the rounding dust. Tendered PERK is burned (it sits at 0x…dEaD and leaves the circulating
supply the book value is computed over). A reentrancy guard covers `tender`, `ask`, `burn` and
`redeemPendingFees`; ERC-20 calls check return values and tolerate tokens that return nothing.

### 4. Ask: the Chairman's weekly report

`ask()`, callable by anyone:

- reverts with `AskTooSoon` if fewer than 7 days (`ASK_INTERVAL`) have passed since `lastAsk`; the
  first ask may happen at any time;
- runs the burn, then requires the float (balance less `burnDue`) to be at least 0.6 IMD
  (`ASK_MINIMUM`), else `FloatTooSmall`;
- approves exactly 0.5 IMD (`ASK_PRICE`) to the Intake `0xa43e6F75ee006411F79Ac1C84120606C2330DE82`
  and calls `request(bytes32("oracle.request@oracle-1"), BODY, Callback(address(0), bytes4(0)),
  imd, 0.5 IMD)`; if any allowance were left it is reset to zero;
- pays the caller 0.1 IMD (`ASK_REWARD`), records `lastAsk = block.timestamp`, increments
  `totalAsked` (the number of answers bought) and emits `Asked(requestId, caller)`.

No callback is registered and no signature is checked: the vault is a paying customer, and the
answer (how much IMD reached 0x…dEaD in the past 168 hours) is read from the oracle's own records.
`BODY` is the brief's JSON byte for byte; its keccak-256 is
`0x0e84c095ed9c231763b35dc8959f58978742666369a6f19d78d0bbff1acb307b` (402 bytes), asserted in tests.

The `oracle-consumer` reference asks for the intake, action and price to be owner-settable. This
launch has no owner by the requester's rule, and the brief fixes all three ("approve exactly 0.5
IMD to the Intake ... and call request(..., imd, 0.5 IMD)"), so they are constants and the hook
does not read `priceOf` from the Intake. If the Intake moves or the price changes, `ask()` stops
working for good (the Intake reverts and nothing is spent; `lastAsk` and `totalAsked` do not move);
the rest of the vault is unaffected. This is a trust assumption the requester chose, recorded here
knowingly. See "Operational responsibilities".

### 5. Where IMD can go, and the views

IMD leaves the hook only by a tender payout, the burn (to 0x…dEaD) and an ask (0.5 to the Intake,
0.1 to the caller). There is no withdraw, sweep, rescue or owner path, no `receive` and no fallback.

Views: `perk`, `imd`, `factory`, `poolManager`, `boundPool`, `totalFloat`, `pendingFloat`,
`burnOwed`, `deferredBurn`, `burnDue`, `totalBurned`, `lastAsk`, `totalAsked`, `totalTendered`,
`bookValuePerPerk` (IMD per PERK, 18 decimals: `(balance - burnDue) * 1e18 / (totalSupply - dead)`,
where `burnDue = burnOwed - deferredBurn`), plus `floatBalance`, `circulatingSupply`,
`quoteTender(amount)` and `feeFor(imdAmount)`.

Book value starts at zero, rises only from the float (fees and any IMD donated to the hook), never
from newly issued tokens (there are none), and at realistic volume stays far below market price. It
only matters if price falls to it.

## Hook configuration (Wizard canonical shape)

```json
{
  "hook": "BaseHook",
  "name": "PerkVaultHook",
  "pausable": false,
  "currencySettler": false,
  "safeCast": true,
  "transientStorage": true,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true,
    "afterInitialize": false,
    "beforeAddLiquidity": false,
    "beforeRemoveLiquidity": false,
    "afterAddLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": true,
    "afterSwap": true,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": true,
    "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "none",
  "info": { "license": "MIT" }
}
```

Address flags: `0x20CC` (8396) = `BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP |
BEFORE_SWAP_RETURN_DELTA | AFTER_SWAP_RETURN_DELTA`, the same five bits as #1330. The hook is written
directly against the v4-core interfaces (no `BaseHook`) and validates its own address bits in the
constructor. `access` is "none": the brief forbids an owner. `beforeInitialize` is the required
initialization callback and carries the binding. `beforeSwapReturnDelta` is needed because an
exact-input buy and an exact-output sell specify IMD and only the before-swap delta can touch the
specified side; it never no-ops a swap, the delta is always exactly the 1% fee. `afterSwap` with
`afterSwapReturnDelta` takes the fee on the unspecified side and settles every fee. No
remove-liquidity callbacks exist, so the factory's zero-liquidity fee collect always goes through.

Key sections of `src/PerkVaultHook.sol`:

- **Constructor** `(IPoolManager poolManager, address perk, address imd, address factory)`: stores
  four immutables, rejects zero addresses and `perk == imd`, validates the address bits. It calls
  no other contract.
- **`beforeInitialize`**: PoolManager-only; the binding rules above.
- **`beforeSwap` / `afterSwap`**: PoolManager-only; bound pool only; #1330's fee logic, then the
  split and the burn.
- **`simulateSwap`**: self-only, always reverts; the simulation `beforeSwap` relies on.
- **`redeemPendingFees` / `unlockCallback`**: permissionless redemption of deferred fees into the
  hook, followed by the burn; the callback accepts only the PoolManager.
- **`burn`, `tender`, `ask`**: the vault, permissionless, reentrancy-guarded.
- Unused callbacks revert with `HookNotImplemented` (and are never called: their bits are unset).

## Launch parameters and assumptions

Decided by the launch and used as given:

- Chain: Robinhood Chain, chain id 4663.
- Pair: IMD, `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` (18 decimals).
- LP fee 12500 (1.25%), tick spacing 60. The hook requires the fee and accepts any spacing.
- Supply 1,000,000,000 PERK minted to the factory; the factory splits it (10% distributor, 89%
  pool, 1% to the wallet that paid). No contract here is allocated any of it.
- Owner `0xbea91e555f85e6092aced53eae6aabf0668ea6a7`: not used. Neither contract has an owner or
  any admin argument, as the brief requires.
- Opening price: set by the deployer from the policy's opening market cap; not this project's.

Constructor arguments the manifest step fills for `PerkVaultHook`, in order:

| Argument | Value |
| --- | --- |
| `poolManager` | `$poolManager` (the chain's Uniswap v4 PoolManager; never hardcoded) |
| `perk` | `$token` (the PERK token the factory deploys just before the hook) |
| `imd` | `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` (IMD on Robinhood Chain) |
| `factory` | `$factory` (the launch factory, the only allowed pool initializer) |

`PerkToken` takes no constructor arguments.

Constants the brief fixes (all in `PerkVaultHook`): fee 1% (`FEE_BPS = 100`), pool fee 12500,
dead address, Intake `0xa43e6F75ee006411F79Ac1C84120606C2330DE82`, action
`oracle.request@oracle-1`, ask price 0.5 IMD, caller reward 0.1 IMD, minimum float 0.6 IMD, ask
interval 7 days, and `BODY`. Choices the brief left open: `totalAsked` counts answers bought (one
per ask); `Asked` also indexes the caller; the quote helpers `floatBalance`, `circulatingSupply`
and `quoteTender` are extra views.

Assumptions:

- IMD transfers move exactly the amount asked, with no fee on transfer. The live IMD is
  owner-controlled with a blocklist and a transfer switch. A blocked 0x…dEaD leaves the burn owed
  without stopping anything; a blocked hook defers fees as claims until unblocked; disabled
  transfers stop every swap in the pool, hook or no hook.
- The Intake pulls exactly the approved 0.5 IMD and does not refund. A refused body or a panel
  that does not agree spends the price with no answer; the vault asks again a week later.
- The hook is deployed by CREATE2 at an address carrying flags `0x20CC`; the factory mines the salt.

What the brief asked that the token does not do: nothing. The token is standard and fee-free; the
fee, burn, tender and ask all live in the hook.

## Operational responsibilities

- **Nobody administers the hook or the token.** There is no key to keep, rotate or hand to a
  multisig, and no parameter can change after deployment.
- **Permissionless keepers.** Anyone may call `redeemPendingFees()` when `pendingFloat() > 0`,
  `burn()` when `burnDue() > 0`, and `ask()` once a week when the float is at least 0.6 IMD (the
  caller earns 0.1 IMD). None is required for trading or tendering to work. While a fee is
  pending, its burn half (`deferredBurn`) waits for the redemption; redeeming is what sends it to
  0x…dEaD.
- **If the Intake moves or reprices**, `ask()` reverts (the live Intake refuses a wrong amount or an
  unknown action) and spends nothing; the float keeps accruing and tenders keep working. A new
  weekly report would need a new hook, which the launch does not provide for.
- **Reading the report.** No callback is registered. The answer is found on the oracle's records by
  the `requestId` in the `Asked` event.
- **Security.** Tests passing is not an audit. The hook holds the float (other people's claim on
  IMD) and should receive an independent adversarial review before release. The `beforeSwapReturnDelta`
  bit, the self-call simulation and the blocklisted-IMD paths are the places to look first.

## Tests

`forge build`, `forge test` and `forge fmt --check` pass with the pinned `solc = "0.8.26"`,
`evm_version = "cancun"` (transient storage) and `bytecode_hash = "none"`. The fuzz tests were run
with the verifier's seed. Tests read no environment variables and depend on no caller address.

- `test/PerkToken.t.sol`: metadata, supply minted once to the deployer, transfers, allowances, no
  mint or admin path, a transfer to 0x…dEaD is ordinary.
- `test/PerkVaultHook.t.sol`: permissions and address flags; callbacks refuse non-manager callers;
  no privileged functions; binding attacks (non-factory sender, fake token with IMD, pool without
  IMD or with ETH, wrong fee, zero fee, dynamic fee, second pool, re-initialization, tick spacing
  not hard-coded); exactly 1% of the IMD side in all four swap modes, fixed and fuzzed, with half
  burned and half kept; short fills; deferred fees on a PERK-only pool recorded once and redeemed
  once, flushed by the next swap, never double-counted; a deferred fee never spends the float on
  hand (book value, the tender quote, tenders and asks are unchanged until the claim is redeemed,
  then rise), also when a swapper forces the deferral by emptying the manager's IMD inside its own
  unlock (`test/mocks/ForcedDeferral.sol`), after a large buy whose fee exceeds the manager's IMD,
  and on a partial redemption; a fuzzed action sequence proving no swap, redeem, burn or donation
  ever lowers book value and `deferredBurn` never exceeds `burnOwed` or `pendingFloat`; half of
  every fee reaches 0x…dEaD once and only once over a mixed sequence (checked against the
  `FloatCollected` logs); first, last and
  dust tenders; zero-payout reverts; a fuzz that a tender never pays above pro rata and never lowers
  book value; donations only raise book value; ask pays the Intake 0.5 and the caller 0.1, sends the
  exact body, action and empty callback, leaves no allowance, reverts under 0.6 and inside 7 days,
  reverts cleanly when the Intake refuses; a fuzzed action sequence proving IMD leaves only by
  tender, burn and ask.
- `test/PerkVaultHookImdBehaviour.t.sol`: IMD refusing the burn (blocked 0x…dEaD) leaves it owed
  without reverting swaps, tenders or asks, and resumes once unblocked; IMD refusing the hook defers
  the fee as a claim; a reentering IMD cannot re-enter `tender` from a tender payout or an ask reward.

`test/utils/HookDeployer.sol` mines CREATE2 salts for the flags; `test/mocks/MockIntake.sol` is
etched at the live Intake's address and pulls exactly the price; `test/mocks/BlocklistERC20.sol`
holds the blocklisted and reentering IMD stand-ins.

## Dependencies

Vendored as ordinary files under `lib/` from launch #1330 (see each `VENDORED.md`): forge-std,
v4-core at `46c6834` (src, `CurrencySettler`, licenses) and solmate's `Owned.sol`. No submodules,
no network needed to build.
