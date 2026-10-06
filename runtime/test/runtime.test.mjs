import test from 'node:test';
import assert from 'node:assert/strict';
import { mount, validateInput, encodeQuery, buildRequest, toOutcome } from '../webmcp-runtime.js';

const metaTransport = { csrf: { source: 'meta', name: 'csrf-token', header: 'X-CSRF-Token' } };
const cookieTransport = { csrf: { source: 'cookie', name: 'csrftoken', header: 'X-CSRFToken' } };

function tool(readOnly = true, overrides = {}) {
  return {
    name: 'tasks', description: 'Read or update tasks.',
    inputSchema: { type: 'object', properties: { title: { type: 'string' } } },
    annotations: { readOnlyHint: readOnly }, fingerprint: 'sha256:first',
    ...overrides,
    endpoint: { path: '/api/tasks', method: readOnly ? 'GET' : 'POST', ...overrides.endpoint },
  };
}

function manifest(tools, transport) {
  return { webmcpManifestVersion: 1, tools, ...(transport ? { transport } : {}) };
}

class FakeDocument extends EventTarget {
  constructor(value, selector = '#webmcp-manifest') {
    super();
    this.location = new URL('https://app.example/current/page');
    this.cookie = '';
    this.meta = new Map();
    this.selector = selector;
    this.queries = [];
    this.listeners = new Set();
    this.setManifest(value);
  }
  setManifest(value) {
    this.element = value === undefined ? null : { textContent: JSON.stringify(value) };
  }
  querySelector(selector) {
    this.queries.push(selector);
    if (selector === this.selector) return this.element;
    return this.meta.get(selector) ?? null;
  }
  addEventListener(type, listener, options) {
    super.addEventListener(type, listener, options);
    this.listeners.add(listener);
  }
  removeEventListener(type, listener, options) {
    super.removeEventListener(type, listener, options);
    this.listeners.delete(listener);
  }
}

class FakeModelContext {
  calls = [];
  active = new Map();
  constructor(behavior = () => Promise.resolve()) { this.behavior = behavior; }
  registerTool(definition, options) {
    const call = { definition, options };
    this.calls.push(call);
    if (this.active.has(definition.name)) throw new DOMException('Duplicate name', 'InvalidStateError');
    this.active.set(definition.name, call);
    options.signal.addEventListener('abort', () => {
      if (this.active.get(definition.name) === call) this.active.delete(definition.name);
    }, { once: true });
    return this.behavior(call);
  }
}

function response(status = 200, data = { tasks: [] }, error) {
  return { status, async json() { if (error) throw error; return data; } };
}

async function harness(t, definition = tool(), options = {}) {
  const doc = options.doc ?? new FakeDocument(manifest([definition], options.transport));
  const context = options.context ?? new FakeModelContext();
  const fetchCalls = [];
  const handle = mount({
    document: doc, modelContext: context, selector: options.selector,
    fetch: (...args) => {
      fetchCalls.push(args);
      return options.fetch ? options.fetch(...args) : Promise.resolve(response());
    },
  });
  t.after(() => handle.dispose());
  await handle.refresh();
  return {
    doc, context, fetchCalls, handle,
    execute: (input = {}, options = {}) => context.active.get(definition.name).definition.execute(input, options),
  };
}

function assertFailure(actual, code, status) {
  assert.equal(actual.ok, false);
  assert.equal(actual.error.code, code);
  assert.equal(typeof actual.error.message, 'string');
  assert.ok(actual.error.message.length > 0);
  if (status === undefined) assert.equal(Object.hasOwn(actual, 'status'), false);
  else assert.equal(actual.status, status);
  assert.equal(Object.hasOwn(actual, 'data'), false);
  assert.doesNotThrow(() => JSON.stringify(actual));
}

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function setGlobal(t, key, value) {
  const old = Object.getOwnPropertyDescriptor(globalThis, key);
  Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });
  t.after(() => {
    if (old) Object.defineProperty(globalThis, key, old);
    else delete globalThis[key];
  });
}

