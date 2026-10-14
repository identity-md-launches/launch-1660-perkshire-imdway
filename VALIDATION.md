# Website validation

Complete for the stated repository scope. This is the worker's own evidence, not independent certification of the site or contracts. Static hosting/pinning is the publisher's handoff step; no public site URL, deployment or live transaction is claimed.

## Scope and assumptions

One light-only HTML page for **perkshire**, using the live launch-1660 PERK and PerkVaultHook on Robinhood Chain 4663. Contract source, existing build settings and dependencies were preserved. The requested 1995 appearance takes precedence over modern card/hero styling and the wallet reference's React example: native DOM/EIP-1193/EIP-6963 implement its connection paths instead. The only UI supplied by a dependency is the optional Coinbase SDK's own connection flow.

Financial readings have no seed values or cached examples in the production app. Exact onchain amounts and fixed contract constants are read together at a block; pool-derived price and ratio use BigInt arithmetic. Fictional management, the given banner, launch number and creator disclosures are static brief content. Test balances/accounts exist only in the isolated browser harness and never enter `dist/`.

## Actual checks

| Check | Result | Evidence |
| --- | --- | --- |
| Production export | Passed | `PERK_TOOLCHAIN=/tmp/perkshire-toolchain node web/scripts/build.mjs`; `web/validation/build.json` |
| Strict typecheck | Passed | `PERK_TOOLCHAIN=/tmp/perkshire-toolchain node web/scripts/typecheck.mjs`; TypeScript 5.9.3, `strict`, `noUncheckedIndexedAccess`, `noEmit` |
| ABI derivation | Passed | `forge build --out test/scratch/foundry-out --cache-path test/scratch/foundry-cache`; successful Solc 0.8.26 compile, with existing contract/test lint warnings |
| ABI and runtime verification | Passed | `PERK_TOOLCHAIN=/tmp/perkshire-toolchain node web/scripts/verify-contracts.mjs`; both canonical ABI Keccak hashes match; deployed runtime matches compiled source except constructor immutables; exact browser code hashes match live code |
| Interaction validation | Passed, 26 grouped checks | Chromium 141 and WebKit 26; `web/validation/interactions.json`, executable harness `web/scripts/check.mjs` |
| Automated accessibility | Passed for scanned page | axe: 45 passed rules, zero violations in each browser; not a full accessibility certification |
| Pinned taste@1 probe | Passed, 16/16 | `PLAYWRIGHT_BROWSERS_PATH=/tmp/perkshire-browsers IMD_PLAYWRIGHT=/tmp/perkshire-toolchain/node_modules/playwright/index.mjs node .imd/reads/skills/design-critic/scripts/taste.mjs --out test/scratch/taste`; retained check results in `web/validation/taste.json` |
| Live browser reading | Passed | Actual `dist/` served under `/preview/`; read block **87,998,517**, 2026-10-14 02:08:36 UTC; zero book value shown as “Undefined,” spot price `0.000002499999999999 IMD`, no prior report; no page errors/warnings on the clean final navigation |
| Coinbase entry | Passed through onboarding/cancel | Real SDK 4.4.0 opened `keys.coinbase.com` onboarding; no sign-in or passkey created. Closing the local chooser releases an unresolved request and permits retry |
| Packaging | Passed | `web/validation/packaging.json`; uncompressed submission file payload below 8 MiB with source, lockfile, export, runtime assets and documentation; no added dependency/cache folders or submodules |

The interaction command used on this restricted worker was:

```sh
PERK_TOOLCHAIN=/tmp/perkshire-toolchain \
PLAYWRIGHT_BROWSERS_PATH=/tmp/perkshire-browsers \
PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1 \
LD_LIBRARY_PATH=/tmp/perkshire-webkit-libs/usr/lib/x86_64-linux-gnu \
__EGL_VENDOR_LIBRARY_DIRS=/tmp/perkshire-webkit-libs/usr/share/glvnd/egl_vendor.d \
LIBGL_DRIVERS_PATH=/tmp/perkshire-webkit-libs/usr/lib/x86_64-linux-gnu/dri \
node web/scripts/check.mjs
```

