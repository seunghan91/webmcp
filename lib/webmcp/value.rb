# frozen_string_literal: true

module WebMCP
  # Copy metadata, normalize Ruby symbol keys/values and reject non-JSON values.
  module Value
    module_function

    def normalize(value, ancestors = [])
      if value.is_a?(Hash) || value.is_a?(Array)
        raise DefinitionError, "metadata cannot contain circular references" if ancestors.include?(value.object_id)
        ancestors = ancestors + [value.object_id]
      end
      case value
      when Hash
        value.each_with_object({}) do |(key, item), result|
          unless key.is_a?(String) || key.is_a?(Symbol)
            raise DefinitionError, "metadata keys must be strings or symbols"
          end
          key = key.to_s
          raise DefinitionError, "duplicate metadata key: #{key}" if result.key?(key)
          result[key] = normalize(item, ancestors)
        end
      when Array then value.map { |item| normalize(item, ancestors) }
      when String
        string = String.new(value).encode(Encoding::UTF_8)
        raise DefinitionError, "metadata must be valid UTF-8" unless string.valid_encoding?
        string
      when Symbol then value.to_s
      when Integer
        raise DefinitionError, "metadata integers must be within +/-2^53" if value.abs > 2**53
        value
      when TrueClass, FalseClass, NilClass then value
      else raise DefinitionError, "metadata must contain JSON values; floats are not supported"
      end
    rescue EncodingError => e
      raise DefinitionError, "metadata must be UTF-8: #{e.message}"
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |k, v| deep_freeze(k); deep_freeze(v) }
      when Array then value.each { |v| deep_freeze(v) }
      end
      value.freeze
    end

    def sorted(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, sorted(value[key])] }
      when Array then value.map { |item| sorted(item) }
      else value
      end
    end

    def fingerprint(value)
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(sorted(normalize(value))))}"
    end

    def hash!(value, label)
      raise DefinitionError, "#{label} must be an object" unless value.is_a?(Hash)
      value
    end

    def keys!(value, allowed, label)
      hash!(value, label)
      unknown = value.keys - allowed
      raise DefinitionError, "unsupported #{label} keys: #{unknown.join(', ')}" unless unknown.empty?
    end

    def html_safe(value)
      value.respond_to?(:html_safe) ? value.html_safe : value
    end

    # String.new deliberately discards ActiveSupport's safe-string marker.
    def escape_html(value)
      CGI.escapeHTML(String.new(value.to_s))
    end
  end
end
