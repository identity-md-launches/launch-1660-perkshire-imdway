import { readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { requireTool, web } from './toolchain.mjs';
import { assertRedirect } from './redirect.mjs';

const ts = requireTool('typescript');
const html = await readFile(join(web, 'index.html'), 'utf8');
assertRedirect(html);
const inline = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const config = ts.readConfigFile(join(web, 'tsconfig.json'), ts.sys.readFile);
if (config.error) throw new Error(ts.flattenDiagnosticMessageText(config.error.messageText, '\n'));
const parsed = ts.convertCompilerOptionsFromJson(config.config.compilerOptions, web);
// Check the actual inline browser code in memory; do not create another runtime file.
const options = { ...parsed.options, allowJs: true, checkJs: true, noEmit: true, types: [] };
const file = join(web, 'redirect-inline.js');
const host = ts.createCompilerHost(options);
const getSourceFile = host.getSourceFile.bind(host);
host.getSourceFile = (name, languageVersion, ...rest) => name === file
  ? ts.createSourceFile(name, inline, languageVersion, true, ts.ScriptKind.JS)
  : getSourceFile(name, languageVersion, ...rest);
const program = ts.createProgram([file], options, host);
const diagnostics = [...parsed.errors, ...ts.getPreEmitDiagnostics(program)];
if (diagnostics.length) {
  console.error(ts.formatDiagnosticsWithColorAndContext(diagnostics, {
    getCurrentDirectory: () => web, getCanonicalFileName: f => f, getNewLine: () => '\n'
  }));
  process.exit(1);
}
for (const name of await readdir(join(web, 'scripts'))) {
  if (name.endsWith('.mjs')) execFileSync(process.execPath, ['--check', join(web, 'scripts', name)]);
}
console.log('Typecheck passed: actual inline JavaScript checked with TypeScript strict/checkJs/noEmit; all Node scripts parse.');
