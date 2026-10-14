import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
export const web = fileURLToPath(new URL('../', import.meta.url));
export const root = resolve(web, '..');
export const requireTool = createRequire(process.env.PERK_TOOLCHAIN
  ? resolve(process.env.PERK_TOOLCHAIN, 'package.json') : resolve(web, 'package.json'));
