# frozen_string_literal: true

module WebMCP
  class Registry
    def initialize
      @tools = {}
    end

    def register(tool)
      raise DefinitionError, "registry is frozen" if frozen?
      raise DefinitionError, "expected a WebMCP::Tool" unless tool.is_a?(Tool)
      raise DefinitionError, "duplicate tool name: #{tool.name}" if @tools.key?(tool.name)
      @tools[tool.name] = tool
      tool
    end

    def fetch(name)
      @tools.fetch(name.to_s) { raise DefinitionError, "unknown tool name: #{name}" }
    end

    def tools
      @tools.values.freeze
    end

    def freeze!
      @tools.freeze
      freeze
    end
  end
end
