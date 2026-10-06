# frozen_string_literal: true

require "json"
require "digest"
require "cgi"
require "logger"
require_relative "webmcp/version"

module WebMCP
  class DefinitionError < ArgumentError; end

  class Configuration
    attr_accessor :logger, :origin_trial_token

    def initialize
      @logger = Logger.new($stderr)
      @origin_trial_token = ENV["WEBMCP_ORIGIN_TRIAL_TOKEN"]
    end
  end

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    def registry
      @registry ||= Registry.new
    end

    def register(tool)
      registry.register(tool)
    end

    def tools
      registry.tools
    end

    def freeze!
      registry.freeze!
    end
  end
end

require_relative "webmcp/value"
require_relative "webmcp/schema"
require_relative "webmcp/tool"
require_relative "webmcp/projection"
require_relative "webmcp/testing"
require_relative "webmcp/registry"
require_relative "webmcp/manifest"
require_relative "webmcp/origin_trial"
require_relative "webmcp/form_helper"
require_relative "webmcp/view_helpers"
require_relative "webmcp/railtie" if defined?(Rails::Railtie)