// The complete §8-7 outcome table is exercised through registered callbacks for
// both read and write tools, not just through the pure conversion helper.
for (const readOnly of [true, false]) {
  const label = readOnly ? 'read' : 'write';
  for (const [status, data] of [[200, { tasks: [1] }], [201, 'saved'], [299, null]]) {
    test(`${label}: ${status} JSON is returned intact`, async t => {
      const h = await harness(t, tool(readOnly), { fetch: async () => response(status, data) });
      assert.deepEqual(await h.execute(), { ok: true, status, data });
      assert.equal(h.fetchCalls.length, 1);
    });
  }

  test(`${label}: response exactly at the character limit succeeds`, async t => {
    const data = { text: '😀é' };
    const h = await harness(t, tool(readOnly, { maxResponseChars: JSON.stringify(data).length }), {
      fetch: async () => response(200, data),
    });
    assert.deepEqual(await h.execute(), { ok: true, status: 200, data });
  });

  for (const [code, makeResponse] of [
    ['response_too_large', () => response(200, { text: 'larger than the limit' })],
    ['invalid_response', () => response(200, undefined, new SyntaxError('Unexpected HTML'))],
  ]) {
    test(`${label}: ${code} follows the read/write outcome contract`, async t => {
      const h = await harness(t, tool(readOnly, { maxResponseChars: 2 }), { fetch: async () => makeResponse() });
      const actual = await h.execute();
      if (readOnly) {
        assertFailure(actual, code, 200);
        if (code === 'response_too_large') assert.match(actual.error.message, /Narrow/);
      } else {
        assert.deepEqual(actual, {
          ok: true, status: 200, data: null, dataOmitted: code,
          message: 'The operation succeeded. Do not repeat it.',
        });
      }
      assert.equal(h.fetchCalls.length, 1);
    });
  }

  test(`${label}: 204 succeeds without reading JSON or applying the size cap`, async t => {
    const h = await harness(t, tool(readOnly, { maxResponseChars: 0 }), {
      fetch: async () => ({ status: 204, json() { assert.fail('204 has no JSON body'); } }),
    });
    assert.deepEqual(await h.execute(), { ok: true, status: 204, data: null });
  });

  for (const status of [302, 400, 403, 413, 500]) {
    test(`${label}: HTTP ${status} is http_error even with a non-JSON body`, async t => {
      const h = await harness(t, tool(readOnly), {
        fetch: async () => ({ status, json() { assert.fail('HTTP failures need no JSON body'); } }),
      });
      assertFailure(await h.execute(), 'http_error', status);
      assert.equal(h.fetchCalls.length, 1);
    });
  }

  for (const [name, error] of [
    ['network failure', new TypeError('Failed to fetch')],
    ['redirect rejection', new TypeError('Redirect is not allowed')],
    ['abort', new DOMException('Cancelled', 'AbortError')],
    ['unexpected rejection', new Error('Rejected')],
  ]) {
    test(`${label}: ${name} after dispatch never throws or retries`, async t => {
      const h = await harness(t, tool(readOnly), { fetch: async () => { throw error; } });
      const actual = await h.execute();
      assertFailure(actual, readOnly ? (error.name === 'AbortError' ? 'aborted' : 'network_error') : 'unknown_outcome');
      if (!readOnly) assert.match(actual.error.message, /Do not retry automatically; ask the user to check/);
      assert.equal(h.fetchCalls.length, 1);
    });
  }

  for (const error of [new TypeError('Body stream failed'), new DOMException('Cancelled', 'AbortError')]) {
    test(`${label}: ${error.name} while reading the body is a transport failure`, async t => {
      const h = await harness(t, tool(readOnly), { fetch: async () => response(200, undefined, error) });
      assertFailure(await h.execute(), readOnly ? (error.name === 'AbortError' ? 'aborted' : 'network_error') : 'unknown_outcome');
      assert.equal(h.fetchCalls.length, 1);
    });
  }

  test(`${label}: input failure prevents dispatch`, async t => {
    const h = await harness(t, tool(readOnly));
    assertFailure(await h.execute({ undeclared: 'no' }), 'invalid_input');
    assert.equal(h.fetchCalls.length, 0);
  });

  test(`${label}: missing configured CSRF on POST prevents dispatch`, async t => {
    const h = await harness(t, tool(readOnly, { endpoint: { method: 'POST' } }), { transport: metaTransport });
    assertFailure(await h.execute(), 'csrf_token_missing');
    assert.equal(h.fetchCalls.length, 0);
  });

  test(`${label}: a signal already aborted prevents dispatch`, async t => {
    const h = await harness(t, tool(readOnly));
    assertFailure(await h.execute({}, { signal: AbortSignal.abort() }), 'aborted');
    assert.equal(h.fetchCalls.length, 0);
  });

  test(`${label}: the execution signal and same-origin options reach fetch`, async t => {
    const h = await harness(t, tool(readOnly));
    const controller = new AbortController();
    await h.execute({}, { signal: controller.signal });
    const [url, options] = h.fetchCalls[0];
    assert.equal(url, 'https://app.example/api/tasks');
    assert.equal(options.signal, controller.signal);
    assert.notEqual(options.signal, h.context.calls[0].options.signal);
    assert.equal(options.method, readOnly ? 'GET' : 'POST');
    assert.equal(options.mode, 'same-origin');
    assert.equal(options.credentials, 'same-origin');
    assert.equal(options.redirect, 'error');
    assert.equal(options.headers.Accept, 'application/json');
  });
}

