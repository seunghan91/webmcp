# frozen_string_literal: true

module WebMCP
  class Projection
    def initialize(source, fingerprint)
      @source = source
      @metadata = Testing.source_metadata(source)
      @fingerprint = Value.fingerprint(@metadata)
      unless fingerprint == @fingerprint
        raise DefinitionError, "source_fingerprint is missing or stale; current source_fingerprint: #{@fingerprint}"
      end
      @overrides = {}
      @renames = {}
      @notes = []
    end

    def rename_params(**map)
      @renames.merge!(Value.normalize(map))
    end

    def input_schema(&block)
      raise DefinitionError, "input_schema requires a projection block" unless block
      @schema_block = block
      @notes << "input_schema override"
    end

    %i[name title description max_response_chars].each do |field|
      define_method(field) do |value|
        @overrides[field] = value
        @notes << "#{field} override"
      end
    end

    def annotations(**values)
      @overrides[:annotations] = values
      @notes << "annotations explicitly declared"
    end

    def endpoint(**values)
      @overrides[:endpoint] = values
      @notes << "endpoint override"
    end

    def build(&block)
      instance_eval(&block) if block
      raise DefinitionError, "from_mcp requires an explicit annotations declaration (MCP hints are not inherited)" unless @overrides.key?(:annotations)
      raise DefinitionError, "from_mcp requires an endpoint declaration" unless @overrides.key?(:endpoint)
      schema = Value.normalize(@metadata["inputSchema"])
      unless @renames.empty?
        Schema.validate!(schema)
        properties = schema.fetch("properties", {})
        @renames.each do |old, replacement|
          raise DefinitionError, "rename_params source is not a property: #{old}" unless properties.key?(old)
          unless replacement.is_a?(String) && !replacement.empty?
            raise DefinitionError, "rename_params destination must be a nonempty name"
          end
        end
        names = properties.keys.map { |key| @renames.fetch(key, key) }
        raise DefinitionError, "rename_params destinations collide" unless names.uniq == names
        schema["properties"] = properties.to_h { |key, value| [@renames.fetch(key, key), value] }
        schema["required"] = schema["required"].map { |key| @renames.fetch(key, key) } if schema.key?("required")
        @renames.each { |old, replacement| @notes << "rename parameter #{old} -> #{replacement}" }
      end
      schema = @schema_block.call(schema) if @schema_block
      Tool.new(name: @metadata["name"], title: @metadata["title"], description: @metadata["description"],
               input_schema: schema, **@overrides, projection_notes: @notes,
               source_fingerprint: @fingerprint, source: @source)
    end
  end
end
