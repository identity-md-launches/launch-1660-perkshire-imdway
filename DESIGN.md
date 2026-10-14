# Perkshire design

## Overview

Perkshire is a holder's ledger and tender form for a value-investing parody. The explicit direction is “plain 1995 HTML, light only, no frameworks.” The implementation uses a single bordered HTML table, browser-native controls, underlined blue links, system serif text and an original frog illustration. There are no cards, gradients, webfonts, dark theme, decorative motion or hero that separates the product from its controls.

The leading rows show the product, free wallet connection, requested banner, price-to-book and the tender form. Live accounts, the weekly report, company particulars, the letter and the disclosures follow in that order. The entire page exists as static HTML; the script adds readings and wallet behavior. Source: `web/index.html`, `web/style.css`, `web/src/`.

## Colors

All colors use CSS custom properties in `web/style.css:1`.

| Token | Value | Use |
| --- | --- | --- |
| `--paper` | `#fffef9` | Page, input and dialog background; primary-button text |
| `--ink` | `#202820` | Main text and dialog frame |
| `--muted` | `#52584e` | Supporting and disabled text |
| `--rule` | `#9b9e8e` | Noninteractive table rules |
| `--control-border` | `#72776a` | Visible control boundaries |
| `--section` | `#eeeee5` | Section-heading rows and disabled controls |
| `--button` | `#e8e8df` | Native-style control fill |
| `--hover` | `#dcded2` | Hover/pressed fill |
| `--link` | `#0000a0` | Underlined links and keyboard focus |
| `--visited` | `#551a8b` | Visited links |
| `--green` | `#244b32` | Available tender and confirmation buttons |
| `--error` | `#8a241e` | Inline errors, accompanied by explanatory text |

Measured against the rendered paper color: ink 15.01:1, muted 7.26:1 and link/focus 13.79:1. Paper text on the green button is 9.78:1. The softer table rule is structural; controls have their own darker boundary token. These measurements and the probe's text-contrast pass are limited to the inspected states, not a claim of full WCAG conformance.

## Typography

- Prose, headings and controls: `"Times New Roman", Times, serif`; numbers and full addresses: `"Courier New", Courier, monospace`. No font downloads.
- Six declared steps: `--small` 14px, `--body` 16px, `--subhead` 20px, `--heading` 28px, `--title` 32px, `--figure` 36px, at the normal 16px root. Weights are 400 and 700; the banner and sign-off use native italic.
- Body line-height is 1.5; title and price-to-book use 1.1, section headings 1.3. Natural letter-spacing throughout.
- The mobile title/ratio are 28px; the desktop title is 32px and ratio 36px. The final probe found four sizes at 390 and five including single-use sizes at 1440.
- The letter is capped at `70ch`. Live numbers use tabular numerals. Critical amounts and addresses wrap instead of being clipped, shortened or hidden; the connected-wallet button's short address has a full address in its dialog.
- Inputs remain 16px or larger. User zoom is not restricted. 200% text enlargement was exercised in both engines; native browser zoom and screen-reader pronunciation were not tested.

## Layout

`main` is at most `58rem` (928px), centered with `2rem` vertical margin and `1rem` inline padding. The ledger collapses its borders and uses fixed-layout columns at 38%/62%. Regular cells have 14px vertical and 16px horizontal padding. Common small gaps are 4, 6, 8 and 12px; section and reading spaces are 16–32px.

At `max-width: 38rem` (608px), the page margin/padding becomes 12px, cell padding 12px, columns 42%/58%, the logo 72px, the amount label/input stack, and transaction buttons each use the available row width. The header and section controls wrap naturally. At larger widths the logo is 96px and amount/transaction controls can sit alongside each other. Nothing is fixed over the document.

Both engines were checked at 320, 390, 610, 768 and 1440px with no horizontal overflow. At 390×844 the connect control and complete tender action are on the first screen; the tender button's bottom is approximately 714px. The monetary-risk note stays next to that control. Full addresses remain available at narrow widths.

## Elevation and shapes

The ledger is flat: one 1px frame and row rules, no shadow. Section-heading rows use a quiet fill. Buttons have square native-style 2px outset borders, inset when pressed. Inputs have a square 1px border (2px when invalid). Dialogs use a 2px ink frame and a translucent `rgb(32 40 32 / .4)` backdrop, without a shadow.

The only circle is the logo crop. `logo.svg` is an original 512×512 flat-color drawing; `logo-512.png` is generated from it. The glasses, face, suit, financial pages and desk sit inside a circle-safe composition. The same local assets provide the identity, favicon and share image.

## Components and states

| Pattern | Source | Behavior |
| --- | --- | --- |
| Ledger row / section row | `web/index.html`, `.ledger`, `.section-heading` | Native table semantics; units alongside values; loading/unavailable are words, never fake zeros |
| Valuation | `.valuation`, `#price-to-book` | Prominent ratio; “Undefined” at zero book value; unavailable on a failed price read |
| Amount/quote form | `#tender-form`, `web/src/app.ts:107` | Explicit label, decimal keyboard, exact BigInt parsing, latest-only quote results, inline errors and balance/allowance |
| Action buttons | `button`, `.primary`, `.actions`, `.row-action` | 44px minimum height; neutral/green/rest/hover/pressed/focus/disabled states; unavailable actions explain their requirements in text |
| Wallet chooser | `web/src/wallet.ts`, `#wallet-dialog`, `.wallet-row` | Native modal; 48px named wallet rows and vendor marks; mobile wallet-browser links; bottom placement below 608px; Escape/backdrop/close button; explicit focus return; abandoned requests can retry |
| Transaction review | `web/src/app.ts:201`, `#review-dialog` | Exact consequences, address, gas budget and cost before signing; cancel; repeat review if the simulated tender payout changes |
| Transaction status | `#transaction-status`, `#transaction-link`, `#check-receipt` | Polite status region, explorer link, receipt retry; no automatic rebroadcast; local pending tracking survives reload |
| Tracking recovery | `#tracking-dialog` | Explicit warning that clearing a local record does not cancel a transaction |
| Weekly report | `#weekly`, `web/src/chain.ts:159` | Chain-clock eligibility and live oracle price; empty/pending/failed/answered states; exact onchain request linkage |

Use actual links for navigation and buttons for actions. Keyboard focus has a 2px blue perimeter with a 3px offset; forced-colors mode uses the system Highlight color. Hover styling is gated to hover-capable pointers. There is no animation to disable for reduced motion. No icon-only financial actions are used.

## Reuse rules

Use the ledger and its existing section row for another account or explanatory section. Keep the original serif voice and six-step type scale. A new financial value needs a real read, an explicit unit and a loading/error state. Keep expensive or irreversible consequences beside their action, before the wallet opens. Reuse native inputs and dialogs rather than adding a component framework. Keep full monetary values and addresses selectable and wrapping. Preserve the light page, one table and original logo; a new decorative card system, font, theme or animation would conflict with this site's direction.

Guidance attribution and full notices: `web/THIRD_PARTY.md` and `web/licenses/interface-guidance.txt`.