test('only readOnlyHint === true gets read outcomes, including read-only POST', async t => {
  for (const annotations of [undefined, {}, { readOnlyHint: false }, { readOnlyHint: 'true' }]) {
    const h = await harness(t, tool(false, { annotations }), { fetch: async () => { throw new TypeError(); } });
    assertFailure(await h.execute(), 'unknown_outcome');
  }
  const h = await harness(t, tool(true, { endpoint: { method: 'POST' } }), { fetch: async () => { throw new TypeError(); } });
  assertFailure(await h.execute(), 'network_error');
});

test('meta CSRF token is re-read on every invocation', async t => {
  const h = await harness(t, tool(false), { transport: metaTransport });
  const meta = { content: 'first-token' };
  h.doc.meta.set('meta[name="csrf-token"]', meta);
  await h.execute();
  meta.content = 'rotated-token';
  await h.execute();
  h.doc.meta.delete('meta[name="csrf-token"]');
  assertFailure(await h.execute(), 'csrf_token_missing');
  assert.equal(h.fetchCalls.length, 2);
  assert.equal(h.fetchCalls[0][1].headers['X-CSRF-Token'], 'first-token');
  assert.equal(h.fetchCalls[1][1].headers['X-CSRF-Token'], 'rotated-token');
});

test('cookie CSRF uses an exact name, decodes values, and sees rotation/removal', async t => {
  const h = await harness(t, tool(false), { transport: cookieTransport });
  h.doc.cookie = 'prefixcsrftoken=wrong; csrftoken=abc%2Bdef%3D%3D; session=opaque';
  await h.execute();
  h.doc.cookie = 'csrftoken=rotated+raw==; another=cookie';
  await h.execute();
  h.doc.cookie = 'csrftoken=; prefixcsrftoken=wrong';
  assertFailure(await h.execute(), 'csrf_token_missing');
  assert.equal(h.fetchCalls.length, 2);
  assert.equal(h.fetchCalls[0][1].headers['X-CSRFToken'], 'abc+def==');
  assert.equal(h.fetchCalls[1][1].headers['X-CSRFToken'], 'rotated+raw==');
});

test('GET permits a missing CSRF token and sends one if present', async t => {
  const h = await harness(t, tool(), { transport: metaTransport });
  assert.equal((await h.execute()).ok, true);
  assert.deepEqual(h.fetchCalls[0][1].headers, { Accept: 'application/json' });
  h.doc.meta.set('meta[name="csrf-token"]', { content: 'present' });
  await h.execute();
  assert.equal(h.fetchCalls[1][1].headers['X-CSRF-Token'], 'present');
});

for (const method of ['POST', 'PATCH', 'DELETE', 'PUT']) {
  test(`${method} without a CSRF configuration is allowed and sends mapped JSON`, async t => {
    const h = await harness(t, tool(false, {
      endpoint: { method, paramMap: { title: 'content' } },
      inputSchema: { type: 'object', properties: { title: { type: 'string' }, tags: { type: 'array', items: { type: 'string' } } } },
    }));
    await h.execute({ title: 'new', tags: ['a', 'b'] });
    assert.deepEqual(h.fetchCalls[0][1].headers, { Accept: 'application/json', 'Content-Type': 'application/json' });
    assert.deepEqual(JSON.parse(h.fetchCalls[0][1].body), { content: 'new', tags: ['a', 'b'] });
  });
}

const inputTool = tool(true, {
  inputSchema: {
    type: 'object', required: ['title'],
    properties: {
      title: { type: 'string' }, count: { type: 'integer' }, price: { type: 'number' },
      completed: { type: 'boolean' }, tags: { type: 'array', items: { type: 'string' } },
    },
  },
});
for (const [label, input] of [
  ['undeclared key', { title: 'ok', extra: 1 }],
  ['__proto__ own key', JSON.parse('{"title":"ok","__proto__":{"polluted":true}}')],
  ['constructor key', { title: 'ok', constructor: 'bad' }],
  ['prototype key', { title: 'ok', prototype: 'bad' }],
  ['required missing', {}],
  ['required inherited', Object.create({ title: 'not own' })],
  ['integer mismatch', { title: 'ok', count: 1.5 }],
  ['integer string', { title: 'ok', count: '1' }],
  ['number mismatch', { title: 'ok', price: '1.5' }],
  ['boolean mismatch', { title: 'ok', completed: 'false' }],
  ['string mismatch', { title: 1 }],
  ['array element mismatch', { title: 'ok', tags: ['a', 1] }],
  ['array null element', { title: 'ok', tags: ['a', null] }],
  ['nested array', { title: 'ok', tags: [['a']] }],
  ['array scalar', { title: 'ok', tags: 'a' }],
  ['sparse array', { title: 'ok', tags: Array(1) }],
  ['null scalar', { title: null }],
  ['undefined scalar', { title: undefined }],
  ['non-finite number', { title: 'ok', price: Infinity }],
  ['NaN', { title: 'ok', price: NaN }],
  ['null input', null],
  ['array input', []],
  ['string input', 'wrong'],
]) {
  test(`invalid input: ${label} is rejected before fetch`, async t => {
    assertFailure(validateInput(inputTool, input), 'invalid_input');
    const h = await harness(t, inputTool);
    assertFailure(await h.execute(input), 'invalid_input');
    assert.equal(h.fetchCalls.length, 0);
  });
}

