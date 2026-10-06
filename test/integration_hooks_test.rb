# frozen_string_literal: true
require_relative "test_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

class IntegrationHooksTest < Minitest::Test
  def ruby_check(script)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script)
    assert status.success?, "#{stdout}\n#{stderr}"
    stdout
  end

  def test_core_loads_without_rails_or_mcp_or_active_support
    ruby_check <<~'SCRIPT'
      require "webmcp"
      abort "optional framework loaded" if defined?(Rails) || defined?(MCP) || defined?(ActiveSupport)
      value = WebMCP::Manifest.to_script_tag({ "text" => "</ScRiPt>&\u2028" })
      abort "unsafe script" unless value.include?('\u003c/ScRiPt\u003e\u0026\u2028')
      WebMCP.freeze!
      abort "unfrozen" unless WebMCP.registry.frozen? && WebMCP.tools.frozen?
    SCRIPT
  end

  def test_railtie_initializers_and_after_initialize_hook
    ruby_check <<~'SCRIPT'
      require "rails"
      require "action_view"
      require "webmcp"
      config = ActiveSupport::OrderedOptions.new
      config.webmcp = ActiveSupport::OrderedOptions.new
      config.webmcp.origin_trial_token = "configured-token"
      config.assets = ActiveSupport::OrderedOptions.new
      config.assets.paths = []
      config.assets.precompile = []
      middleware = Class.new do
        attr_reader :calls
        def initialize; @calls = []; end
        def use(*args, **kwargs); @calls << [args, kwargs]; end
      end.new
      app = Struct.new(:config, :middleware).new(config, middleware)
      %w[webmcp.configure webmcp.helpers webmcp.assets].each do |name|
        WebMCP::Railtie.initializers.find { |i| i.name == name }.run(app)
      end
      abort "middleware not inserted" unless middleware.calls == [[[WebMCP::OriginTrial], {token: "configured-token"}]]
      abort "token not propagated" unless WebMCP.config.origin_trial_token == "configured-token"
      ActionView::Base # Trigger the framework's lazy action_view load hook.
      abort "builder not extended" unless ActionView::Helpers::FormBuilder.ancestors.include?(WebMCP::FormBuilderOptions)
      abort "view helpers missing" unless ActionView::Base.ancestors.include?(WebMCP::ViewHelpers)
      root = File.expand_path("app/assets/javascripts")
      abort "asset namespace missing" unless config.assets.paths.include?(root) && config.assets.paths.include?(File.join(root, "webmcp"))
      abort "precompile missing" unless config.assets.precompile.include?("webmcp/runtime.js")
      config.webmcp.origin_trial_token = ""
      WebMCP::Railtie.initializers.find { |i| i.name == "webmcp.configure" }.run(app)
      abort "empty token inserted middleware" unless middleware.calls.length == 1
      # Execute only this Railtie's boot callback, without initializing a dummy app.
      hooks = ActiveSupport.instance_variable_get(:@load_hooks)[:after_initialize]
      hook = hooks.map(&:first).find { |block| block.source_location.first.end_with?("webmcp/railtie.rb") }
      abort "after_initialize hook missing" unless hook
      hook.call(app)
      abort "registry not frozen" unless WebMCP.registry.frozen?
    SCRIPT
  end

  def test_sync_runtime_task_preserves_bytes_and_records_digest
    # Run a copy of the task in isolation; never create/edit the shared runtime source.
    Dir.mktmpdir("webmcp-task-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib/tasks"))
      FileUtils.mkdir_p(File.join(dir, "runtime"))
      FileUtils.cp(File.expand_path("../lib/tasks/webmcp.rake", __dir__), File.join(dir, "lib/tasks/webmcp.rake"))
      bytes = "// @webmcp/runtime v0.1.0\nexport const sample = '한글';\n"
      File.binwrite(File.join(dir, "runtime/webmcp-runtime.js"), bytes)
      script = "require 'rake'; load #{File.join(dir, 'lib/tasks/webmcp.rake').inspect}; Rake::Task['webmcp:sync_runtime'].invoke"
      ruby_check(script)
      assert_equal bytes.b, File.binread(File.join(dir, "app/assets/javascripts/webmcp/runtime.js"))
      assert_equal "#{Digest::SHA256.hexdigest(bytes)}  runtime/webmcp-runtime.js\n", File.read(File.join(dir, "conformance/RUNTIME.sha256"))
    end
  end
end
