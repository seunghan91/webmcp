# frozen_string_literal: true

module WebMCP
  class Railtie < Rails::Railtie
    config.webmcp = ActiveSupport::OrderedOptions.new
    config.webmcp.origin_trial_token = ENV["WEBMCP_ORIGIN_TRIAL_TOKEN"]

    initializer "webmcp.configure" do |app|
      if Gem::Version.new(Rails.version) < Gem::Version.new("7.1")
        raise DefinitionError, "WebMCP Rails integration requires Rails >= 7.1"
      end
      token = app.config.webmcp.origin_trial_token
      WebMCP.config.origin_trial_token = token
      WebMCP.config.logger = Rails.logger if Rails.logger
      app.middleware.use WebMCP::OriginTrial, token: token unless token.nil? || token.empty?
    end

    initializer "webmcp.helpers" do
      ActiveSupport.on_load(:action_view) do
        WebMCP::FormHelper.install!
        include WebMCP::ViewHelpers
      end
    end

    initializer "webmcp.assets", after: :load_config_initializers do |app|
      if app.config.respond_to?(:assets)
        # The parent preserves the logical path webmcp/runtime.js in both pipelines.
        root = File.expand_path("../../app/assets/javascripts", __dir__)
        app.config.assets.paths << root
        app.config.assets.paths << File.join(root, "webmcp")
        if app.config.assets.respond_to?(:precompile)
          app.config.assets.precompile += ["webmcp/runtime.js"]
        end
      end
    end

    config.after_initialize { WebMCP.freeze! }

    rake_tasks do
      load File.expand_path("../tasks/webmcp.rake", __dir__)
    end
  end
end
