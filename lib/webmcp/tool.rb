# frozen_string_literal: true

module WebMCP
  class Tool
    ANNOTATIONS = { "read_only" => "readOnlyHint", "untrusted_content" => "untrustedContentHint",
                    "consequential" => "consequentialHint", "debugging" => "debugging" }.freeze
    METHODS = %w[GET POST PATCH PUT DELETE].freeze
    FORBIDDEN_PARAMS = %w[_method authenticity_token csrfmiddlewaretoken __proto__ constructor prototype].freeze
    attr_reader :name, :description, :input_schema, :endpoint, :annotations, :title,
                :max_response_chars, :projection_notes, :source_fingerprint, :source

    def self.define(**options)
      new(**options)
    end

    def self.from_mcp(source, source_fingerprint: nil, &block)
      Projection.new(source, source_fingerprint).build(&block)
    end

    def self.validate_name!(name)
      unless name.is_a?(String) && name.length.between?(1, 128) && /\A[A-Za-z0-9_.-]+\z/.match?(name)
        raise DefinitionError, "tool name must be 1..128 characters from A-Z, a-z, 0-9, _, . and -"
      end
      name
    end

    def initialize(name:, description:, input_schema:, endpoint:, annotations: {}, title: nil,
                   max_response_chars: nil, projection_notes: [], source_fingerprint: nil, source: nil)
      @name = Value.normalize(name)
      self.class.validate_name!(@name)
      @description = Value.normalize(description)
      unless @description.is_a?(String) && !@description.empty?
        raise DefinitionError, "description must be a nonempty string"
      end
      @title = Value.normalize(title)
      raise DefinitionError, "title must be a string" unless @title.nil? || @title.is_a?(String)
      @input_schema = Schema.validate!(Value.normalize(input_schema))
      @annotations = Value.normalize(annotations)
      Value.hash!(@annotations, "annotations")
      unless (@annotations.keys - ANNOTATIONS.keys).empty?
        raise DefinitionError, "MCP and WebMCP annotation sets differ; WebMCP accepts only #{ANNOTATIONS.keys.join(', ')}; MCP destructive/idempotent/openWorld hints are not mapped"
      end
      unless @annotations.values.all? { |v| v == true || v == false }
        raise DefinitionError, "annotations must be booleans"
      end
      @endpoint = validate_endpoint!(Value.normalize(endpoint))
      @max_response_chars = Value.normalize(max_response_chars)
      unless @max_response_chars.nil? || (@max_response_chars.is_a?(Integer) && @max_response_chars.positive?)
        raise DefinitionError, "max_response_chars must be a positive integer"
      end
      @projection_notes = Value.normalize(projection_notes)
      @source_fingerprint = Value.normalize(source_fingerprint)
      @source = source # Keep the live source for drift checks; never freeze the SDK class.
      [@name, @description, @title, @input_schema, @annotations, @endpoint,
       @projection_notes, @source_fingerprint].each { |v| Value.deep_freeze(v) }
      WebMCP.config.logger&.warn("WebMCP name exceeds Chrome's recommended 30-character budget: #{@name}") if @name.length > 30
      WebMCP.config.logger&.warn("WebMCP description exceeds Chrome's recommended 500-character budget: #{@name}") if @description.length > 500
      freeze
    end

    def to_manifest_entry(transport)
      entry = { "name" => name, "description" => description, "inputSchema" => input_schema,
                "annotations" => annotations.select { |_, v| v }.to_h { |k, v| [ANNOTATIONS.fetch(k), v] },
                "endpoint" => { "path" => endpoint.fetch("path"), "method" => endpoint.fetch("method") } }
      entry["title"] = title unless title.nil?
      entry["maxResponseChars"] = max_response_chars unless max_response_chars.nil?
      entry["endpoint"]["paramMap"] = endpoint["param_map"] unless endpoint["param_map"].empty?
      entry["endpoint"]["arrayFormat"] = endpoint["array_format"] if endpoint["array_format"]
      entry["fingerprint"] = Value.fingerprint(entry.merge("transport" => Manifest.normalize_transport(transport)))
      Value.normalize(entry)
    end

    private

    def validate_endpoint!(endpoint)
      Value.keys!(endpoint, %w[path method param_map array_format], "endpoint")
      path = endpoint["path"]
      unless path.is_a?(String) && path.start_with?("/") && !path.start_with?("//") && !/[\\:\x00-\x1f\x7f]/.match?(path)
        raise DefinitionError, "endpoint path must be same-origin, start with /, and contain no // prefix, backslash, colon or control character"
      end
      method = endpoint["method"].to_s.upcase
      raise DefinitionError, "endpoint method must be GET, POST, PATCH, PUT or DELETE" unless METHODS.include?(method)
      if method == "GET" && annotations["read_only"] != true
        raise DefinitionError, "GET endpoints require read_only: true"
      end
      map = endpoint.fetch("param_map", {})
      Value.hash!(map, "param_map")
      properties = input_schema.fetch("properties", {})
      map.each do |key, destination|
        raise DefinitionError, "param_map key is not in schema properties: #{key}" unless properties.key?(key)
        unless destination.is_a?(String) && /\A[A-Za-z][A-Za-z0-9_]*\z/.match?(destination) && !FORBIDDEN_PARAMS.include?(destination)
          raise DefinitionError, "invalid or reserved param_map destination: #{destination.inspect}"
        end
      end
      destinations = properties.keys.map { |key| map.fetch(key, key) }
      raise DefinitionError, "param_map destinations collide" unless destinations.uniq == destinations
      format = endpoint["array_format"]
      raise DefinitionError, "array_format must be brackets or repeat" unless format.nil? || %w[brackets repeat].include?(format)
      format ||= "brackets" if method == "GET" && properties.values.any? { |p| p["type"] == "array" }
      { "path" => path, "method" => method, "param_map" => map, "array_format" => format }
    end
  end
end
