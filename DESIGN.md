# PERK redirect design

## Overview

The `perk` site sends visitors to the creator's supplied new PERK website. `web/index.html` is the single source; `dist/index.html` and `dist/404.html` are identical build outputs. The entire visible interface, when automatic navigation is blocked, is one native link: “Continue to Perkshire IMDway (PERK)”. The brief's “No other text, images or styles” controls the visible page.

## Colors and tokens

There are no authored color tokens, custom properties, stylesheets or inline styles. Colors come from browser and visitor preferences. In the inspected Chromium fallback, the unvisited link was `rgb(0, 0, 238)` on a white canvas; the probe measured contrast at 9.4:1. This is an observation, not a palette enforced by the source. The underline communicates the action independently of color.

The required favicon and sharing image appear only in head metadata (`web/index.html:11` and `:12`) and reference the new site's existing image. There are no body images or local asset files. No theme, status palette, gradients or decorations are implemented.

## Typography

There is no font dependency or authored type scale. The native anchor inherits the browser's default text styling; Chromium measured one 16px, weight-400 Times New Roman style with normal tracking. User settings may change it. Text remains selectable, naturally wraps, and is never truncated. The document declares English and allows browser zoom (`web/index.html:2` and `:7`).

## Layout and responsive behavior

The anchor is the body's only element, in normal document flow (`web/index.html:15`). There is no grid, fixed sizing, positioning, hero, breakpoint, spacing token or container component. Chromium's default body inset measured 8px. The product name and fallback action are at the first screen's leading edge.

Checks at 320, 390, 768 and 1440 CSS pixels found no horizontal overflow or clipped action. Increasing the link text to 200% at 320px in the test page reflowed without horizontal scrolling. Native browser zoom, other locales and native-device behavior were not tested; no alternative layout or localization is claimed.

## Elevation, depth and shapes

The page has no surfaces, borders, shadows, radii, clipping or overlays. The native link's focus outline is preserved. There are no animated states or reduced-motion-specific rules because no animation exists.

## Components and behavior

| Pattern | Source | Behavior |
| --- | --- | --- |
| Immediate navigation | `web/index.html:5` and `:6` | Meta refresh uses delay 0. Synchronous `location.replace` executes in the head, before the body. Both use the exact supplied root URL without forwarding old query/fragment values. |
| Fallback navigation | `web/index.html:15` | Native anchor, default underline, same-tab navigation and browser context-menu support. Tab focuses it; Enter follows it. The native focus outline was viewed at 390px. |
| Static path fallback | `web/scripts/build.mjs:13` | Builds an identical `404.html`; `_redirects` adds the host-supported catch-all rule. These are aliases/routing support for the same document, not more content pages. |

There are no forms, dialogs, loading indicators, wallet controls, application errors or transaction states. If automatic redirects are disabled, the anchor is the entire recovery path. Failures at the destination are handled by the browser and the destination itself.

## Reuse rules

- Keep one canonical HTML source and regenerate the export with `node web/scripts/build.mjs`.
- Keep the redirect directives in the head and the body limited to the one descriptive anchor.
- Reuse the same generated document for old routes. Do not restore the former app, CSS, wallet SDK bundles or imagery.
- Update both redirect directives, the link, the build rule and checks together if the requester changes the destination.

Design guidance: Jakub Krehel's Better Interface, commit `267330e1adfc66a718fb65fa6918c1f06d0a689e` (MIT). Documentation method: Paul Bakaus's Impeccable, commit `9d715cc4f5564a990ca8345abfdd5df6dc9b41c8` (Apache-2.0). Existing full notices remain in `web/licenses/interface-guidance.txt`.
