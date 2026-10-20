# Redirect validation

## Scope and assumptions

Reviewed the final `web/index.html`, production export and path fallback. The requested migration overrides the former dapp: no contract reads, wallet flow, trading controls, additional content, body images or authored styles belong on this site. Launch 1660 on chain 4663, Solidity sources, tests, libraries, launch manifest and protected dependency/configuration files are unchanged.

The only former exported HTML page was `index.html`; its old anchors and queries now enter the redirect. Identical `404.html` and a catch-all `_redirects` rule cover additional paths when supported by the static host. The HTML does not preserve old queries or fragments. The required favicon and sharing image use the actual destination site's existing PNG as head metadata only; it was fetched successfully and is not bundled.

## Actual commands and results

All commands below ran from the repository root. Tool installation, raw reports and screenshots are disposable scratch data, not part of the submission.

| Command/check | Actual result |
| --- | --- |
| `npm ci --prefix test/scratch/toolchain --cache test/scratch/npm-cache --no-audit --no-fund` after copying the existing manifest and lockfile | Passed; exact locked development dependencies installed without changing the originals. |
| `node web/scripts/build.mjs` | Passed; rebuilt only `dist/index.html`, identical `404.html` and `_redirects`. No app bundle, stylesheet or local image remains. |
| `node web/scripts/typecheck.mjs --toolchain test/scratch/toolchain` | Passed; actual inline JavaScript checked using TypeScript strict/checkJs/noEmit and the preserved compiler options; all Node scripts syntax-checked. |
| `PLAYWRIGHT_BROWSERS_PATH=test/scratch/browsers node web/scripts/check.mjs --toolchain test/scratch/toolchain --engine chromium` | Passed, 7 grouped checks. Chromium 141; all requested old-path navigation cases and useful primary interactions below passed. |
| Default interaction command requesting both engines | Chromium passed; command exited 1 when WebKit could not launch its runtime. No WebKit interaction, rendering or accessibility pass is claimed. |
| Browser-tool manual inspection | Actual export navigated to the exact supplied live destination with HTTP 200. Fallback viewed at 390 and 1440; 390 focus screenshot viewed; zero console errors reported for the inspected navigation. |
| Protected-file and packaging audit | Recorded in `web/validation.json`; preserved files match the initial task-file hashes, and the submission-size check stays below 8 MiB. No ignore file, dependency manifest, lockfile or submodule was changed. |

The interaction harness uses its own bounded local preview and closes it. External destination requests are intercepted with an explicit navigation fixture; no test depends on wallet, RPC or oracle availability. Fallback checks suppress only meta refresh and the inline script in a test response, leaving the visible document unchanged. The manually followed destination was not intercepted.

The seven groups cover export/source equality and minimal contents; immediate `location.replace` execution; fallback HTTP responses; actual unmodified HTML navigation; JavaScript-disabled meta refresh; script-only navigation/history replacement; and fallback keyboard, responsive and accessibility behavior. Tested old routes include root, `index.html`, query plus `#weekly`, `#tender`, `#accounts`, `#letter`, `accounts.html`, `tender/`, a nested old HTML path, `style.css` and `assets/app.js`. Unknown paths receive the redirect HTML with 404 status in preview. The script-only Back test returns to the preceding page rather than revisiting the redirect.

Fallback checks: exactly one body element/link and no other text; correct href; no stylesheet, inline style, image or script; visible action and no horizontal overflow at 320/390/768/1440; 200% text enlargement at 320; Tab focus with a visible native outline and Enter navigation. Five applicable axe rules (`color-contrast`, `link-name`, `html-has-lang`, `document-title`, `meta-viewport`) reported zero violations. This scoped scan is not a full accessibility certification.

## Pinned design probe

Ran the original pinned script against the real production export:

```sh
IMD_PLAYWRIGHT="$PWD/test/scratch/toolchain/node_modules/playwright/index.mjs" PLAYWRIGHT_BROWSERS_PATH=test/scratch/browsers node .imd/reads/skills/design-critic/scripts/taste.mjs --out test/scratch/taste --offline
```

Exit 0, **14/16 reported passes**, but this is not a useful visual pass: the intended external navigation is blocked offline, leaving no original page to measure. `render` reports “page renders nothing”; `share` sees no original metadata. These observations follow the requested immediate navigation. Changing the page to linger would violate the brief.

