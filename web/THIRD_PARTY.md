# Sources and notices

The page is plain HTML/CSS and browser TypeScript. It uses no UI framework. Its normal app code is bundled by esbuild; the Coinbase Wallet SDK is loaded only when that wallet is chosen (or a previously selected Coinbase connection is restored). The SDK's own dependencies do not turn the page into a framework application.

- Coinbase Wallet SDK, MIT: `assets/licenses/coinbase-wallet-sdk.txt`.
- Noble hashes, MIT: `assets/licenses/noble-hashes.txt`.
- MetaMask and Phantom marks copied from RainbowKit's official wallet connector assets; Coinbase mark from the pinned wallet reference. RainbowKit MIT notice: `assets/licenses/rainbowkit.txt`. Names and marks belong to their respective owners.
- Additional bundled-library copyright notices are retained in the export's linked `.LEGAL.txt` files; full dependency licenses are collected into `dist/assets/licenses/bundled-dependencies.txt` during the build.
- Original Warren Peppett vector illustration: `../logo.svg`, authored for this assignment; `../logo-512.png` is its reproducible raster export.

Design guidance was adapted from Jakub Krehel's [Better Interface](https://github.com/jakubkrehel/skills/tree/267330e1adfc66a718fb65fa6918c1f06d0a689e/skills/better-interface), commit `267330e1adfc66a718fb65fa6918c1f06d0a689e`, MIT. Design-documentation guidance was adapted from Paul Bakaus's [Impeccable](https://github.com/pbakaus/impeccable/blob/9d715cc4f5564a990ca8345abfdd5df6dc9b41c8/skill/reference/document.md), commit `9d715cc4f5564a990ca8345abfdd5df6dc9b41c8`, Apache-2.0. Both complete license texts and copyright attribution are retained in `licenses/interface-guidance.txt`.

The published [IMD Intake API documentation](https://imd.fun/docs#intake) establishes that Intake request IDs differ from oracle UUIDs, and documents `GET /intake/:chainId/:transactionHash`. The report reader uses that mapping before reading `/oracle/requests/:id`. The [Uniswap pool data guide](https://developers.uniswap.org/docs/sdks/v4/guides/pool-data) documents StateView and the Q64.96 spot-price source. Addresses, network parameters and ABIs originate from the pinned deployment inputs and local Solidity, not those documentation examples.
