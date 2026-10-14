import { join, dirname } from 'node:path';
import { requireTool, web } from './toolchain.mjs';
const ts = requireTool('typescript');
const file = ts.readConfigFile(join(web, 'tsconfig.json'), ts.sys.readFile);
const config = ts.parseJsonConfigFileContent(file.config, ts.sys, web);
// Supports a temporary external toolchain without a node_modules directory in the repository.
config.options.baseUrl = web;
config.options.paths = {
  '@coinbase/wallet-sdk': [join(dirname(requireTool.resolve('@coinbase/wallet-sdk/package.json')), 'dist/index.d.ts')],
  '@noble/hashes/*': [join(dirname(requireTool.resolve('@noble/hashes/sha3.js')), '*')]
};
const program = ts.createProgram(config.fileNames, config.options);
const diagnostics = [...config.errors, ...ts.getPreEmitDiagnostics(program)];
if (diagnostics.length) {
  console.error(ts.formatDiagnosticsWithColorAndContext(diagnostics, { getCurrentDirectory: () => web, getCanonicalFileName: f => f, getNewLine: () => '\n' }));
  process.exit(1);
}
console.log('Typecheck passed (TypeScript strict, noEmit).');