Playwright and browser binaries were installed outside the repository. Missing WebKit OS libraries were downloaded and extracted under `/tmp`; its temporary launcher was adjusted to preserve that library search path. The dependency preflight was bypassed only after providing the actual runtime libraries; WebKit itself successfully rendered and exercised the entire suite. No browser libraries or downloads are part of the submission. On a normally provisioned machine the README's simpler command applies.

The browser harness serves the production export at `/preview/`. It intercepts all external traffic for signing scenarios, uses an EIP-1193 test provider, and checks exact transaction destination, chain, value and calldata. It covers:

- Exact-amount approval, full-precision tender input, onchain quote, simulation, gas review, changed-quote reconfirmation, receipt and actual payout display.
- Redeem, burn and ask; the float/oracle/caller cost split; zero float/book value; no-op burns; oracle repricing; first ask and the exact seven-day boundary using block time.
- Wrong network, unknown-network add/switch, account changes, cancellation, signature rejection/retry and abandoned wallet requests whose late responses must be ignored.
- Invalid, dust, oversized and insufficient-balance amounts; bad bytecode, partial price failure, RPC outage and recovery; persisted pending hashes without rebroadcast; failed receipts, status retry, and explicit tracking recovery.
- Exact `Asked` → Intake entry → oracle UUID association; unrelated answers rejected; report pending and answered states. Intake IDs are never compared directly with oracle UUIDs.
- Mobile deep links for all three wallets and the Coinbase Smart Wallet entry; native modal Escape/focus return; 200% text enlargement; 320/390/610/768/1440px reflow.

## Better Interface review

The pinned workflow, six domains' core principles, and final-design documentation method were read and applied while building. The visual idea is a frog chairman's plain HTML accounts ledger, with the books and tender action ahead of the letter.

| Domain | Coverage | Result and limits |
| --- | --- | --- |
| Accessibility | Checked | Native buttons/links/form labels/table headers/dialogs; skip link, live statuses, keyboard open/dismiss/focus return, visible focus screenshot, axe in both engines. No manual screen-reader session or native-device testing |
| Layout | Checked | Actual export and screenshots; 320, 390, 610, 768, 1440px, long values and 200% text size. No horizontal overflow. Product, connect and tender buttons on first 390×844 screen. Native browser zoom and RTL mirror unperformed; English/LTR is the supported content |
| Writing | Checked | Action names, free versus gas costs, exact spending in the review, zero/stale/error states, permanent PERK burn and unprotected quote warning. Requested banner and risk disclosures retained. No fabricated live counters or answers |
| Typography | Checked | Two system font stacks, two weights, six declared size tokens; four computed sizes at 390 and five including one-offs at 1440. Full amounts/addresses wrap; 16px inputs. No downloaded fonts; OS font rasterization can vary |
| Colors | Checked | Light-only semantic tokens and real rendered solid-background text pairs; probe contrast pass. Ink/paper 15.01:1, muted/paper 7.26:1, link/paper 13.79:1, paper/green 9.78:1. Forced-colors support reviewed in CSS but not tested in a native high-contrast session; dark mode is intentionally absent |
| UI details | Checked | Rest/hover/pressed/focus/disabled states, wallet pending/rejection/retry, financial loading/empty/error/success, native dialog behavior and real phone-width sheet screenshots. No animation, shadows, gradients, cards or theme transitions; motion replay is not applicable |

The probe reports zero prose words because it treats the table's contents as data. That is a limitation of this probe, not a claim that the page contains no prose. The copy and first screen were also inspected manually. Its six controls below the comfortable 44px size are spaced text links; transaction buttons are at least 44px, wallet rows at least 48px. No applicable first-screen or repeated visual failures remain.

## Findings and fixes

