# frozen_string_literal: true

module WebMCP
  module ViewHelpers
    DEFAULT_TRANSPORT = Value.deep_freeze({ "csrf" => { "source" => "meta", "name" => "csrf-token", "header" => "X-CSRF-Token" } })

    def webmcp_manifest_tag(*tool_names, transport: DEFAULT_TRANSPORT, nonce: webmcp_nonce, autostart: true)
      tools = tool_names.map { |name| WebMCP.registry.fetch(name) }
      Manifest.to_script_tag(Manifest.build(tools, transport: transport), nonce: nonce, autostart: autostart)
    end

    def webmcp_runtime_tag
      src = asset_path("webmcp/runtime.js")
      nonce = webmcp_nonce
      nonce_attr = nonce.nil? ? "" : %( nonce="#{Value.escape_html(nonce)}")
      Value.html_safe(%(<script type="module" src="#{Value.escape_html(src)}"#{nonce_attr}></script>))
    end

    def webmcp_origin_trial_meta_tag
      OriginTrial.meta_tag(WebMCP.config.origin_trial_token)
    end

    private

    def webmcp_nonce
      content_security_policy_nonce if respond_to?(:content_security_policy_nonce)
    end
  end
end
