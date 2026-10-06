# frozen_string_literal: true
require "bundler"
require "digest"
require "fileutils"
require "open3"
require "rbconfig"
require "rubygems/package"
require "tmpdir"

ROOT = File.expand_path("../..", __dir__)

def run!(*command, chdir:, env: {})
  puts "$ #{command.join(' ')}"
  output, status = Open3.capture2e(env, *command, chdir: chdir)
  puts output
  raise "Command failed (#{status.exitstatus}): #{command.join(' ')}" unless status.success?
  output
end

def write(app, path, contents)
  target = File.join(app, path)
  FileUtils.mkdir_p(File.dirname(target))
  File.write(target, contents)
end

Dir.mktmpdir("webmcp-package-") do |directory|
  archive = File.join(directory, "webmcp.gem")
  run!("gem", "build", "webmcp.gemspec", "--output", archive, chdir: ROOT)
  package = Gem::Package.new(archive)
  installed = File.join(directory, "webmcp-#{package.spec.version}")
  package.extract_files(installed)
  File.write(File.join(installed, "webmcp.gemspec"), package.spec.to_ruby)
  canonical = File.join(ROOT, "runtime/webmcp-runtime.js")
  packaged_asset = File.join(installed, "app/assets/javascripts/webmcp/runtime.js")
  raise "Packaged runtime differs from canonical source; run rake webmcp:sync_runtime" unless File.binread(packaged_asset) == File.binread(canonical)
  digest = Digest::SHA256.file(packaged_asset).hexdigest
  raise "Packaged runtime digest is stale" unless File.read(File.join(installed, "conformance/RUNTIME.sha256")).split.first == digest

  app = File.join(directory, "smoke_app")
  run!("bundle", "exec", "rails", "new", app, "--minimal", "--skip-git", "--skip-bundle",
       "--skip-active-record", "--skip-bootsnap", "--skip-docker", "--skip-ci", chdir: ROOT)
  versions = %w[rails propshaft puma].to_h { |name| [name, Gem.loaded_specs.fetch(name).version.to_s] }
  write(app, "Gemfile", "source \"https://rubygems.org\"\n" +
    versions.map { |name, version| "gem #{name.inspect}, #{version.inspect}\n" }.join +
    "gem \"webmcp\", path: #{installed.inspect}\n")
  write(app, "config/boot.rb", <<~RUBY)
    ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
    require "bundler/setup"
  RUBY
  write(app, "config/application.rb", <<~RUBY)
    require_relative "boot"
    require "rails"
    require "action_controller/railtie"
    require "action_view/railtie"
    Bundler.require(*Rails.groups)
    module SmokeApp
      class Application < Rails::Application
        config.load_defaults 8.0
        config.action_controller.allow_forgery_protection = true
      end
    end
  RUBY
  write(app, "config/environments/production.rb", <<~RUBY)
    Rails.application.configure do
      config.eager_load = true
      config.enable_reloading = false
      config.consider_all_requests_local = false
      config.force_ssl = false
      config.public_file_server.enabled = true
      config.hosts = ["localhost", "127.0.0.1"]
      config.logger = Logger.new($stdout)
    end
  RUBY
  # The generated app is disposable; replace its example configuration and page.
  FileUtils.rm_rf(Dir[File.join(app, "config/initializers/*")])
  FileUtils.cp(File.join(ROOT, "test/dummy/config/initializers/content_security_policy.rb"),
               File.join(app, "config/initializers/content_security_policy.rb"))
  write(app, "config/initializers/webmcp.rb", <<~RUBY)
    raise "Loaded checkout instead of built gem" unless Gem.loaded_specs.fetch("webmcp").full_gem_path == #{installed.inspect}
    WebMCP.register(WebMCP::Tool.define(
      name: "packaged_items", title: "Packaged items", description: "Read items from the installed gem app.",
      input_schema: { type: "object", properties: {} }, annotations: { read_only: true },
      endpoint: { path: "/api/items", method: :get }
    ))
  RUBY
  write(app, "config/routes.rb", <<~RUBY)
    Rails.application.routes.draw do
      get "/page_a", to: "smoke#index"
      get "/api/items", to: "smoke#items"
      get "/favicon.ico", to: proc { [204, {}, []] }
    end
  RUBY
  write(app, "app/controllers/smoke_controller.rb", <<~RUBY)
    class SmokeController < ActionController::Base
      layout "application"
      protect_from_forgery with: :exception
      def index; end
      def items
        render json: { packaged: true }
      end
    end
  RUBY
  write(app, "app/views/layouts/application.html.erb", <<~ERB)
    <!doctype html>
    <html><head><title>Packaged WebMCP</title>
    <%= csrf_meta_tags %><%= csp_meta_tag %><%= webmcp_runtime_tag %>
    </head><body><%= yield %></body></html>
  ERB
  write(app, "app/views/smoke/index.html.erb", <<~ERB)
    <h1>Packaged runtime</h1>
    <%= webmcp_manifest_tag(:packaged_items) %>
  ERB

  Bundler.with_unbundled_env do
    env = { "BUNDLE_GEMFILE" => File.join(app, "Gemfile"), "BUNDLE_APP_CONFIG" => File.join(app, ".bundle"),
            "RAILS_ENV" => "production", "SECRET_KEY_BASE" => "dummy" }
    run!("bundle", "install", chdir: app, env: env)
    run!("bin/rails", "assets:precompile", chdir: app, env: env)
    run!("node", File.join(ROOT, "test/integration/package.test.mjs"), app, digest, chdir: app, env: env)
  end
end
puts "Package smoke: PASS (temporary application and unpacked gem removed)"