test('inherited keys are ignored, and only declared own schema and mapping keys apply', async t => {
  const h = await harness(t, inputTool);
  const input = Object.assign(Object.create({ extra: 'ignored', constructor: 'ignored' }), { title: 'own' });
  assert.deepEqual(validateInput(inputTool, input), { ok: true });
  await h.execute(input);
  assert.equal(h.fetchCalls[0][0], 'https://app.example/api/tasks?title=own');
  const definition = tool(true, {
    inputSchema: { type: 'object', properties: Object.create({ secret: { type: 'string' } }) },
  });
  assertFailure(validateInput(definition, { secret: 'hidden' }), 'invalid_input');
  definition.inputSchema.properties = { title: { type: 'string' } };
  definition.endpoint.paramMap = Object.create({ title: 'wrong' });
  assert.equal(encodeQuery(definition, { title: 'own' }), 'title=own');
});

test('forbidden own keys are rejected even if declared in the schema', () => {
  for (const key of ['__proto__', 'constructor', 'prototype']) {
    const definition = tool(true, { inputSchema: { type: 'object', properties: { [key]: { type: 'string' } } } });
    assertFailure(validateInput(definition, { [key]: 'value' }), 'invalid_input');
  }
});

test('runtime validates scalar array item types without enum, range or length checks', () => {
  for (const [type, value, invalid] of [
    ['string', 'long text', false], ['number', -1.5, '1.5'], ['integer', -100, 1.5], ['boolean', false, 'false'],
  ]) {
    const definition = tool(true, {
      inputSchema: { type: 'object', properties: {
        values: { type: 'array', maxItems: 0, items: { type, enum: [], minimum: 0, maximum: 1, maxLength: 0 } },
        scalar: { type, enum: [], minimum: 0, maximum: 1, maxLength: 0 },
      } },
    });
    assert.deepEqual(validateInput(definition, { values: [value, value], scalar: value }), { ok: true });
    assert.deepEqual(validateInput(definition, { values: [] }), { ok: true });
    assertFailure(validateInput(definition, { values: [invalid] }), 'invalid_input');
  }
});

for (const arrayFormat of ['brackets', 'repeat']) {
  test(`GET ${arrayFormat} encoding maps names and preserves booleans, order and escaping`, async t => {
    const definition = tool(true, {
      endpoint: { path: '/api/tasks?existing=1', arrayFormat, paramMap: { tags: 'labels', title: 'content' } },
      inputSchema: { type: 'object', properties: {
        tags: { type: 'array', items: { type: 'string' } }, title: { type: 'string' },
        completed: { type: 'boolean' }, count: { type: 'integer' }, missing: { type: 'string' },
        absent: { type: 'string' }, empty: { type: 'array', items: { type: 'string' } },
      } },
    });
    const input = { tags: ['a b', '한글&='], title: 'A+B', completed: false, count: 0, empty: [] };
    const before = structuredClone({ definition, input });
    const query = encodeQuery(definition, { ...input, missing: null, absent: undefined });
    const key = arrayFormat === 'brackets' ? 'labels[]' : 'labels';
    assert.deepEqual([...new URLSearchParams(query)], [
      [key, 'a b'], [key, '한글&='], ['content', 'A+B'], ['completed', 'false'], ['count', '0'],
    ]);
    assert.equal(encodeQuery(definition, { completed: true }), 'completed=true');
    const h = await harness(t, definition);
    await h.execute(input);
    const [url, options] = h.fetchCalls[0];
    assert.equal(url, `https://app.example/api/tasks?existing=1&${query}`);
    assert.equal(Object.hasOwn(options, 'body'), false);
    assert.deepEqual(options.headers, { Accept: 'application/json' });
    assert.deepEqual({ definition, input }, before);
  });
}

for (const path of [
  'https://evil.example/api', '//evil.example/api', '///evil.example/api',
  'https://app.example/api', 'relative/path', '/\\evil.example/api',
  '/api\\tasks', '/\n/evil.example', '/api\u0000tasks', 'javascript:alert(1)',
]) {
  test(`unsafe endpoint ${JSON.stringify(path)} is rejected before fetch`, async t => {
    const h = await harness(t, tool(false, { endpoint: { path } }));
    assertFailure(await h.execute(), 'invalid_input');
    assert.equal(h.fetchCalls.length, 0);
  });
}

