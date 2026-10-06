# frozen_string_literal: true

module WebMCP
  class OriginTrial
    def initialize(app, token: nil, warn_on_oac_opt_out: true, logger: WebMCP.config.logger)
      @app, @token, @logger = app, token.to_s, logger
      @warn_on_oac_opt_out = warn_on_oac_opt_out
      @warned = false
      @warning_lock = Mutex.new
    end

    def call(env)
      response = @app.call(env)
      return response if @token.empty?
      status, headers, body = response
      unless headers.keys.any? { |key| key.downcase == "origin-trial" }
        headers = headers.dup
        # Rack 3 requires lowercase field names; Rack 2 preserves conventional casing.
        key = env["rack.version"]&.first.to_i >= 3 || (defined?(Rack::RELEASE) && Rack::RELEASE.to_i >= 3) ? "origin-trial" : "Origin-Trial"
        headers[key] = @token
      end
      oac_key = headers.keys.find { |key| key.downcase == "origin-agent-cluster" }
      if @warn_on_oac_opt_out && headers[oac_key] == "?0"
        @warning_lock.synchronize do
          unless @warned
            @logger&.warn("WebMCP: Origin-Agent-Cluster: ?0 may cause SecurityError in older Origin-Trial builds; header left unchanged")
            @warned = true
          end
        end
      end
      [status, headers, body]
    end

    def self.meta_tag(token)
      return Value.html_safe("") if token.nil? || token.to_s.empty?
      Value.html_safe(%(<meta http-equiv="origin-trial" content="#{Value.escape_html(token)}">))
    end
  end
end
