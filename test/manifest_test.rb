# frozen_string_literal: true
require_relative "test_helper"

class ManifestTest < Minitest::Test
  def test_autostart_defaults_on_and_can_be_disabled
    manifest = WebMCP::Manifest.build([tool], transport: {})
    assert_includes WebMCP::Manifest.to_script_tag(manifest), " data-webmcp-autostart>"
    refute_includes WebMCP::Manifest.to_script_tag(manifest, autostart: false), "data-webmcp-autostart"
  end

  def test_script_escape_table_and_nonce
    payload = "</ScRiPt><!--&>\u2028\u2029"
    manifest = WebMCP::Manifest.build([tool(description: payload)], transport: {})
    html = WebMCP::Manifest.to_script_tag(manifest, nonce: '"<>&')
    assert_includes html, 'nonce="&quot;&lt;&gt;&amp;"'
    json = html.split(">", 2).last.delete_suffix("</script>")
    refute_match(/[<>&\u2028\u2029]/, json)
    %w[\u003c \u003e \u0026 \u2028 \u2029].each { |escape| assert_includes json, escape }
    assert_equal manifest, JSON.parse(json)
  end

  def test_transport_and_duplicates
    assert_raises(WebMCP::DefinitionError) { WebMCP::Manifest.build([tool, tool], transport: {}) }
    [{ csrf: { source: :other, name: "token", header: "X-CSRF" } }, { csrf: {} }, { csrf: { source: :meta, name: "token", header: "X\nHeader" } }].each do |transport|
      assert_raises(WebMCP::DefinitionError) { WebMCP::Manifest.build([tool], transport: transport) }
    end
  end

  def test_conformance_fixtures
    paths = Dir[File.expand_path("../conformance/fixtures/*.json", __dir__)]
    assert_operator paths.length, :>=, 3
    paths.each do |path|
      fixture = JSON.parse(File.read(path))
      value = WebMCP::Tool.define(**fixture.fetch("definition").transform_keys(&:to_sym))
      manifest = WebMCP::Manifest.build([value], transport: fixture.fetch("transport"))
      assert_equal fixture.fetch("expected"), JSON.parse(JSON.generate(manifest))["tools"].first, path
    end
  end

  def test_registry
    registry = WebMCP::Registry.new
    value = tool
    assert_same value, registry.register(value)
    assert_same value, registry.fetch(:find_tasks)
    assert_raises(WebMCP::DefinitionError) { registry.register(tool) }
    assert_raises(WebMCP::DefinitionError) { registry.fetch(:unknown) }
    registry.freeze!
    assert registry.frozen?
    assert registry.tools.frozen?
    assert_raises(WebMCP::DefinitionError) { registry.register(tool(name: "other")) }
  end
end