test('buildRequest uses document origin, not baseURI, and supports the global location fallback', t => {
  const doc = { location: { origin: 'https://app.example' }, baseURI: 'https://evil.example/' };
  const actual = buildRequest(tool(), { title: 'safe' }, {}, doc);
  assert.equal(actual.url, 'https://app.example/api/tasks?title=safe');
  setGlobal(t, 'location', { origin: 'https://fallback.example' });
  assert.equal(buildRequest(tool(), {}, {}, {}).url, 'https://fallback.example/api/tasks');
  assert.equal(buildRequest(tool(true, { endpoint: { path: '/' } }), {}, {}, doc).url, 'https://app.example/');
});

test('toOutcome is pure and applies limits only when configured', () => {
  const data = { text: 'x'.repeat(2000) };
  assert.deepEqual(toOutcome(tool(), { status: 200, data }), { ok: true, status: 200, data });
  assertFailure(toOutcome(tool(), { code: 'csrf_token_missing' }, 'before-dispatch'), 'csrf_token_missing');
  assertFailure(toOutcome(tool(false), new TypeError(), 'before-dispatch'), 'invalid_input');
  assertFailure(toOutcome(tool(), new DOMException('', 'AbortError'), 'after-dispatch'), 'aborted');
  assertFailure(toOutcome(tool(false), new TypeError(), 'after-dispatch'), 'unknown_outcome');
  assertFailure(toOutcome(tool(true, { maxResponseChars: 0 }), { status: 200, data: null }), 'response_too_large', 200);
  assert.equal(data.text.length, 2000);
});

test('unexpected pre-dispatch exceptions still return an outcome', async t => {
  const h = await harness(t, tool(false));
  const input = { get title() { throw new Error('Accessor failed'); } };
  assertFailure(await h.execute(input), 'invalid_input');
  assert.equal(h.fetchCalls.length, 0);
});

test('mount registers only the IDL fields and separate tool controllers', async t => {
  const first = tool(true, { title: 'Tasks', annotations: { readOnlyHint: true, untrustedContentHint: true, consequentialHint: true, debugging: true }, exposedTo: ['https://evil.example'] });
  const second = tool(false, { name: 'update', annotations: undefined });
  const h = await harness(t, first, { doc: new FakeDocument(manifest([first, second])) });
  const [one, two] = h.context.calls;
  assert.deepEqual(Object.keys(one.definition).sort(), ['annotations', 'description', 'execute', 'inputSchema', 'name', 'title']);
  assert.deepEqual(one.definition.annotations, first.annotations);
  assert.equal(one.definition.title, 'Tasks');
  assert.deepEqual(Object.keys(one.options), ['signal']);
  assert.equal(Object.hasOwn(two.definition, 'title'), false);
  assert.equal(Object.hasOwn(two.definition, 'annotations'), false);
  assert.notEqual(one.options.signal, two.options.signal);
  assert.equal(h.context.calls.length, 2);
});

test('mount auto-registers from a custom selector', async t => {
  const started = deferred();
  const context = new FakeModelContext(() => { started.resolve(); });
  const doc = new FakeDocument(manifest([tool()]), '#custom');
  const handle = mount({ document: doc, modelContext: context, selector: '#custom' });
  t.after(() => handle.dispose());
  await started.promise;
  assert.equal(context.calls.length, 1);
  assert.deepEqual(doc.queries, ['#custom']);
});

test('missing modelContext is a silent no-op, including absent browser globals', async t => {
  const warn = t.mock.method(console, 'warn', () => {});
  setGlobal(t, 'document', undefined);
  setGlobal(t, 'navigator', undefined);
  const handle = mount();
  assert.equal(await handle.refresh(), undefined);
  assert.equal(handle.dispose(), undefined);
  assert.equal(await handle.refresh(), undefined);
  assert.equal(warn.mock.callCount(), 0);
});

test('defaults prefer document.modelContext and fall back to navigator.modelContext', async t => {
  const documentContext = new FakeModelContext();
  const navigatorContext = new FakeModelContext();
  const doc = new FakeDocument(manifest([tool()]));
  doc.modelContext = documentContext;
  let fetched = 0;
  setGlobal(t, 'document', doc);
  setGlobal(t, 'navigator', { modelContext: navigatorContext });
  setGlobal(t, 'fetch', async () => { ++fetched; return response(); });
  const handle = mount();
  t.after(() => handle.dispose());
  await handle.refresh();
  assert.equal(documentContext.calls.length, 1);
  assert.equal(navigatorContext.calls.length, 0);
  await documentContext.active.get('tasks').definition.execute({});
  assert.equal(fetched, 1);
  handle.dispose();
  doc.modelContext = null;
  const fallback = mount({ document: doc });
  t.after(() => fallback.dispose());
  await fallback.refresh();
  assert.equal(navigatorContext.calls.length, 1);
  const disabled = mount({ document: doc, modelContext: null });
  await disabled.refresh();
  disabled.dispose();
  assert.equal(navigatorContext.calls.length, 1);
});

