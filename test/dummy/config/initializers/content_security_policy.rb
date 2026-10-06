Rails.application.config.content_security_policy do |policy|
  policy.default_src :self
  policy.script_src :self
  policy.style_src :self
  policy.object_src :none
  policy.base_uri :self
end
# Stable for a session so Turbo visits use the same document's CSP nonce.
Rails.application.config.content_security_policy_nonce_generator = ->(request) {
  request.session[:csp_nonce] ||= SecureRandom.base64(32)
}
Rails.application.config.content_security_policy_nonce_directives = %w[script-src style-src]
