# Changelog

## Unreleased

- Documentation for people and AI agents: `AGENTS.md`, `llms.txt`, a README troubleshooting table with exact error messages, and changelog/issue/documentation links in the gemspec.

## 0.1.0

- Autostart opted-in manifests from the external runtime under strict CSP, expose
  `WebMCPRuntime.handle`, and emit `webmcp:mounted`; support `autostart: false`.
- Add explicit Rails 8/Turbo/Chrome integration and built-gem production asset
  smoke tasks. All 9 browser checks pass on Chrome 154.0.8037.98 with Rails 8.1
  and 8.0. Chrome 154 accepts only legacy JSON-string `executeTool` input (object
  input ships in 155), so the agent-side test helper falls back to it;
  `WEBMCP_STRICT_OBJECT_INPUT=1` runs the object-only gate.

- Add immutable validated tool definitions and explicit MCP metadata projections,
  source drift checks, and canonical effective-contract fingerprints.
- Add a boot-time registry, manifest v1 rendering, safe JSON script embedding and
  language-neutral conformance fixtures.
- Add optional Rails 7.1+ page opt-in helpers, declarative form attributes that
  preserve custom builders, CSP nonce handling, and runtime asset synchronization.
- Add standalone Rack Origin-Trial middleware and escaped meta tags, preserving
  existing headers and warning once about legacy OAC opt-out behavior.
- Pin the implementation contract to Draft CG Report 2026-10-02; browser and
  production-asset release gates remain separate from Ruby unit verification.

## 0.0.1

- Initial gem skeleton.
