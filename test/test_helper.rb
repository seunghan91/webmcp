# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "webmcp"

module ToolExamples
  def definition(**overrides)
    { name: "find_tasks", description: "Find tasks", input_schema: { type: "object", properties: { query: { type: "string" } } },
      endpoint: { path: "/tasks", method: :get }, annotations: { read_only: true } }.merge(overrides)
  end

  def tool(**overrides)
    WebMCP::Tool.define(**definition(**overrides))
  end

  def fake_source(metadata = nil)
    metadata ||= { name: "source_tasks", title: "Tasks", description: "Search tasks", inputSchema: {
      type: "object", properties: { content: { type: "string" }, limit: { type: "integer", maximum: 500 } }, required: ["content"]
    }, annotations: { readOnlyHint: true, destructiveHint: true } }
    Class.new do
      singleton_class.attr_accessor :metadata
      define_singleton_method(:to_h) { self.metadata }
    end.tap { |source| source.metadata = metadata }
  end

  def project(source, &block)
    WebMCP::Tool.from_mcp(source, source_fingerprint: WebMCP::Testing.current_source_fingerprint(source), &block)
  end
end

class Minitest::Test
  include ToolExamples
end
