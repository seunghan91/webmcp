import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  startRails, launchChrome, observedPage, requireModelContext, toolNames,
  executeRaw, assertStrictCSP, assertCleanBrowser,
} from './support.mjs';

const pageA = ['boom', 'items_create', 'items_read', 'redirect_read', 'redirect_write', 'string_tool'];
const pageB = ['items_read', 'string_tool'];

test('Rails + Chrome WebMCP release gate', { timeout: 120_000 }, async t => {
  const directory = await mkdtemp(join(tmpdir(), 'webmcp-browser-'));
  const requestLog = join(directory, 'requests.jsonl');
  let server, browser;
  try {
    server = await startRails(fileURLToPath(new URL('../dummy/', import.meta.url)), { WEBMCP_REQUEST_LOG: requestLog });
    browser = await launchChrome();
    const observation = await observedPage(browser);
    const { page } = observation;
    assertStrictCSP(await page.goto(`${server.url}/page_a`));
    await requireModelContext(page);
    const execute = async (name, input) => JSON.parse(await executeRaw(page, name, input));
    const audit = async () => (await readFile(requestLog, 'utf8').catch(error => {
      if (error.code === 'ENOENT') return '';
      throw error;
    })).trim().split('\n').filter(Boolean).map(line => JSON.parse(line));

    await t.test('1. Page A registers exactly its tools, titles and annotations', async () => {
      assert.deepEqual(await toolNames(page), pageA);
      const entries = await page.evaluate(async () => {
        const manifest = JSON.parse(document.querySelector('#webmcp-manifest').textContent);
        return (await document.modelContext.getTools()).map(tool => ({
          name: tool.name, title: tool.title, annotations: { ...tool.annotations },
          expected: manifest.tools.find(entry => entry.name === tool.name),
        }));
      });
      for (const tool of entries) {
        assert.equal(tool.title, tool.expected.title, tool.name);
        for (const key of ['readOnlyHint', 'untrustedContentHint', 'consequentialHint']) {
          assert.equal(tool.annotations[key] ?? false, tool.expected.annotations[key] ?? false, `${tool.name}.${key}`);
        }
      }
    });
    await t.test('2. Projected MCP read tool round-trips bracket arrays through Rack', async () => {
      assert.deepEqual(await execute('items_read', { tags: ['a', 'b'] }), {
        ok: true, status: 200, data: { tags: ['a', 'b'] },
      });
    });
    await t.test('3. Write succeeds with real CSRF protection', async () => {
      // First prove the server rejects a direct request without a token.
      const denied = await page.request.post(`${server.url}/api/items`, { data: { title: 'denied' } });
      assert.equal(denied.status(), 422, 'Rails must actually enforce CSRF');
      assert.deepEqual(await execute('items_create', { title: 'x' }), {
        ok: true, status: 201, data: { title: 'x' },
      });
    });
    await t.test('4. Missing CSRF prevents any request reaching the server', async () => {
      const before = await audit();
      await page.evaluate(() => {
        window.savedCSRF = document.querySelector('meta[name="csrf-token"]').outerHTML;
        document.querySelector('meta[name="csrf-token"]').remove();
      });
      try {
        const result = await execute('items_create', { title: 'blocked' });
        assert.equal(result.ok, false);
        assert.equal(result.error.code, 'csrf_token_missing');
        assert.deepEqual(await audit(), before, 'Server request log changed despite the missing token');
        console.log(`CSRF missing: server request log unchanged (${before.length} API requests)`);
      } finally {
        await page.evaluate(() => document.head.insertAdjacentHTML('beforeend', window.savedCSRF));
      }
    });
    await t.test('5. Read/write redirects have distinct failure outcomes', async () => {
      // redirect:'error' is logged against the redirect target as net::ERR_FAILED.
      observation.expectedNetworkErrors.push(
        { path: '/api/items', text: 'Failed to load resource: net::ERR_FAILED' },
        { path: '/api/items', text: 'Failed to load resource: net::ERR_FAILED' });
      for (const [name, code] of [['redirect_read', 'network_error'], ['redirect_write', 'unknown_outcome']]) {
        const result = await execute(name);
        assert.equal(result.ok, false);
        assert.equal(result.error.code, code);
      }
    });
    await t.test('6. HTTP 500 returns an http_error envelope', async () => {
      observation.expectedNetworkErrors.push(
        { path: '/api/boom', text: 'Failed to load resource: the server responded with a status of 500' });
      const result = await execute('boom');
      assert.equal(result.ok, false);
      assert.equal(result.status, 500);
      assert.equal(result.error.code, 'http_error');
    });
    await t.test('7. Record native executeTool serialization for envelope and plain string', async () => {
      await page.evaluate(async () => {
        window.stringController = new AbortController();
        await document.modelContext.registerTool({
          name: 'plain_string_probe', description: 'Return a plain string for serialization measurement.',
          inputSchema: { type: 'object', properties: {} }, execute: () => 'hi',
        }, { signal: window.stringController.signal });
      });
      try {
        const envelope = await executeRaw(page, 'string_tool');
        console.log(`executeTool envelope raw: ${JSON.stringify(envelope)}`);
        assert.deepEqual(JSON.parse(envelope), { ok: true, status: 200, data: 'hello' });
        console.log(`executeTool plain string raw: ${JSON.stringify(await executeRaw(page, 'plain_string_probe'))}`);
      } finally {
        await page.evaluate(() => window.stringController.abort());
      }
    });
    await t.test('8. Turbo navigation replaces the page tool set without a document reload', async () => {
      const visits = await page.evaluate(() => {
        window.documentSentinel = 'same-document';
        return window.turboVisits;
      });
      await page.locator('#next-page').click();
      await page.waitForURL(`${server.url}/page_b`);
      await page.waitForFunction(previous => window.turboVisits > previous, visits);
      assert.equal(await page.evaluate(() => window.documentSentinel), 'same-document');
      await page.waitForFunction(expected => document.modelContext.getTools().then(
        tools => JSON.stringify(tools.map(tool => tool.name).sort()) === JSON.stringify(expected)), pageB);
      assert.deepEqual(await toolNames(page), pageB);
      // Page B changes every fingerprint, so these names were aborted and
      // registered again immediately. The new callbacks must be live.
      const fingerprints = await page.evaluate(() =>
        JSON.parse(document.querySelector('#webmcp-manifest').textContent).transport.csrf.header);
      assert.equal(fingerprints, 'X-CSRF-Token-Page-B');
      assert.deepEqual(await execute('string_tool', {}), { ok: true, status: 200, data: 'hello' });
      // Only the re-registered callback knows page B's header name.
      const last = (await audit()).filter(entry => entry.path === '/api/string').at(-1);
      assert.equal(last.csrf_header, 'page-b', 'the page B callback sent the request');
    });
    await t.test('10. A first page without a manifest registers tools on the next Turbo visit', async () => {
      const fresh = await observedPage(browser);
      const second = fresh.page;
      try {
        await second.goto(`${server.url}/page_empty`);
        await second.waitForLoadState('networkidle');
        assert.equal(await second.evaluate(() => globalThis.WebMCPRuntime === undefined), true);
        assert.deepEqual(await toolNames(second), []);
        await second.evaluate(() => { window.documentSentinel = 'same-document'; });
        await second.locator('#next-page').click();
        await second.waitForURL(`${server.url}/page_a`);
        await second.waitForFunction(() => window.turboVisits >= 2);
        assert.equal(await second.evaluate(() => window.documentSentinel), 'same-document',
          'a Turbo visit, not a full load that would re-evaluate the module');
        await second.waitForFunction(expected => document.modelContext.getTools().then(
          tools => JSON.stringify(tools.map(tool => tool.name).sort()) === JSON.stringify(expected)), pageA);
        assert.equal(await second.evaluate(() => typeof globalThis.WebMCPRuntime?.handle?.refresh), 'function');
        assertCleanBrowser(fresh);
      } finally {
        await second.close();
      }
    });
    await t.test('9. Both pages have zero CSP violations and console errors', async () => {
      // Flush asynchronous CSP reporting before checking every collected error.
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      assertCleanBrowser(observation);
    });
  } catch (error) {
    if (server) console.error(server.output());
    throw error;
  } finally {
    try { if (browser) await browser.close(); }
    finally {
      try { if (server) await server.stop(); }
      finally { await rm(directory, { recursive: true, force: true }); }
    }
  }
});