test('unknown manifest versions warn once per mount, register nothing, and remove stale tools', async t => {
  const warn = t.mock.method(console, 'warn', () => {});
  const doc = new FakeDocument({ webmcpManifestVersion: 2, tools: [tool()] });
  const h = await harness(t, tool(), { doc });
  await h.handle.refresh();
  doc.setManifest({ webmcpManifestVersion: '1', tools: [tool()] });
  await h.handle.refresh();
  assert.equal(warn.mock.callCount(), 1);
  assert.equal(h.context.calls.length, 0);
  doc.setManifest(manifest([tool()]));
  await h.handle.refresh();
  assert.equal(h.context.active.size, 1);
  doc.setManifest({ tools: [tool()] });
  await h.handle.refresh();
  assert.equal(h.context.calls[0].options.signal.aborted, true);
  assert.equal(h.context.active.size, 0);
  assert.equal(warn.mock.callCount(), 1);
});

test('missing or malformed manifest removes registrations and later refresh recovers', async t => {
  t.mock.method(console, 'warn', () => {});
  const h = await harness(t);
  h.doc.element.textContent = '{bad JSON';
  await h.handle.refresh();
  assert.equal(h.context.active.size, 0);
  h.doc.setManifest(manifest([tool()]));
  await h.handle.refresh();
  assert.equal(h.context.active.size, 1);
  h.doc.setManifest(undefined);
  await h.handle.refresh();
  assert.equal(h.context.active.size, 0);
});

for (const synchronous of [false, true]) {
  test(`a ${synchronous ? 'synchronous throw' : 'registerTool rejection'} is isolated`, async t => {
    const warn = t.mock.method(console, 'warn', () => {});
    const context = new FakeModelContext(({ definition }) => {
      if (definition.name === 'broken') {
        const error = new DOMException('Registration rejected', 'InvalidStateError');
        if (synchronous) throw error;
        return Promise.reject(error);
      }
    });
    const definitions = [tool(true, { name: 'broken' }), tool(true, { name: 'working' })];
    const h = await harness(t, definitions[1], { context, doc: new FakeDocument(manifest(definitions)) });
    assert.equal(context.calls.length, 2);
    assert.equal(context.calls[0].options.signal.aborted, true);
    assert.equal(context.active.has('working'), true);
    assert.equal(warn.mock.callCount(), 1);
    assert.equal((await h.execute()).ok, true);
  });
}

test('refresh diffs by name and fingerprint, aborting changed/removed tools before replacements', async t => {
  const definitions = ['stable', 'changed', 'removed'].map(name => tool(true, { name }));
  const h = await harness(t, definitions[0], { doc: new FakeDocument(manifest(definitions)) });
  const original = [...h.context.calls];
  h.doc.setManifest(manifest([
    tool(true, { name: 'changed', fingerprint: 'sha256:second', title: 'Changed' }),
    definitions[0], tool(true, { name: 'added' }),
  ]));
  await h.handle.refresh();
  assert.equal(h.context.calls.length, 5);
  assert.equal(original[0].options.signal.aborted, false);
  assert.equal(original[1].options.signal.aborted, true);
  assert.equal(original[2].options.signal.aborted, true);
  assert.deepEqual([...h.context.active.keys()].sort(), ['added', 'changed', 'stable']);
  await h.handle.refresh();
  assert.equal(h.context.calls.length, 5);
  h.handle.dispose();
  assert.ok(h.context.calls.every(call => call.options.signal.aborted));
});

test('a changed fingerprint replaces the endpoint and CSRF transport captured by execute', async t => {
  const h = await harness(t, tool(false), { transport: metaTransport });
  h.doc.meta.set('meta[name="csrf-token"]', { content: 'old' });
  await h.execute({ title: 'before' });
  h.doc.cookie = 'csrftoken=new';
  h.doc.setManifest(manifest([tool(false, {
    fingerprint: 'sha256:transport-change', endpoint: { path: '/new', paramMap: { title: 'content' } },
  })], cookieTransport));
  await h.handle.refresh();
  await h.execute({ title: 'after' });
  assert.equal(h.context.calls[0].options.signal.aborted, true);
  assert.equal(h.fetchCalls[1][0], 'https://app.example/new');
  assert.equal(h.fetchCalls[1][1].headers['X-CSRFToken'], 'new');
  assert.equal(h.fetchCalls[1][1].headers['X-CSRF-Token'], undefined);
  assert.deepEqual(JSON.parse(h.fetchCalls[1][1].body), { content: 'after' });
});

