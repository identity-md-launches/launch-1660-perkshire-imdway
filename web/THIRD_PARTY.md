# Sources and notices

The redirect document has no bundled third-party code, local imagery, fonts or styles. Its favicon and `og:image` reference the new PERK site's existing `assets/investor-pepe.png`; the image is not copied into the export or shown in its body.

The protected existing package manifest and lockfile are retained. Their wallet libraries are unused by the redirect. TypeScript, Playwright and axe are development checks only and are not included in `dist/`.

Design guidance: Jakub Krehel's [Better Interface](https://github.com/jakubkrehel/skills/tree/267330e1adfc66a718fb65fa6918c1f06d0a689e/skills/better-interface), commit `267330e1adfc66a718fb65fa6918c1f06d0a689e` (MIT). Documentation guidance: Paul Bakaus's [Impeccable](https://github.com/pbakaus/impeccable/blob/9d715cc4f5564a990ca8345abfdd5df6dc9b41c8/skill/reference/document.md), commit `9d715cc4f5564a990ca8345abfdd5df6dc9b41c8` (Apache-2.0). Existing attribution and complete licenses remain in `licenses/interface-guidance.txt`.
