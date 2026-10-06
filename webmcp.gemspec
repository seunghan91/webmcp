# frozen_string_literal: true

require_relative "lib/webmcp/version"

Gem::Specification.new do |spec|
  spec.name = "webmcp"
  spec.version = WebMCP::VERSION
  spec.authors = ["seunghan Kim"]
  spec.email = ["theqwe2000@gmail.com"]
  spec.summary = "Server-side WebMCP tools, explicit MCP projections, Rails forms and Origin-Trial helpers"
  spec.description = "A dependency-free Ruby core for immutable WebMCP definitions and safe manifests, " \
                     "with optional MCP SDK projection and Rails 7.1+ integration."
  spec.homepage = "https://github.com/seunghan91/webmcp"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir["lib/**/*", "app/assets/**/*", "runtime/webmcp-runtime.js", "conformance/**/*",
                   "README.md", "CHANGELOG.md", "LICENSE.txt", "Rakefile"].select { |path| File.file?(path) }
  spec.require_paths = ["lib"]
  spec.metadata["source_code_uri"] = "https://github.com/seunghan91/webmcp"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "mcp", ">= 1.1", "< 2"
  spec.add_development_dependency "actionview", ">= 7.1", "< 9"
  spec.add_development_dependency "railties", ">= 7.1", "< 9"
end