| Severity/domain | Source location | Finding, correction and recheck |
| --- | --- | --- |
| High / data integrity | `web/src/chain.ts:186` | Matching a hook Intake ID to an oracle UUID would miss the real report or invite an unrelated same-question answer. Follow the public Intake record for the exact onchain transaction and payer, then validate oracle ID/question/chain/type. Both engines verify a matched answer and reject an unrelated answer |
| High / writing and state | `web/src/app.ts:233`, `web/src/app.ts:294` | A queued dialog `close` event could replace a successful transaction status with “Review cancelled.” Give signing/error/cancel closures distinct return values. Confirmed receipts for all five actions now retain their real result in both engines |
| Medium / accessibility | `web/src/wallet.ts:148` | WebKit did not reliably return focus to Connect after dismissal. Add explicit close-event focus restoration; keyboard dismissal and focus now pass in both engines; visible ring inspected in the WebKit wallet screenshot |
| Medium / recoverability | `web/src/wallet.ts:56`, `web/src/wallet.ts:148` | The real Coinbase popup could leave an unresolved connection when dismissed. Closing the local chooser now abandons that generation, releases its provider and enables retry; a late result cannot replace the next connection. Rechecked with real Coinbase onboarding and isolated tests in both engines |
| Medium / colors | `web/style.css:7`, `web/style.css:29` | Soft table dividers were also being used as control boundaries. Retain soft structural lines but add the darker `--control-border` for controls. Inspected final screenshots and reran the text/contrast probe |
| Medium / writing | `web/src/app.ts:93` | A failed initial RPC read left the weekly-cost label saying it was still reading. Show cost unavailable and explain how to retry; outage/recovery assertions pass in both engines |
| Medium / chain reading | `web/src/chain.ts:175` | Looking only a few blocks around a timestamp could miss an L2 event when many blocks share one second. Binary-search the complete timestamp interval and select its latest Asked event; request matching tests pass |
| Medium / recoverability | `web/src/app.ts:281`, `web/index.html` tracking dialog | A lost/replaced receipt could leave locally persisted tracking indefinitely blocking actions. Expose an explicit local-clear review after a long wait/read failure, state that it does not cancel the transaction, and preserve its explorer link. Receipt retry and warning checked in both engines |

During test development, an overly narrow mock URL route failed to intercept an oracle request. The final harness uses `**/*`, explicitly passes only the local preview origin, and stubs/blocks every external request. Final isolated results contain no dependency on live oracle traffic. Initial missing browser-library and npm-cache write failures were resolved locally; they are not unresolved limitations.

## Deliverables and remaining limits

`dist/index.html` and all local runtime assets are present alongside `web/` source and its exact package lock. The export has a title, description, both favicon formats, `og:title`, `og:description` and a local `og:image`. Original SVG and 512px PNG are also at the repository root. `DESIGN.md` documents the final source; the README documents install, rebuild, preview and checks.

The package audit measures the complete tracked-plus-untracked, nonignored file payload before publisher bundling. It is a conservative source/export size check, not a claim to have produced the publisher’s final Git bundle.

Evidence images: `web/validation/mobile-390.png` and `web/validation/desktop-1440.png` are live-data production screenshots. `web/validation/wallet-mobile-webkit.png` shows the isolated mobile wallet fixture, not live balances. Additional probe screenshots remain in disposable `test/scratch/taste/shots/`.

- No funded wallet or real signature was used, and no onchain transaction was submitted. Wallet signing/receipts were validated using explicit mocks. Coinbase onboarding loaded, but passkey creation and chain-4663 signing with a real Coinbase account remain unverified. Physical mobile app handoff also remains unverified.
- The live hook had never asked a question during inspection. The answer path is schema-checked against the public service documentation and exercised with isolated records; a real completed Chairman's report could not be observed yet. Report signatures are not independently verified in the browser; the UI labels the result oracle-reported.
- Public RPC, oracle, wallet and Uniswap availability is external. Connection and retry controls remain available on failures. There is no vendored service, proxy, private key, backend or fake offline financial data.
- A tender's execution price can change after the last simulation. This immutable contract has no min-payout/deadline argument. The page discloses that before signing and does not pretend it can guarantee the quote.
- Hosting and the final public name happen after this static-export handoff. Nothing here redeploys, remints, upgrades or otherwise modifies the contracts.
