import assert from 'node:assert/strict';
import { readFile, readdir, mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { runInNewContext } from 'node:vm';
import { preview } from './preview.mjs';
import { requireTool, root, web } from './toolchain.mjs';
import { assertRedirect, destination } from './redirect.mjs';

const html = await readFile(join(web, 'index.html'), 'utf8');
assertRedirect(html);
assert.equal(await readFile(join(root, 'dist/index.html'), 'utf8'), html);
assert.equal(await readFile(join(root, 'dist/404.html'), 'utf8'), html);
assert.equal(await readFile(join(root, 'dist/_redirects'), 'utf8'), `/* ${destination} 301\n`);
assert.deepEqual((await readdir(join(root, 'dist'))).sort(), ['404.html', '_redirects', 'index.html']);
const results = [];
const record = name => { results.push(name); console.log(`PASS ${name}`); };
record('Minimal page, exact export copies, catch-all rule, no obsolete runtime assets');
let replacement;
runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], { location: { replace: url => { replacement = url; } } });
assert.equal(replacement, destination);
record('Inline script calls location.replace immediately with the exact destination');

const { chromium, webkit } = requireTool('playwright');
const engineFlag = process.argv.indexOf('--engine');
const selected = engineFlag === -1 ? 'both' : process.argv[engineFlag + 1];
assert.ok(['both', 'chromium', 'webkit'].includes(selected), '--engine must be both, chromium or webkit');
const { default: AxeBuilder } = requireTool('@axe-core/playwright');
const { server, url } = await preview();
const origin = new URL(url).origin;
const shots = join(root, 'test/scratch/redirect-shots');
await mkdir(shots, { recursive: true });
const routes = ['index.html', '?old=1#weekly', '#tender', '#accounts', '#letter', 'accounts.html', 'tender/', 'nested/weekly.html', 'style.css', 'assets/app.js'];
try {
  for (const path of routes) {
    const response = await fetch(url + path);
    assert.equal(response.status, /^(index\.html|\?|#)/.test(path) ? 200 : 404);
    assertRedirect(await response.text());
  }
  record('Preview serves the redirect for root, old anchors, queries, nested paths and removed assets');
  for (const [name, engine] of [['Chromium', chromium], ['WebKit', webkit]]) {
    if (selected !== 'both' && selected !== name.toLowerCase()) continue;
    const browser = await engine.launch({ headless: true });
    try {
      async function scenario(mode, task, javaScriptEnabled = true) {
        const context = await browser.newContext({ viewport: { width: 390, height: 844 }, javaScriptEnabled });
        const page = await context.newPage();
        page.setDefaultTimeout(10000);
        const errors = [], reached = [];
        page.on('pageerror', error => errors.push(error.message));
        await context.route('**/*', async route => {
          const request = route.request(), requestUrl = request.url();
          if (requestUrl === destination) {
            reached.push(requestUrl);
            return route.fulfill({ contentType: 'text/html', body: '<!doctype html><title>Isolated redirect destination</title>' });
          }
          if (new URL(requestUrl).origin !== origin) {
            assert.equal(requestUrl, destination + 'assets/investor-pepe.png', 'Unexpected external request');
            return route.fulfill({ status: 204, body: '' });
          }
          if (requestUrl.endsWith('/before')) return route.fulfill({ contentType: 'text/html', body: `<a href="${url}index.html?legacy=1#weekly">Old PERK link</a>` });
          if (mode !== 'normal') {
            let content = html;
            if (mode === 'script' || mode === 'fallback') content = content.replace(/\s*<meta http-equiv="refresh"[^>]*>/, '');
            if (mode === 'fallback') content = content.replace(/\s*<script>[\s\S]*?<\/script>/, '');
            return route.fulfill({ contentType: 'text/html', body: content });
          }
          return route.continue();
        });
        try { await task(page, reached); assert.deepEqual(errors, []); }
        finally { await context.close(); }
      }
      const navigate = async (page, path) => {
        await page.goto(path, { waitUntil: 'commit' }).catch(error => {
          if (!/ERR_ABORTED|interrupted by another navigation/i.test(error.message)) throw error;
        });
        await page.waitForURL(destination);
      };
      await scenario('normal', async (page, reached) => {
        for (const path of routes) await navigate(page, url + path);
        assert.equal(reached.length, routes.length);
      });
      record(`${name}: unmodified production HTML redirects every tested old path to the exact URL`);
      await scenario('normal', async (page, reached) => {
        await navigate(page, url);
        await navigate(page, url + 'nested/old.html');
        assert.equal(reached.length, 2);
      }, false);
      record(`${name}: zero-delay meta refresh works with JavaScript disabled, including 404 fallback`);
      await scenario('script', async (page, reached) => {
        await page.goto(url + 'before');
        await page.getByRole('link', { name: 'Old PERK link' }).click();
        await page.waitForURL(destination);
        assert.equal(reached.length, 1);
        await page.goBack();
        assert.equal(page.url(), url + 'before');
      });
      record(`${name}: script alone redirects; Back returns to the preceding page without a redirect loop`);
      await scenario('fallback', async (page, reached) => {
        await page.goto(url);
        assert.equal(await page.locator('body > a').count(), 1);
        assert.equal(await page.locator('body *').count(), 1);
        assert.equal(await page.locator('body').innerText(), 'Continue to Perkshire IMDway (PERK)');
        assert.equal(await page.locator('a').getAttribute('href'), destination);
        assert.equal(await page.locator('style, [style], img, script, link[rel="stylesheet"]').count(), 0);
        for (const width of [320, 390, 768, 1440]) {
          await page.setViewportSize({ width, height: 844 });
          const box = await page.locator('a').boundingBox();
          assert.ok(box && box.x >= 0 && box.y >= 0 && box.x + box.width <= width && box.y + box.height < 844);
          assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
          if ([390, 1440].includes(width)) await page.screenshot({ path: join(shots, `${name.toLowerCase()}-${width}.png`) });
        }
        await page.setViewportSize({ width: 320, height: 844 });
        await page.locator('a').evaluate(element => { element.style.fontSize = '200%'; });
        assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
        await page.locator('a').evaluate(element => { element.removeAttribute('style'); });
        await page.setViewportSize({ width: 390, height: 844 });
        await page.keyboard.press('Tab');
        assert.equal(await page.locator('a').evaluate(element => element === document.activeElement), true);
        const focus = await page.locator('a').evaluate(element => ({ outline: getComputedStyle(element).outlineStyle, width: getComputedStyle(element).outlineWidth }));
        assert.notEqual(focus.outline, 'none');
        assert.notEqual(focus.width, '0px');
        await page.screenshot({ path: join(shots, `${name.toLowerCase()}-focus-390.png`) });
        const audit = await new AxeBuilder({ page }).withRules(['color-contrast', 'link-name', 'html-has-lang', 'document-title', 'meta-viewport']).analyze();
        assert.deepEqual(audit.violations, []);
        await page.keyboard.press('Enter');
        await page.waitForURL(destination);
        assert.equal(reached.length, 1);
      });
      record(`${name}: fallback link, keyboard focus/Enter, 320/390/768/1440 reflow, 200% text and five applicable axe rules`);
    } finally { await browser.close(); }
  }
} finally { await new Promise(resolve => server.close(resolve)); }
await writeFile(join(root, 'test/scratch/redirect-results.json'), JSON.stringify({ passed: results.length, results }, null, 2) + '\n');
console.log(`${results.length} grouped checks passed. Screenshots and report are in test/scratch/. External navigation was intercepted; no wallet or RPC used.`);