test('overlapping refreshes serialize, abort a late old registration, and apply only the latest generation', async t => {
  const started = deferred();
  const slow = deferred();
  const context = new FakeModelContext(() => {
    if (context.calls.length === 1) { started.resolve(); return slow.promise; }
  });
  const doc = new FakeDocument(manifest([tool(true, { title: 'old' })]));
  const handle = mount({ document: doc, modelContext: context });
  t.after(() => handle.dispose());
  await started.promise;
  doc.setManifest(manifest([tool(true, { title: 'intermediate', fingerprint: 'sha256:middle' })]));
  const middle = handle.refresh();
  doc.setManifest(manifest([tool(true, { title: 'latest', fingerprint: 'sha256:last' })]));
  const latest = handle.refresh();
  assert.equal(context.calls.length, 1);
  slow.resolve();
  await Promise.all([middle, latest]);
  assert.equal(context.calls[0].options.signal.aborted, true);
  assert.equal(context.calls.length, 2);
  assert.equal(context.active.get('tasks').definition.title, 'latest');
  assert.equal(context.calls[1].options.signal.aborted, false);
});

test('a superseded pending registration is replaced even if its fingerprint is unchanged', async t => {
  const started = deferred(), slow = deferred();
  const context = new FakeModelContext(() => {
    if (context.calls.length === 1) { started.resolve(); return slow.promise; }
  });
  const doc = new FakeDocument(manifest([tool()]));
  const handle = mount({ document: doc, modelContext: context });
  t.after(() => handle.dispose());
  await started.promise;
  const refreshed = handle.refresh();
  slow.resolve();
  await refreshed;
  assert.equal(context.calls.length, 2);
  assert.equal(context.calls[0].options.signal.aborted, true);
  assert.equal(context.calls[1].options.signal.aborted, false);
});

test('dispose aborts settled/pending generations, clears the queue, and handles late resolution', { timeout: 1000 }, async t => {
  const started = deferred(), slow = deferred();
  const context = new FakeModelContext(({ definition }) => {
    if (definition.name === 'slow') { started.resolve(); return slow.promise; }
  });
  const doc = new FakeDocument(manifest([tool(), tool(true, { name: 'slow' })]));
  const handle = mount({ document: doc, modelContext: context });
  t.after(() => handle.dispose());
  await started.promise;
  doc.setManifest(manifest([tool(true, { name: 'queued' })]));
  const queued = handle.refresh();
  handle.dispose();
  assert.ok(context.calls.every(call => call.options.signal.aborted));
  assert.equal(doc.listeners.size, 0);
  await queued; // Must settle without waiting for slow.resolve().
  await handle.refresh();
  doc.dispatchEvent(new Event('turbo:load'));
  slow.resolve();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(context.calls.length, 2);
  assert.equal(context.active.size, 0);
  handle.dispose();
});

test('dispose before the initial refresh prevents any registration', async () => {
  const context = new FakeModelContext();
  const doc = new FakeDocument(manifest([tool()]));
  const handle = mount({ document: doc, modelContext: context });
  handle.dispose();
  await handle.refresh();
  assert.equal(context.calls.length, 0);
  assert.equal(doc.listeners.size, 0);
});

test('Turbo load automatically refreshes and disposal removes the listener', async t => {
  const h = await harness(t);
  const added = deferred();
  h.context.behavior = ({ definition }) => { if (definition.name === 'next') added.resolve(); };
  h.doc.setManifest(manifest([tool(true, { name: 'next' })]));
  h.doc.dispatchEvent(new Event('turbo:load'));
  await added.promise;
  assert.equal(h.context.calls[0].options.signal.aborted, true);
  assert.equal(h.context.active.has('next'), true);
  h.handle.dispose();
  assert.equal(h.doc.listeners.size, 0);
  h.doc.dispatchEvent(new Event('turbo:load'));
  await h.handle.refresh();
  assert.equal(h.context.calls.length, 2);
});

test('unregistration leaves an in-flight execution controlled solely by its own signal', async t => {
  const pending = deferred();
  const h = await harness(t, tool(false), { fetch: () => pending.promise });
  const controller = new AbortController();
  const execution = h.execute({}, { signal: controller.signal });
  h.doc.setManifest(manifest([]));
  await h.handle.refresh();
  h.handle.dispose();
  assert.equal(h.context.calls[0].options.signal.aborted, true);
  assert.equal(controller.signal.aborted, false);
  assert.equal(h.fetchCalls[0][1].signal, controller.signal);
  pending.resolve(response(201, { saved: true }));
  assert.deepEqual(await execution, { ok: true, status: 201, data: { saved: true } });
});

