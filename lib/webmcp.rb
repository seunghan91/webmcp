# frozen_string_literal: true

require_relative "webmcp/version"

# WebMCP — Ruby/Rails toolkit for the W3C Web Model Context Protocol.
#
# Status: early development. The WebMCP spec is in Chrome origin trial
# (Chrome 149-156) and its surface is still moving; this gem tracks the
# spec and will ship its first usable release once the API stabilizes.
#
# Planned surface:
#   - Tool definitions in Ruby, shared between server-side MCP and WebMCP
#   - Declarative form attribute helpers (toolname/tooldescription/...)
#   - Rack middleware for serving the Origin-Trial token header
module WebMCP
end
