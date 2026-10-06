# frozen_string_literal: true

module WebMCP
  module Manifest
    ESCAPES = { "<" => '\u003c', ">" => '\u003e', "&" => '\u0026', "\u2028" => '\u2028', "\u2029" => '\u2029' }.freeze
    module_function

    def normalize_transport(transport)
      transport = Value.normalize(transport)
      Value.keys!(transport, %w[csrf], "transport")
      if transport.key?("csrf")
        csrf = transport["csrf"]
        Value.keys!(csrf, %w[source name header], "csrf")
        unless %w[meta cookie].include?(csrf["source"]) && %w[name header].all? { |k| csrf[k].is_a?(String) && !csrf[k].empty? && !/[\x00-\x1f\x7f]/.match?(csrf[k]) }
          raise DefinitionError, "csrf requires source meta/cookie and nonempty name/header"
        end
      end
      transport
    end

    def build(tools, transport:)
      transport = normalize_transport(transport)
      entries = tools.map { |tool| tool.to_manifest_entry(transport) }
      names = entries.map { |entry| entry["name"] }
      raise DefinitionError, "duplicate tool names in manifest" unless names.uniq == names
      { "webmcpManifestVersion" => 1, "transport" => transport, "tools" => entries }
    end

    def to_script_tag(hash, nonce: nil, autostart: true)
      json = JSON.generate(Value.normalize(hash)).gsub(/[<>&\u2028\u2029]/, ESCAPES)
      nonce_attr = nonce.nil? ? "" : %( nonce="#{Value.escape_html(nonce)}")
      autostart_attr = autostart ? " data-webmcp-autostart" : ""
      Value.html_safe(%(<script type="application/json" id="webmcp-manifest"#{nonce_attr}#{autostart_attr}>#{json}</script>))
    end
  end
end
