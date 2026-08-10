# frozen_string_literal: true

require_relative "lib/webmcp/version"

Gem::Specification.new do |spec|
  spec.name        = "webmcp"
  spec.version     = WebMCP::VERSION
  spec.authors     = ["seunghan Kim"]
  spec.email       = ["theqwe2000@gmail.com"]
  spec.summary     = "Ruby/Rails toolkit for WebMCP (W3C Web Model Context Protocol) — early development."
  spec.description = "Define agent-callable tools once in Ruby and expose them to browsers via the " \
                     "WebMCP standard (document.modelContext): declarative form attributes, " \
                     "imperative registration payloads, and Origin-Trial header middleware. " \
                     "Currently in early development while the W3C spec stabilizes (Chrome origin trial)."
  spec.homepage    = "https://github.com/seunghan91/webmcp"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.files       = Dir["lib/**/*.rb", "README.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]
  spec.metadata["source_code_uri"] = "https://github.com/seunghan91/webmcp"
  spec.metadata["rubygems_mfa_required"] = "true"
end