async function importAutostart(label) {
  return import(`../webmcp-runtime.js?autostart=${label}`);
}

function autostartDocument(t, { enabled = true, loading = false, missing = false } = {}) {
  const doc = new FakeDocument(missing ? undefined : manifest([tool()]));
  doc.readyState = loading ? 'loading' : 'complete';
  doc.modelContext = new FakeModelContext();
  if (doc.element) doc.element.hasAttribute = name => enabled && name === 'data-webmcp-autostart';
  setGlobal(t, 'document', doc);
  setGlobal(t, 'WebMCPRuntime', undefined);
  setGlobal(t, Symbol.for('webmcp.runtime.autostart'), undefined);
  // Capture the handle before global restoration in setGlobal's cleanup hooks.
  doc.addEventListener('webmcp:mounted', event => t.after(() => event.detail.dispose()));
  return doc;
}

test('browser autostart exposes its handle and dispatches exactly one mounted event', async t => {
  const doc = autostartDocument(t);
  const events = [];
  doc.addEventListener('webmcp:mounted', event => events.push(event.detail));
  const module = await importAutostart('enabled');
  const runtime = globalThis.WebMCPRuntime;
  assert.equal(runtime.mount, module.mount);
  assert.deepEqual(events, [runtime.handle]);
  await runtime.handle.refresh();
  assert.equal(doc.modelContext.calls.length, 1);
  await importAutostart('second-evaluation');
  assert.equal(globalThis.WebMCPRuntime, runtime);
  assert.equal(events.length, 1);
  assert.equal(doc.modelContext.calls.length, 1);
});

for (const options of [{ enabled: false }, { missing: true }]) {
  test(`autostart requires an opted-in manifest: ${JSON.stringify(options)}`, async t => {
    const doc = autostartDocument(t, options);
    await importAutostart(JSON.stringify(options));
    assert.equal(globalThis.WebMCPRuntime, undefined);
    assert.equal(doc.modelContext.calls.length, 0);
  });
}

test('autostart waits for parsing and guards duplicate evaluations before DOMContentLoaded', async t => {
  const doc = autostartDocument(t, { loading: true, missing: true });
  let events = 0;
  doc.addEventListener('webmcp:mounted', () => ++events);
  await importAutostart('loading-first');
  await importAutostart('loading-second');
  assert.equal(globalThis.WebMCPRuntime, undefined);
  doc.setManifest(manifest([tool()]));
  doc.element.hasAttribute = name => name === 'data-webmcp-autostart';
  doc.readyState = 'interactive';
  doc.dispatchEvent(new Event('DOMContentLoaded'));
  await globalThis.WebMCPRuntime.handle.refresh();
  assert.equal(events, 1);
  assert.equal(doc.modelContext.calls.length, 1);
  doc.dispatchEvent(new Event('DOMContentLoaded'));
  assert.equal(events, 1);
});

test('autostart waits across empty and opted-out Turbo visits, then starts once and stops listening', async t => {
  const doc = autostartDocument(t, { missing: true });
  let events = 0;
  doc.addEventListener('webmcp:mounted', () => ++events);
  await importAutostart('turbo-empty-optout-optin');
  assert.equal(globalThis.WebMCPRuntime, undefined);
  doc.dispatchEvent(new Event('turbo:load'));
  assert.equal(globalThis.WebMCPRuntime, undefined, 'still no manifest: keep waiting');
  doc.setManifest(manifest([tool()]));
  doc.element.hasAttribute = () => false;
  doc.dispatchEvent(new Event('turbo:load'));
  assert.equal(globalThis.WebMCPRuntime, undefined, 'opted-out manifest: keep waiting');
  doc.element.hasAttribute = name => name === 'data-webmcp-autostart';
  doc.dispatchEvent(new Event('turbo:load'));
  await globalThis.WebMCPRuntime.handle.refresh();
  assert.equal(events, 1);
  assert.equal(doc.modelContext.calls.length, 1);
  const handle = globalThis.WebMCPRuntime.handle;
  doc.dispatchEvent(new Event('turbo:load'));
  await handle.refresh();
  assert.equal(events, 1, 'the bootstrap listener was removed after starting');
  assert.equal(globalThis.WebMCPRuntime.handle, handle);
});

test('Node module evaluation without a document does not autostart', async t => {
  setGlobal(t, 'document', undefined);
  setGlobal(t, 'WebMCPRuntime', undefined);
  setGlobal(t, Symbol.for('webmcp.runtime.autostart'), undefined);
  await importAutostart('node');
  assert.equal(globalThis.WebMCPRuntime, undefined);
  assert.equal(globalThis[Symbol.for('webmcp.runtime.autostart')], undefined);
});
