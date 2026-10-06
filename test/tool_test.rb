# frozen_string_literal: true
require_relative "test_helper"
require "rack/utils"

class ToolTest < Minitest::Test
  def test_names_and_chrome_budget_warnings
    ["", "a" * 129, "a b", "é", "a\n", "a/b"].each do |name|
      assert_raises(WebMCP::DefinitionError) { tool(name: name) }
    end
    log = StringIO.new
    old_logger = WebMCP.config.logger
    WebMCP.config.logger = Logger.new(log)
    assert_equal "A_1.-", tool(name: "A_1.-").name
    assert_equal 128, tool(name: "a" * 128, description: "x" * 501).name.length
    assert_includes log.string, "30-character"
    assert_includes log.string, "500-character"
  ensure
    WebMCP.config.logger = old_logger if old_logger
  end

  def test_descriptions_annotations_and_response_limit
    [nil, "", 1].each { |v| assert_raises(WebMCP::DefinitionError) { tool(description: v) } }
    error = assert_raises(WebMCP::DefinitionError) { tool(annotations: { destructive: true }) }
    assert_includes error.message, "MCP and WebMCP annotation sets differ"
    assert_raises(WebMCP::DefinitionError) { tool(annotations: { read_only: "true" }) }
    assert_raises(WebMCP::DefinitionError) { tool(annotations: {}) }
    assert_raises(WebMCP::DefinitionError) { tool(annotations: { read_only: false }) }
    assert tool(endpoint: { path: "/search", method: :post })
    assert tool(endpoint: { path: "/write", method: :post }, annotations: {})
    [0, -1, 1.5, 2**53 + 1].each { |v| assert_raises(WebMCP::DefinitionError) { tool(max_response_chars: v) } }
    entry = tool(annotations: { read_only: true, debugging: false }).to_manifest_entry({})
    assert_equal({ "readOnlyHint" => true }, entry["annotations"])
    %w[title maxResponseChars projection_notes].each { |key| refute entry.key?(key) }
    refute entry["endpoint"].key?("paramMap")
  end

  def test_endpoint_path_and_method_rules
    ["//x", "\\x", "/\\x", "http://x", "/a\nb", "/a\x00", "/a\x7f", "/http:x", "tasks"].each do |path|
      assert_raises(WebMCP::DefinitionError, path.inspect) { tool(endpoint: { path: path, method: :get }) }
    end
    assert_raises(WebMCP::DefinitionError) { tool(endpoint: { path: "/x", method: :head }) }
    %i[get post patch put delete].each { |method| assert tool(endpoint: { path: "/x?q=a", method: method }) }
  end

  def test_param_map_and_collisions_with_unmapped_fields
    %w[_method authenticity_token csrfmiddlewaretoken constructor prototype __proto__ a-b 1a].each do |dest|
      assert_raises(WebMCP::DefinitionError) { tool(endpoint: { path: "/x", method: :get, param_map: { query: dest } }) }
    end
    assert_raises(WebMCP::DefinitionError) { tool(endpoint: { path: "/x", method: :get, param_map: { missing: :q } }) }
    schema = { type: "object", properties: { a: { type: "string" }, b: { type: "string" } } }
    [{ a: :b }, { a: :c, b: :c }].each do |map|
      assert_raises(WebMCP::DefinitionError) { tool(input_schema: schema, endpoint: { path: "/x", method: :get, param_map: map }) }
    end
    entry = tool(endpoint: { path: "/x", method: :get, param_map: { query: :search } }).to_manifest_entry({})
    assert_equal({ "query" => "search" }, entry["endpoint"]["paramMap"])
  end

  def test_input_subset
    [{ type: "array" }, { type: "object", additionalProperties: false }, { type: "object", allOf: [] },
     { type: "object", required: ["missing"] }, { type: "object", properties: [] }].each do |schema|
      assert_raises(WebMCP::DefinitionError) { tool(input_schema: schema) }
    end
    [{ type: "object" }, { type: "string", pattern: "x" }, { "$ref" => "#/x" },
     { type: ["string", "null"] }, { type: "array", items: { type: "array", items: { type: "string" } } },
     { type: "array", items: { type: "object" } }, { type: "string", default: 3 },
     { type: "integer", maximum: 2.1 }, { type: "integer", maximum: 2**53 + 1 }].each do |property|
      assert_raises(WebMCP::DefinitionError) { tool(input_schema: { type: "object", properties: { x: property } }) }
    end
    %w[__proto__ constructor prototype].each do |name|
      assert_raises(WebMCP::DefinitionError) { tool(input_schema: { type: "object", properties: { name => { type: "string" } } }) }
    end
    assert tool(input_schema: { type: "object" })
    assert tool(input_schema: { type: "object", properties: {
      q: { type: "string", enum: ["a", "b"], default: "a", maxLength: 4, description: "Query" },
      limit: { type: "integer", minimum: 1, maximum: 20 }, enabled: { type: "boolean", default: false }
    }, required: ["q"] })
  end

  def test_malformed_metadata_fails_as_a_definition_error
    cyclic = { type: "object" }
    cyclic[:properties] = cyclic
    assert_raises(WebMCP::DefinitionError) { tool(input_schema: cyclic) }
    assert_raises(WebMCP::DefinitionError) { tool(description: "\xff".b.force_encoding("UTF-8")) }
    assert_raises(WebMCP::DefinitionError) { tool(input_schema: { type: "object", "type" => "object" }) }
  end

  def test_array_format_and_rack_round_trip
    schema = { type: "object", properties: { tags: { type: "array", items: { type: "string" }, maxItems: 4 } } }
    entry = tool(input_schema: schema).to_manifest_entry({})
    assert_equal "brackets", entry["endpoint"]["arrayFormat"]
    assert_equal ["a", "b"], Rack::Utils.parse_nested_query("tags%5B%5D=a&tags%5B%5D=b")["tags"]
    assert_equal "repeat", tool(input_schema: schema, endpoint: { path: "/x", method: :get, array_format: :repeat }).to_manifest_entry({})["endpoint"]["arrayFormat"]
    refute tool(input_schema: schema, endpoint: { path: "/x", method: :post }).to_manifest_entry({})["endpoint"].key?("arrayFormat")
    assert_raises(WebMCP::DefinitionError) { tool(endpoint: { path: "/x", method: :get, array_format: :csv }) }
  end

  def test_deep_immutability_without_freezing_callers_and_fingerprint_stability
    original = definition
    value = WebMCP::Tool.define(**original)
    assert value.frozen?
    assert_raises(FrozenError) { value.input_schema["properties"]["query"]["type"].replace("number") }
    original[:input_schema][:properties][:query][:type] = "integer"
    assert_equal "string", value.input_schema["properties"]["query"]["type"]
    a = value.to_manifest_entry({})
    b = WebMCP::Tool.define(**definition.to_a.reverse.to_h).to_manifest_entry({})
    assert_equal a["fingerprint"], b["fingerprint"]
    assert_equal WebMCP::Value.fingerprint({ a: { c: 2, b: 1 } }), WebMCP::Value.fingerprint({ "a" => { "b" => 1, "c" => 2 } })
    a["inputSchema"]["type"] = "changed"
    assert_equal "object", value.input_schema["type"]
    refute_equal b["fingerprint"], value.to_manifest_entry(csrf: { source: :meta, name: "token", header: "X-CSRF" })["fingerprint"]
    refute_equal b["fingerprint"], tool(endpoint: { path: "/different", method: :get }).to_manifest_entry({})["fingerprint"]
  end
end
