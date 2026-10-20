import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const web = fileURLToPath(new URL('../', import.meta.url));
export const root = resolve(web, '..');
const flag = process.argv.indexOf('--toolchain');
if (flag !== -1 && !process.argv[flag + 1]) throw new Error('--toolchain needs a directory');
export const requireTool = createRequire(resolve(flag === -1 ? web : process.argv[flag + 1], 'package.json'));
