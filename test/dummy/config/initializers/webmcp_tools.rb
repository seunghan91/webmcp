require "mcp"

ItemsSource = MCP::Tool.define(
  name: "items_read", title: "Read items", description: "Read items matching tags.",
  input_schema: { type: "object", properties: { tags: { type: "array", items: { type: "string" } } } },
  annotations: { read_only_hint: true }
) { |**| raise "The browser must call the HTTP endpoint, never the MCP implementation" }

WebMCP.register(WebMCP::Tool.from_mcp(
  ItemsSource, source_fingerprint: "sha256:9bc087df7de80b13b999d091467862602a2177d58bb048d764cbf1d891e179cf"
) do
  input_schema { |schema| schema.reject { |key, _| key == "$schema" } }
  annotations read_only: true, untrusted_content: true
  endpoint path: "/api/items", method: :get
end)

[
  ["items_create", "Create item", "/api/items", :post, { title: { type: "string" } }],
  ["redirect_read", "Read redirect", "/api/redirect", :get, {}],
  ["redirect_write", "Write redirect", "/api/redirect_write", :post, {}],
  ["boom", "Server error", "/api/boom", :get, {}],
  ["string_tool", "String response", "/api/string", :get, {}]
].each do |name, title, path, method, properties|
  WebMCP.register(WebMCP::Tool.define(
    name: name, title: title, description: "Exercise #{name} through HTTP.",
    input_schema: { type: "object", properties: properties },
    annotations: method == :get ? { read_only: true } : { consequential: true },
    endpoint: { path: path, method: method }
  ))
end
