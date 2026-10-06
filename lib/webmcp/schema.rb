# frozen_string_literal: true

module WebMCP
  module Schema
    SCALARS = %w[string number integer boolean].freeze
    METADATA = %w[enum description default minimum maximum maxLength maxItems].freeze
    RESERVED = %w[__proto__ constructor prototype].freeze
    module_function

    def validate!(schema)
      Value.keys!(schema, %w[type properties required description], "input_schema")
      raise DefinitionError, 'input_schema type must be object' unless schema["type"] == "object"
      properties = schema.fetch("properties", {})
      Value.hash!(properties, "properties")
      properties.each do |name, property|
        raise DefinitionError, "reserved property name: #{name}" if RESERVED.include?(name)
        validate_property!(property, name)
      end
      if schema.key?("description") && !schema["description"].is_a?(String)
        raise DefinitionError, "schema description must be a string"
      end
      if schema.key?("required")
        required = schema["required"]
        unless required.is_a?(Array) && required.all? { |key| key.is_a?(String) && properties.key?(key) } && required.uniq == required
          raise DefinitionError, "required must contain unique declared property names"
        end
      end
      schema
    end

    def validate_property!(property, label, scalar_only: false)
      Value.keys!(property, ["type", *METADATA, *(scalar_only ? [] : ["items"])], "property #{label}")
      type = property["type"]
      unless SCALARS.include?(type) || (!scalar_only && type == "array")
        raise DefinitionError, "#{label}: only scalar properties and arrays of scalars are supported"
      end
      if type == "array"
        validate_property!(property["items"], "#{label}.items", scalar_only: true)
      elsif property.key?("items")
        raise DefinitionError, "#{label}: items requires array type"
      end
      if property.key?("description") && !property["description"].is_a?(String)
        raise DefinitionError, "#{label}: description must be a string"
      end
      %w[minimum maximum maxLength maxItems].each do |key|
        next unless property.key?(key)
        v = property[key]
        unless v.is_a?(Integer) && (!%w[maxLength maxItems].include?(key) || v >= 0)
          raise DefinitionError, "#{label}: #{key} must be an integer (lengths must be nonnegative)"
        end
      end
      if property.key?("enum")
        values = property["enum"]
        unless values.is_a?(Array) && !values.empty? && values.all? { |v| matches?(v, property) }
          raise DefinitionError, "#{label}: enum must be a nonempty array matching the property type"
        end
      end
      if property.key?("default") && !matches?(property["default"], property)
        raise DefinitionError, "#{label}: default must match the property type"
      end
    end

    def matches?(value, schema)
      case schema["type"]
      when "string" then value.is_a?(String)
      when "number", "integer" then value.is_a?(Integer)
      when "boolean" then value == true || value == false
      when "array" then value.is_a?(Array) && value.all? { |item| matches?(item, schema["items"]) }
      else false
      end
    end
  end
end
