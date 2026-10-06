# webmcp

[![Gem Version](https://img.shields.io/gem/v/webmcp)](https://rubygems.org/gems/webmcp) [![CI](https://github.com/seunghan91/webmcp/actions/workflows/ci.yml/badge.svg)](https://github.com/seunghan91/webmcp/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.txt)

Server-side WebMCP toolkit for Ruby and Rails — the reference implementation of the family.

[WebMCP](https://github.com/webmachinelearning/webmcp) is a W3C Community Group
proposal that lets a web page register tools an in-browser AI agent can call
through `document.modelContext`. This gem is the server side of that: you define
tools where your app already knows its routes, sessions and permissions, and a
small browser runtime registers them on the pages you choose. When an agent calls
a tool, the runtime calls your existing same-origin endpoint with the user's
session and CSRF token, so authentication and authorization stay in your app.

- **Tool definitions** — `WebMCP::Tool.define`, validated against the spec's naming, annotation and schema rules at boot.
- **Projection from MCP SDK tools** — `WebMCP::Tool.from_mcp` reuses a tool's identity from the official [`mcp`](https://rubygems.org/gems/mcp) gem and makes every browser-side difference explicit, with a pinned source fingerprint that fails tests when the MCP tool drifts.
- **Rails helpers** — `webmcp_manifest_tag` (per-page opt-in), `webmcp_runtime_tag` (CSP nonce aware, autostart), `form_with ..., webmcp: {...}` for declarative forms (keeps custom FormBuilders).
- **Origin Trial** — `WebMCP::OriginTrial` Rack middleware and `webmcp_origin_trial_meta_tag`.
- **Shared browser runtime** — zero dependencies; same-origin only, `redirect: 'error'`, CSRF read per call, declared parameters only, read/write outcome envelopes, no retries.

```ruby
# Gemfile
gem "webmcp", "~> 0.1"
```

**Status:** 0.x, tracking the WebMCP Draft CG Report of 2026-10-02. WebMCP runs
behind a Chrome origin trial (Chrome 149–156, extension requested to 162) or the
`chrome://flags/#enable-webmcp-testing` flag. The shared runtime is tested in real
Chrome 154 by the [Ruby reference suite](https://github.com/seunghan91/webmcp/blob/main/test/integration/RESULTS.md)
(CSRF-protected writes, blocked redirects, HTTP errors, Turbo navigation, strict CSP).

| Language | Package | Registry |
|---|---|---|
| Ruby / Rails (reference) | [`webmcp`](https://github.com/seunghan91/webmcp) | [RubyGems](https://rubygems.org/gems/webmcp) |
| Go (`net/http`) | [`webmcp-go`](https://github.com/seunghan91/webmcp-go) | [pkg.go.dev](https://pkg.go.dev/github.com/seunghan91/webmcp-go) |
| Python / Django | [`webmcp-django`](https://github.com/seunghan91/webmcp-django) | [PyPI](https://pypi.org/project/webmcp-django/) |
| Rust | [`webmcp`](https://github.com/seunghan91/webmcp-rust) | [crates.io](https://crates.io/crates/webmcp) |

All four emit the same manifest v1 (checked against shared conformance fixtures,
fingerprints included) and ship the byte-identical browser runtime.

## Intent: share identity, project the rest explicitly

**Surfaces are intentionally different; share identity, project the rest explicitly.**
A server MCP tool and its browser counterpart can represent the same feature
while intentionally having different schemas, limits, and execution paths.

| Difference | Server MCP | Browser WebMCP | Reason |
|---|---|---|---|
| Field names | `content`, `id` | `title`, `task_id` | Browser agents benefit from names matching visible labels. |
| Dates | ISO 8601 | `YYYY-MM-DD HH:MM` in the user's timezone | Match what the user sees. |
| Result limit | 500 | 20 | Keep results useful within the browser's response budget and tab context. |
| Execution path | Service object → database | Session cookies → existing web endpoint | Preserve session, CSRF and authorization checks. |

Identity and descriptions can start from one source. Schema changes, annotations,
limits and endpoints are explicit projections. MCP and WebMCP annotations are
different sets: `destructiveHint` does not automatically mean `consequentialHint`.
Even `readOnlyHint` must be declared again for the browser endpoint.

## Quick start

Ruby >= 3.1; no runtime gem dependencies. Rails >= 7.1 and the `mcp` gem >= 1.1
are optional. Add `gem "webmcp", "~> 0.1.0"` to your Gemfile.

```ruby
require "webmcp"

ListTasks = WebMCP::Tool.define(
  name: "list_tasks",
  title: "List tasks",
  description: "List at most 20 tasks for the signed-in user.",
  input_schema: {
    type: "object",
    properties: {
      tags: { type: "array", items: { type: "string" } },
      completed: { type: "boolean" }
    }
  },
  annotations: { read_only: true, untrusted_content: true },
  endpoint: { path: "/api/tasks", method: :get },
  max_response_chars: 1500
)
WebMCP.register(ListTasks)
```

Definitions are deeply frozen copies. Duplicate names fail. Rails freezes the
registry after initialization; in a Rack application call `WebMCP.freeze!` after
registering tools at boot. `WebMCP.tools` returns a frozen list.

### Project an existing MCP tool

First obtain the source fingerprint in a console:

```ruby
WebMCP::Testing.current_source_fingerprint(McpTools::ListTasks)
# => "sha256:..."
```

Paste that literal into the checked-in definition. Do not compute it dynamically
at boot: that would erase the drift baseline.

```ruby
ListTasksBrowser = WebMCP::Tool.from_mcp(
  McpTools::ListTasks,
  source_fingerprint: "sha256:PASTE_THE_REVIEWED_SOURCE_FINGERPRINT_HERE"
) do
  # For a source already in the 0.x subset, rename only top-level properties.
  rename_params content: :title, id: :task_id
  input_schema do |schema| # String keys; already renamed, including required.
    schema["properties"]["limit"]["maximum"] = 20
    schema
  end
  annotations read_only: true, untrusted_content: true
  endpoint path: "/api/tasks", method: :get, param_map: { title: :content }
  max_response_chars 1500
end
WebMCP.register(ListTasksBrowser)
WebMCP::Testing.assert_projection_fresh(ListTasksBrowser)
```

Missing or stale fingerprints raise `WebMCP::DefinitionError` with the current
value. Tests can call `assert_projection_fresh` to detect later source changes.
`projection_notes` describes renames and overrides for debugging and never
appears in the manifest. Override `name`, `title`, `description` or
`max_response_chars` in the block as needed. No MCP annotations are inherited;
even a write projection must call `annotations` explicitly (an empty call is valid).

The official MCP SDK adds a `$schema` dialect declaration. That keyword is outside
this toolkit's deliberately strict 0.x subset. For an SDK schema, use an explicit
schema projection; do not use `rename_params` on an out-of-subset source:

```ruby
# Source can be an MCP::Tool subclass or the class returned by MCP::Tool.define.
BrowserSearch = WebMCP::Tool.from_mcp(
  McpTools::Search,
  source_fingerprint: "sha256:PASTE_THE_REVIEWED_SOURCE_FINGERPRINT_HERE"
) do
  input_schema do |schema|
    schema = schema.reject { |key, _| key == "$schema" }
    # If needed, explicitly replace the schema here, including required names.
    schema
  end
  annotations read_only: true
  endpoint path: "/api/search", method: :post
end
```

The bridge duck-types `to_h`; it never requires the MCP SDK or invokes its tools.
The source fingerprint includes the original schema, including `$schema`.

### Rails views: opt in on each page

```erb
<%= csrf_meta_tags %>
<%= webmcp_manifest_tag(:list_tasks) %>
<%= webmcp_runtime_tag %>
```

Only listed tools are exposed. With no names the manifest contains no tools;
unknown names fail. Rails transport defaults to meta `csrf-token`, header
`X-CSRF-Token`. Both script helpers include `content_security_policy_nonce` when
available. The runtime tag references the external module `webmcp/runtime.js`;
it contains no inline executable JavaScript.

These two helpers are sufficient: the manifest includes `data-webmcp-autostart`
by default, and the external module calls `mount()` once when the document is
ready. No inline bootstrap script is needed. The handle is exposed as
`WebMCPRuntime.handle`, and the document receives a `webmcp:mounted` event whose
`detail` is that handle. Registration is asynchronous; `await handle.refresh()`
waits for reconciliation when you need it.

For Inertia or another SPA, put the following in your existing external entry:

```javascript
// Call after navigation has replaced #webmcp-manifest:
await globalThis.WebMCPRuntime.handle.refresh();

// Install this listener before loading the runtime if you need the initial handle:
document.addEventListener("webmcp:mounted", ({ detail: handle }) => {
  // Keep the handle for refresh() and dispose().
}, { once: true });
```

For manual ownership, use `webmcp_manifest_tag(:list_tasks, autostart: false)`.
Pin `"webmcp/runtime"` to `"webmcp/runtime.js"` in `config/importmap.rb`, then call
`mount()` from your external entry:

```javascript
import { mount } from "webmcp/runtime";
const handle = mount({ selector: "#webmcp-manifest" });
```

For Vite/esbuild, import the copied canonical module from your source tree.
Plain Ruby supports the same opt-out with
`WebMCP::Manifest.to_script_tag(manifest, autostart: false)`.

```erb
<%= form_with url: "/tasks", builder: MyFormBuilder,
      webmcp: { tool: "create_task", description: "Create a task", autosubmit: false } do |f| %>
  <%= f.text_field :title, webmcp: { param_description: "Task title" } %>
  <%= f.select :priority, ["normal", "high"], webmcp: { param_description: "Priority" } %>
  <%= f.submit "Create" %>
<% end %>
```

Custom `builder:` and `default_form_builder` are preserved. Helpers prepend
option processing onto the existing FormBuilder and FormTagHelper; no replacement
builder is installed. `form_tag` and field tag helpers also accept `webmcp:`.
Only `toolname`, `tooldescription`, `toolautosubmit`, and `toolparamdescription`
are generated; `param_title` is rejected. Attribute values are escaped even if
originally marked `html_safe`.

### Origin Trial

```ruby
# Rails application configuration, or ENV["WEBMCP_ORIGIN_TRIAL_TOKEN"]:
config.webmcp.origin_trial_token = "YOUR_ORIGIN_TRIAL_TOKEN"

# Rack, without Rails:
use WebMCP::OriginTrial, token: ENV["WEBMCP_ORIGIN_TRIAL_TOKEN"]
```

```erb
<%= webmcp_origin_trial_meta_tag %>
```

For plain Ruby, `WebMCP::OriginTrial.meta_tag(token)` returns escaped markup.
The middleware only fills a missing `Origin-Trial` header, preserving even an
existing empty header. An empty token is a no-op. `warn_on_oac_opt_out: true`
logs once per middleware instance when `Origin-Agent-Cluster: ?0` is observed;
it never rewrites that header. Supply `logger:` or set `WebMCP.config.logger`.
Rack 3 receives lowercase response header names.

### Plain Ruby manifests and runtime assets

```ruby
manifest = WebMCP::Manifest.build([ListTasks], transport: {})
html = WebMCP::Manifest.to_script_tag(manifest, nonce: "YOUR_CSP_NONCE")
# Writes need CSRF transport, for example:
transport = { csrf: { source: "meta", name: "csrf-token", header: "X-CSRF-Token" } }
```

Manifests use version 1 and camelCase JSON keys. Empty `paramMap`, absent `title`
and absent `maxResponseChars` are omitted; annotations contain only true keys.
Fingerprints cover the effective tool entry plus `transport`. See
[conformance/README.md](conformance/README.md) for the exact canonical preimages
and cross-language fixtures.

Before packaging a checkout, synchronize the canonical runtime:

```sh
bundle exec rake webmcp:sync_runtime
```

This copies `runtime/webmcp-runtime.js` into
`app/assets/javascripts/webmcp/runtime.js` and records `conformance/RUNTIME.sha256`.
The Railtie adds asset paths and, for Sprockets, a precompile entry. Other asset
pipelines can copy the canonical module directly. Do not edit the generated copy.

## Security model

The server remains the security boundary. Tools call existing same-origin
endpoints with the current session; those endpoints must enforce authorization,
CSRF, input validation, range limits and result caps. A schema `maximum` is
metadata, not server enforcement. Annotations are hints, not security controls.

- Endpoint paths must begin with `/`; protocol-relative URLs, backslashes, colons
  and control characters are rejected. The runtime also checks the resolved
  origin and uses same-origin mode/credentials with redirects rejected.
- GET requires `read_only: true`; read-only POST is allowed. Other methods need a
  CSRF token read at invocation time. Missing tokens stop the request.
- Only declared input keys are sent. Prototype-related keys are rejected.
  Explicit `param_map` destinations cannot collide or target reserved transport
  fields such as `_method`, `authenticity_token`, or `csrfmiddlewaretoken`.
- JSON embedding escapes `<`, `>`, `&`, U+2028 and U+2029. This prevents script
  breakout, including mixed-case closing tags and HTML comments. Nonces and HTML
  attributes are independently escaped.
- The runtime returns structured success/error envelopes and never retries.
  An ambiguous write result is `unknown_outcome`: verify with the user before
  retrying. A successful write with unreadable/oversized output stays successful
  with `dataOmitted`; an oversized read returns `response_too_large`. Responses
  are never silently truncated.
- Write endpoints should answer in JSON, including their error paths. A write
  tool that receives a 2xx non-JSON body (for example, a 200 HTML sign-in page
  after a session expired) reports `ok: true` with `dataOmitted: "invalid_response"`
  by contract. Return 401/403 JSON instead of rendering a page.

**Tool metadata is agent-visible, not just display text.** An AI agent reads
`tooldescription` / `toolparamdescription` as part of its instructions for what
the tool does. Do not build these strings from unvalidated user input (profile
fields, query params, uploaded file names, etc.); a user-controlled value rendered
into tool metadata is a prompt-injection vector that can hijack the agent's
behavior. Keep tool names and descriptions as literal strings you write, not
values derived at request time from data a visitor controls. Define tools at boot
and freeze the registry; HTML escaping alone does not prevent prompt injection.

## Comparison

This comparison follows the reviewed 0.1.0 versions, not a claim about future releases.

| Library | Focus | Relationship |
|---|---|---|
| `webmcp-rails` 0.1.0 | Declarative `form_with webmcp:` attributes | This API shape informed our helpers. This gem preserves custom builders and does not emit the non-spec `toolparamtitle`. |
| `active_webmcp` 0.1.0 | Controller actions exposed as page-selected tools; Rails 8.1, importmap and Propshaft | Closest alternative. We also use page opt-in, and add explicit MCP projection, declarative forms, OT helpers, a standalone Rack/Ruby core and shared manifest fixtures. Its controller-centric integration may fit apps that do not need projection. |

## Limitations and validation

- Declarative form attributes are wired into `form_with` (which `form_for`
  delegates to on Rails 7.1+), `form_tag` and the field/`FormBuilder` helpers.

This is a 0.x subset, not a general JSON Schema rewriting engine. Root schemas
allow `type: "object"`, `properties`, `required`, and `description`. Properties
are `string`, `number`, `integer`, `boolean`, or arrays of those scalar types.
Property metadata supports `enum`, `description`, `default`, `minimum`, `maximum`,
`maxLength`, and `maxItems`. Nested objects/arrays, `$ref`, composition and other
keywords are rejected. Metadata numbers must be integers within +/-2^53; floats
are not accepted. `number` inputs may still be fractional at runtime. Enum,
bounds and lengths must be enforced by the endpoint.

`rename_params` accepts only subset sources, runs before the schema block, and
updates `required`; collision checks include unchanged names. The schema block
receives a mutable copy with string keys. GET arrays explicitly emit
`arrayFormat: "brackets"` by default (`tags[]=a&tags[]=b`); use `:repeat` only for
endpoints that expect repeated unbracketed keys.

No cross-origin exposure, automatic response truncation, or Inertia adapter is
provided. The runtime's `mount({ selector })` returns `{ refresh(), dispose() }`.
For Inertia or another SPA, call `WebMCPRuntime.handle.refresh()` after replacing
the manifest; call `handle.dispose()` when the owner is removed. Turbo refresh is
handled by the runtime. Browser registration requires WebMCP support; unsupported
browsers are a no-op. The spec and Origin Trial can change.

```sh
bundle install
npm ci --prefix test/integration
node --test runtime/test/runtime.test.mjs
bundle exec rake test
bundle exec rake webmcp:sync_runtime
bundle exec rake test:integration
bundle exec rake test:package
```

The integration tasks require Ruby >= 3.2 for Rails 8, Node.js, and system Google
Chrome. The Ruby core still supports Ruby >= 3.1 without Rails. Node dependencies
are isolated under `test/integration`; `rake test` does not boot the dummy app.

The unit suite covers real MCP SDK projections, standalone core loading, Rails
helper/custom-builder behavior, Railtie hooks, independent manifest fixtures,
XSS vectors, Rack array parsing, middleware semantics, and autostart opt-out.
The runtime suite also covers browser autostart, repeated module evaluation and
DOMContentLoaded. `test:integration` exercises the real Rails/Turbo app with CSRF
protection and strict nonce-based CSP. It fails explicitly if WebMCP is missing.
`test:package` builds and unpacks the gem into a fresh temporary Rails app,
precompiles production assets, verifies the served runtime bytes, checks native
tool registration and CSP, and cleans up the temporary app.

On Chrome **154.0.8037.98** with `--enable-features=WebMCPTesting`, all 9 checks
pass on Rails 8.1 and 8.0: registration and annotations, bracket-array round-trip
through Rack, a CSRF-protected write, a missing CSRF token blocking the request,
read/write redirect outcomes, HTTP 500, Turbo tool-set replacement (including a
first page without a manifest and same-name re-registration), and zero CSP
violations. The packaged production app also passes.

Two Chrome 154 behaviours differ from the spec. It accepts only the legacy
JSON-string `executeTool` input (object input ships in Chrome 155), so the test
helper, which plays the agent, falls back to it; the runtime's `execute` receives
an object either way, and `WEBMCP_STRICT_OBJECT_INPUT=1` runs the object-only gate.
A tool that returns a plain string comes back as `hi`, without the JSON quotes the
spec's serialization step implies; the runtime always returns an envelope object.

See [the Lane C verification report](test/integration/RESULTS.md) for commands
and outputs.
