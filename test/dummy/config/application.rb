require_relative "boot"
require "rails"
require "action_controller/railtie"
require "action_view/railtie"
require "propshaft"
require "importmap-rails"
require "turbo-rails"
require "webmcp"

module WebMCPDummy
  # A server-side audit log proves rejected client calls never reach Rack.
  class RequestAudit
    def initialize(app)
      @app = app
    end

    def call(env)
      if env["PATH_INFO"].start_with?("/api/") && ENV["WEBMCP_REQUEST_LOG"]
        File.open(ENV.fetch("WEBMCP_REQUEST_LOG"), "a") do |log|
          csrf_header = if env["HTTP_X_CSRF_TOKEN_PAGE_B"] then "page-b" elsif env["HTTP_X_CSRF_TOKEN"] then "default" end
          log.puts JSON.generate(method: env["REQUEST_METHOD"], path: env["PATH_INFO"], csrf_header: csrf_header)
        end
      end
      @app.call(env)
    end
  end

  class Application < Rails::Application
    config.load_defaults 8.0
    config.eager_load = false
    config.secret_key_base = "webmcp-dummy-test-secret-" * 8
    config.hosts = ["127.0.0.1", "localhost"]
    config.action_controller.allow_forgery_protection = true
    config.action_dispatch.show_exceptions = :all
    config.logger = Logger.new($stdout)
    config.middleware.use RequestAudit
  end
end
