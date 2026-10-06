import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import {
  startRails, launchChrome, observedPage, requireModelContext, toolNames,
  assertStrictCSP, assertCleanBrowser,
} from './support.mjs';

const [app, expectedDigest] = process.argv.slice(2);
assert.ok(app && expectedDigest, 'Pass the temporary Rails app path and packaged runtime digest');
let server, browser;
function curl200(url) {
  const result = execFileSync('curl', ['--fail', '--silent', '--show-error', '--max-time', '10',
    '--write-out', '%{http_code}', url]);
  assert.equal(result.subarray(-3).toString(), '200', `curl HTTP status for ${url}`);
  return result.subarray(0, -3);
}

try {
  server = await startRails(app, { RAILS_ENV: 'production', SECRET_KEY_BASE: 'dummy' });
  const html = curl200(`${server.url}/page_a`).toString();
  const assetPath = html.match(/src="([^"\s]*\/webmcp\/runtime-[^"\s]+\.js)"/)?.[1];
  assert.ok(assetPath, 'Page must reference the digested webmcp/runtime.js asset');
  const javascript = curl200(`${server.url}${assetPath}`);
  assert.equal(createHash('sha256').update(javascript).digest('hex'), expectedDigest);
  assert.match(javascript.toString(), /@webmcp\/runtime v0\.1\.0/);
  console.log(`Production curl: page 200; ${assetPath} 200; canonical runtime SHA-256 ${expectedDigest}`);
  browser = await launchChrome();
  const observation = await observedPage(browser);
  const { page } = observation;
  assertStrictCSP(await page.goto(`${server.url}/page_a`));
  await requireModelContext(page);
  assert.deepEqual(await toolNames(page), ['packaged_items']);
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  assertCleanBrowser(observation);
  console.log('Production Chrome: tools registered; CSP violations 0; console errors 0');
} catch (error) {
  if (server) console.error(server.output());
  throw error;
} finally {
  try { if (browser) await browser.close(); }
  finally { if (server) await server.stop(); }
}
