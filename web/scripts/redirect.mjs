import assert from 'node:assert/strict';

export const destination = 'https://perkshire-imdway-perk-on-robinho.sites.imd.fun/';
export function assertRedirect(html) {
  assert.match(html, /^<!doctype html>/i);
  const head = html.match(/<head>([\s\S]*?)<\/head>/i)?.[1];
  assert.ok(head, 'The redirect must be in the head.');
  assert.ok(head.includes(`<meta http-equiv="refresh" content="0; url=${destination}">`));
  const scripts = [...head.matchAll(/<script>([\s\S]*?)<\/script>/g)];
  assert.equal(scripts.length, 1);
  assert.equal(scripts[0][1], `location.replace("${destination}");`);
  assert.equal(html.match(/<body>([\s\S]*?)<\/body>/i)?.[1].trim(),
    `<a href="${destination}">Continue to Perkshire IMDway (PERK)</a>`);
  assert.doesNotMatch(html, /<style\b|\sstyle\s*=|<img\b|<iframe\b|<link[^>]*stylesheet|<script[^>]*\ssrc=/i);
  assert.match(head, /<title>Perkshire IMDway \(PERK\)<\/title>/);
  for (const field of ['name="description"', 'property="og:title"', 'property="og:image"', 'rel="icon"']) {
    assert.ok(head.includes(field), `Missing ${field}`);
  }
}
