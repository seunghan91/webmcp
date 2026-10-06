# Manifest v1 conformance

Each JSON fixture has `definition` (snake_case public API inputs), `transport`
(camelCase manifest transport), and `expected` (one manifest tool entry).
Compare parsed JSON values, not serialized key order. Fixtures are fixed inputs
and expected outputs; tests must not regenerate expected output using the code
under test. The initial expected fingerprints were calculated independently with
Python's sorted, compact, UTF-8 JSON serialization and SHA-256.

Fingerprint preimages:

- Effective tool: the tool entry without `fingerprint`, with an added `transport`
  member containing the manifest transport. Hash recursively sorted keys,
  compact JSON, UTF-8, with no HTML escaping, then prefix the hex digest `sha256:`.
- MCP source: select the keys actually present in `to_h` from `name`, `title`,
  `description`, `inputSchema`, then canonicalize as above. Absent optional keys
  are omitted; explicit null values are retained. MCP annotations are excluded.
- Only integer metadata numbers within +/-2^53 are allowed. Array order is
  significant. Empty `paramMap` and absent optional fields are omitted. Empty
  `annotations` is retained. Ruby GET arrays emit `arrayFormat: "brackets"`.

`projection-result.json` describes the effective definition after renaming
`content` to `title`, reducing `limit.maximum` from 500 to 20, and setting an
explicit endpoint map back to `content`. It can be consumed by languages without
an MCP SDK bridge.

`rake webmcp:sync_runtime` copies the separately maintained canonical runtime into
Rails assets and writes `RUNTIME.sha256` in sha256sum format. It never edits the
canonical source. Re-run after runtime changes, before packaging.
