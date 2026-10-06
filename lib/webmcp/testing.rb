# frozen_string_literal: true

module WebMCP
  module Testing
    module_function

    def source_metadata(source)
      raise DefinitionError, "MCP tool must respond to to_h" unless source.respond_to?(:to_h)
      raw = source.to_h
      Value.hash!(raw, "MCP tool metadata")
      # Ignore MCP annotations (and other unrelated metadata) even for hashing.
      selected = raw.select { |key, _| %w[name title description inputSchema].include?(key.to_s) }
      Value.normalize(selected)
    end

    def current_source_fingerprint(source)
      Value.fingerprint(source_metadata(source))
    end

    def assert_projection_fresh(tool)
      raise DefinitionError, "tool is not an MCP projection" unless tool.source
      current = current_source_fingerprint(tool.source)
      unless tool.source_fingerprint == current
        raise DefinitionError, "MCP projection #{tool.name} is stale; current source_fingerprint: #{current}"
      end
      true
    end
  end
end