For a meaningful fallback review, copied the final HTML to `test/scratch/fallback/index.html` and removed only the refresh meta and inline script. Then ran:

```sh
IMD_PLAYWRIGHT="$PWD/test/scratch/toolchain/node_modules/playwright/index.mjs" PLAYWRIGHT_BROWSERS_PATH=test/scratch/browsers node .imd/reads/skills/design-critic/scripts/taste.mjs test/scratch/fallback --out test/scratch/taste-fallback --offline
```

Exit 0, **16/16 passed for that identified fixture**. Screenshots were reviewed separately. The probe measured the lone native link at approximately 257×17px, without a crowded neighbor, and 9.4:1 contrast. It reported the sub-44px comfortable target size; the requested plain native link is retained. No custom button or extra styles were added to satisfy a generic design preference.

## Better Interface coverage

| Domain | Coverage and evidence | Limits / not applicable |
| --- | --- | --- |
| Accessibility | Checked: native link/name, English language, unrestricted viewport, keyboard Tab/Enter, viewed native focus outline, five applicable axe rules, enlarged text. | Screen-reader session, physical device, native 200% browser zoom and WebKit unperformed. Forms, dialogs, live regions and non-native controls absent. |
| Layout | Checked: sole action on first screen at 390; no horizontal scroll at 320/390/768/1440; default normal-flow layout and 200% text reflow. | No breakpoint, RTL locale, sticky area or multi-column layout exists; native zoom unperformed. |
| Writing | Checked: one descriptive verb-first link names Perkshire IMDway (PERK); href and both redirects match exactly. | Marketing hero, copy hierarchy, errors and form instructions absent by request. |
| Typography | Checked: no authored type system or font loading; observed one 16px/400 default face; no clipping or truncation in tested widths. | Browser defaults vary; mixed-direction text and native zoom unperformed. |
| Colors | Checked: no authored palette; native link underline; fixture probe measured the rendered link/white pair at 9.4:1. | No dark theme, forced-colors session or visited-link contrast measurement claimed. |
| UI | Checked: one native anchor with native focus/activation; zero body images, decorations, overlays, styles or animations. | Motion, surfaces, icon families, custom states and animation timing not applicable. |

## Findings and fixes

| Finding | Final source location | Fix and recheck |
| --- | --- | --- |
| High / task behavior: former table, wallet app and site content would remain visible. | `web/index.html:5`, `web/index.html:6`, `web/index.html:15` | Replaced all visible content with one link and both immediate head redirects. Removed former frontend code/assets and old validation screenshots. Minimal-DOM assertions, real export navigation and viewed fallback screenshots confirm the replacement. |
| High / old-path recovery: a plain missing-file response cannot perform the requested migration. | `web/scripts/build.mjs:13`, `web/scripts/build.mjs:15`, `web/scripts/preview.mjs:12` | Build identical 404 document plus catch-all rule; preview unknown paths returns that HTML. Chromium follows both normal and JavaScript-disabled old-path fallback to the exact destination. Production host policy remains a deployment limitation. |
| Probe applicability: redirect leaves no original document for generic render/share checks. | `web/index.html:5` and `web/index.html:6` | Preserved required immediate navigation; separately reviewed the explicitly identified fallback fixture, with 16/16 results. Did not relabel the actual export's 14/16 as a pass. |

## Completion and remaining limits

Complete for the requested redirect implementation, production build, typecheck and available browser checks, with these disclosed limits: WebKit checks unperformed; no screen-reader/native-device/native-zoom or social-crawler testing; metadata image availability is external; the real post-publication static host's unknown-path handling is not verified. A host must honor `_redirects` or the supplied `404.html`, or map old paths to `index.html` itself. Publishing is after review and was not performed. Existing Solidity tests were not rerun because the contract source and configuration are unchanged. Worker observations are not independent behavior certification.

Evidence in disposable scratch: `redirect-results.json`, `redirect-shots/chromium-390.png`, `redirect-shots/chromium-1440.png`, `redirect-shots/chromium-focus-390.png`, `manual-mobile-390.png`, `manual-focus-390.png`, `manual-desktop-1440.png`, `taste/taste.json`, and `taste-fallback/taste.json` with its screenshots. These are not runtime assets or submission files.
