import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:net';
import { setTimeout as delay } from 'node:timers/promises';
import { chromium } from 'playwright';

export async function startRails(cwd, env = {}) {
  const socket = createServer();
  socket.listen(0, '127.0.0.1');
  await once(socket, 'listening');
  const port = socket.address().port;
  await new Promise(resolve => socket.close(resolve));
  const child = spawn('bin/rails', ['server', '-b', '127.0.0.1', '-p', String(port)], {
    cwd, env: { ...process.env, RAILS_ENV: 'test', ...env }, stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  child.stdout.on('data', data => { output += data; });
  child.stderr.on('data', data => { output += data; });
  let spawnError;
  child.on('error', error => { spawnError = error; });
  const exited = once(child, 'exit').catch(() => {});
  const stop = async () => {
    if (child.exitCode === null && child.signalCode === null) {
      child.kill('SIGTERM');
      const timer = setTimeout(() => child.kill('SIGKILL'), 5000);
      try { await exited; } finally { clearTimeout(timer); }
    }
  };
  const url = `http://127.0.0.1:${port}`;
  try {
    for (let attempt = 0; attempt < 300; ++attempt) {
      if (spawnError || child.exitCode !== null) throw spawnError ?? new Error('Rails exited');
      try {
        const response = await fetch(`${url}/page_a`, { signal: AbortSignal.timeout(1000) });
        if (response.status === 200) return { url, stop, output: () => output };
        if (response.status >= 400) throw new Error(`Rails readiness HTTP ${response.status}: ${await response.text()}`);
      } catch (error) {
        if (error.message.startsWith('Rails readiness')) throw error;
      }
      await delay(100);
    }
    throw new Error('Rails readiness timeout');
  } catch (error) {
    await stop();
    throw new Error(`${error.message}\n${output}`, { cause: error });
  }
}

export async function launchChrome() {
  const browser = await chromium.launch({ channel: 'chrome', args: ['--enable-features=WebMCPTesting'] });
  console.log(`Chrome version: ${browser.version()}`);
  return browser;
}

export async function observedPage(browser) {
  const page = await browser.newPage();
  const violations = [], consoleErrors = [], pageErrors = [];
  await page.exposeFunction('reportCSPViolation', violation => violations.push(violation));
  await page.addInitScript(() => {
    document.addEventListener('securitypolicyviolation', event => {
      window.reportCSPViolation({ directive: event.effectiveDirective, blockedURI: event.blockedURI });
    });
    window.turboVisits = 0;
    document.addEventListener('turbo:load', () => ++window.turboVisits);
  });
  // Checks that fail on purpose register the exact network log lines they expect;
  // each allowance is consumed once. Anything else, including CSP and script errors, counts.
  const expectedNetworkErrors = [];
  page.on('console', message => {
    if (message.type() !== 'error') return;
    const location = message.location();
    const path = location.url ? new URL(location.url).pathname : '';
    const text = message.text();
    const index = expectedNetworkErrors.findIndex(entry => entry.path === path && text.startsWith(entry.text));
    if (index >= 0) expectedNetworkErrors.splice(index, 1);
    else consoleErrors.push({ text, location });
  });
  page.on('pageerror', error => pageErrors.push(String(error)));
  return { page, violations, consoleErrors, pageErrors, expectedNetworkErrors };
}

export async function requireModelContext(page) {
  assert.equal(await page.evaluate(() => Boolean(document.modelContext)), true,
    'document.modelContext is undefined in this Chrome build even with --enable-features=WebMCPTesting; the real-browser release gate cannot run.');
  await page.waitForFunction(() => Boolean(globalThis.WebMCPRuntime?.handle));
  // Wait for autostart's reconciliation, without manually refreshing/mounting.
  await page.waitForFunction(async () => (await document.modelContext.getTools()).length > 0);
}

export async function toolNames(page) {
  return page.evaluate(async () => (await document.modelContext.getTools()).map(tool => tool.name).sort());
}

export async function executeRaw(page, name, input = {}) {
  return page.evaluate(async ({ name, input, strict }) => {
    const context = document.modelContext;
    const tool = (await context.getTools()).find(tool => tool.name === name);
    if (!tool) throw new Error(`Missing tool: ${name}`);
    // This helper plays the agent. The spec's object input ships in Chrome 155;
    // Chrome 154 accepts only the legacy JSON string. The runtime's execute
    // callback receives an object either way. WEBMCP_STRICT_OBJECT_INPUT=1
    // disables the fallback to test the spec's object form strictly.
    try {
      return await context.executeTool(tool, input);
    } catch (error) {
      if (strict || !/Failed to parse input arguments/.test(String(error?.message))) throw error;
      globalThis.__webmcpLegacyInput = true;
      return context.executeTool(tool, JSON.stringify(input));
    }
  }, { name, input, strict: process.env.WEBMCP_STRICT_OBJECT_INPUT === '1' });
}

export function assertStrictCSP(response) {
  const policy = response.headers()['content-security-policy'];
  assert.ok(policy, 'The response must enforce CSP');
  assert.match(policy, /script-src 'self' 'nonce-[^']+'/);
  assert.doesNotMatch(policy, /'unsafe-inline'/);
}

export function assertCleanBrowser(observation) {
  assert.deepEqual(observation.expectedNetworkErrors, [], 'Expected network failures that never occurred');
  assert.deepEqual(observation.violations, [], 'CSP violations');
  assert.deepEqual(observation.consoleErrors, [], 'Browser console errors');
  assert.deepEqual(observation.pageErrors, [], 'Uncaught JavaScript errors');
}
