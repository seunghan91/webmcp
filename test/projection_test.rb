# frozen_string_literal: true
require_relative "test_helper"
require "mcp"

class ProjectionTest < Minitest::Test
  def test_projection_order_overrides_and_notes
    source = fake_source
    projection = project(source) do
      input_schema do |schema|
        raise "rename must happen first" unless schema["required"] == ["title"]
        schema["properties"]["limit"]["maximum"] = 20
        schema
      end
      rename_params content: :title
      annotations read_only: true, untrusted_content: true
      endpoint path: "/tasks", method: :get, param_map: { title: :content }
      name "browser_tasks"
      title "Browser tasks"
      description "At most twenty tasks"
      max_response_chars 1500
    end
    assert_equal "browser_tasks", projection.name
    assert_equal "Browser tasks", projection.title
    assert_equal "At most twenty tasks", projection.description
    assert_equal 1500, projection.max_response_chars
    assert_equal 20, projection.input_schema["properties"]["limit"]["maximum"]
    assert_equal ["title"], projection.input_schema["required"]
    assert_equal ["content"], source.to_h[:inputSchema][:required]
    assert projection.projection_notes.any? { |note| note.include?("content -> title") }
    refute projection.to_manifest_entry({}).key?("projection_notes")
    assert WebMCP::Testing.assert_projection_fresh(projection)
    source.metadata[:description] = "Changed upstream"
    assert_raises(WebMCP::DefinitionError) { WebMCP::Testing.assert_projection_fresh(projection) }
  end

  def test_required_fingerprint_and_annotation_declaration
    source = fake_source
    current = WebMCP::Testing.current_source_fingerprint(source)
    [nil, "sha256:old"].each do |fingerprint|
      error = assert_raises(WebMCP::DefinitionError) { WebMCP::Tool.from_mcp(source, source_fingerprint: fingerprint) }
      assert_includes error.message, current
    end
    assert_raises(WebMCP::DefinitionError) { project(source) { endpoint path: "/tasks", method: :get } }
    assert_raises(WebMCP::DefinitionError) { project(source) { annotations read_only: true } }
    projection = project(source) do
      annotations
      endpoint path: "/tasks", method: :post
    end
    assert_empty projection.annotations
    assert_equal "Tasks", projection.title
    source.metadata[:annotations] = { consequentialHint: true }
    assert WebMCP::Testing.assert_projection_fresh(projection)
  end

  def test_projection_matches_the_language_neutral_result_fixture
    fixture = JSON.parse(File.read(File.expand_path("../conformance/fixtures/projection-result.json", __dir__)))
    projection = project(fake_source) do
      rename_params content: :title
      input_schema do |schema|
        schema["properties"]["limit"]["maximum"] = 20
        schema
      end
      name "search_tasks"
      title "Search tasks"
      description "Search at most 20 tasks."
      annotations read_only: true
      endpoint path: "/api/search", method: :post, param_map: { title: :content }
      max_response_chars 1500
    end
    assert_equal fixture["expected"], projection.to_manifest_entry(fixture["transport"])
  end

  def test_rename_collisions_unknown_names_and_subset_gate
    [{ content: :limit }, { content: :x, limit: :x }, { missing: :x }].each do |map|
      assert_raises(WebMCP::DefinitionError) do
        project(fake_source) do
          rename_params(**map)
          annotations read_only: true
          endpoint path: "/tasks", method: :get
        end
      end
    end
    source = fake_source
    source.metadata[:inputSchema][:additionalProperties] = false
    assert_raises(WebMCP::DefinitionError) do
      project(source) do
        rename_params content: :title
        input_schema { |schema| schema.reject { |key, _| key == "additionalProperties" } }
        annotations read_only: true
        endpoint path: "/tasks", method: :get
      end
    end
    # A full explicit schema override is allowed when no rename is requested.
    assert project(source) {
      input_schema { |_| { type: "object" } }
      annotations read_only: true
      endpoint path: "/tasks", method: :get
    }
  end

  def test_real_mcp_tool_define_and_subclass
    source = MCP::Tool.define(name: "sdk_tasks", title: "SDK tasks", description: "Find tasks",
                              input_schema: { type: "object", properties: { query: { type: "string" } } },
                              annotations: { read_only_hint: true }) { |**| nil }
    subclass = Class.new(MCP::Tool) do
      tool_name "subclass_tasks"
      description "Subclass tasks"
      input_schema type: "object", properties: {}
    end
    [source, subclass].each do |sdk_tool|
      projection = project(sdk_tool) do
        # The SDK adds a dialect declaration outside the 0.x browser subset.
        input_schema { |schema| schema.reject { |key, _| key == "$schema" } }
        annotations read_only: true
        endpoint path: "/tasks", method: :get
      end
      assert_equal sdk_tool.to_h[:name], projection.name
      assert WebMCP::Testing.assert_projection_fresh(projection)
      refute sdk_tool.frozen?
    end
  end
end
