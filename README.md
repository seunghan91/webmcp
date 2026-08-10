# webmcp

Ruby/Rails toolkit for [WebMCP](https://github.com/webmachinelearning/webmcp) —
the W3C proposal that lets web pages declare structured tools for AI agents
(`document.modelContext`).

**Status: early development.** The WebMCP spec is in Chrome origin trial
(Chrome 149–156) and its API surface has already changed twice. This gem is
being extracted from a production integration and will ship its first usable
release once the spec surface stabilizes.

Planned:

- Define tools once in Ruby; emit both server-side MCP schemas and WebMCP
  registration payloads
- Declarative helpers: `form_with ..., webmcp:` → `toolname` /
  `tooldescription` / `toolparamdescription` attributes
- Rack middleware for the `Origin-Trial` token header

## License

MIT
