# frozen_string_literal: true
require_relative "test_helper"
require "uri"
require "action_view"
require "active_support/core_ext/hash/reverse_merge"

WebMCP::FormHelper.install!

class CustomWebMCPTestBuilder < ActionView::Helpers::FormBuilder
  def text_field(attribute, options = {})
    super(attribute, options.merge(class: "custom-builder"))
  end
end

class WebMCPTestView < ActionView::Base
  include WebMCP::ViewHelpers

  def protect_against_forgery?
    false
  end

  def url_for(value = nil)
    value.is_a?(String) ? value : "/tasks"
  end

  def content_security_policy_nonce
    'nonce"<&'
  end

  def asset_path(name, **)
    "/assets/#{name}"
  end
end

class FormHelperTest < Minitest::Test
  def setup
    @view = WebMCPTestView.new(ActionView::LookupContext.new([]), {}, nil)
  end

  def parse(html)
    Nokogiri::HTML.fragment(html)
  end

  def test_custom_builder_and_escaped_attributes
    dangerous = %(<"& onfocus="evil).html_safe
    options = { tool: "create_task", description: dangerous, autosubmit: true }.freeze
    field_options = { webmcp: { param_description: dangerous }.freeze }.freeze
    seen = nil
    html = @view.form_with(url: "/tasks", builder: CustomWebMCPTestBuilder, webmcp: options) do |f|
      seen = f.class
      f.text_field(:title, field_options)
    end
    assert_equal CustomWebMCPTestBuilder, seen
    form = parse(html).at_css("form")
    assert_equal "create_task", form["toolname"]
    assert_equal dangerous, form["tooldescription"]
    assert form.key?("toolautosubmit")
    field = form.at_css("input.custom-builder")
    assert_equal dangerous, field["toolparamdescription"]
    refute field.key?("onfocus")
    refute_includes html, "toolparamtitle"
    refute form.key?("webmcp")
    assert options.key?(:tool)
    assert field_options.key?(:webmcp)
  end

  def test_default_form_builder_is_preserved
    @view.define_singleton_method(:default_form_builder) { CustomWebMCPTestBuilder }
    seen = nil
    html = @view.form_with(url: "/tasks", webmcp: { tool: "create_task", description: "Create", autosubmit: false }) do |f|
      seen = f.class
      f.text_field(:title, webmcp: { param_description: "Title" })
    end
    assert_equal CustomWebMCPTestBuilder, seen
    refute parse(html).at_css("form").key?("toolautosubmit")
    assert parse(html).at_css("input.custom-builder")
  end

  def test_field_variants_and_select_option_positions
    f = CustomWebMCPTestBuilder.new(:task, nil, @view, {})
    metadata = { param_description: "Parameter" }
    htmls = [f.text_area(:title, webmcp: metadata), f.check_box(:done, { webmcp: metadata }),
             f.radio_button(:priority, "high", webmcp: metadata), f.hidden_field(:id, webmcp: metadata),
             f.select(:priority, ["high"], webmcp: metadata), f.select(:priority, ["high"], {}, webmcp: metadata),
             f.collection_select(:priority, [Struct.new(:id, :name).new(1, "High")], :id, :name, webmcp: metadata),
             f.date_select(:due, { webmcp: metadata }), f.file_field(:file, webmcp: metadata)]
    htmls.each do |html|
      assert parse(html).at_css('[toolparamdescription="Parameter"]'), html
      refute_includes html, "webmcp="
      refute_includes html, "toolparamtitle"
    end
  end

  def test_form_tag_and_field_tag_options
    html = @view.form_tag("/tasks", webmcp: { tool: "create_task", description: "Create" }) do
      @view.text_field_tag(:title, nil, webmcp: { param_description: 'Title "<&'.html_safe })
    end
    assert_equal "create_task", parse(html).at_css("form")["toolname"]
    assert_equal 'Title "<&', parse(html).at_css("input[toolparamdescription]")["toolparamdescription"]
    [@view.check_box_tag(:done, "1", false, webmcp: { param_description: "Done" }),
     @view.select_tag(:priority, "", webmcp: { param_description: "Priority" }),
     @view.date_field_tag(:due, nil, webmcp: { param_description: "Date" })].each do |result|
      assert parse(result).at_css("[toolparamdescription]")
      refute_includes result, "webmcp="
    end
  end

  def test_invalid_form_metadata
    assert_raises(WebMCP::DefinitionError) { @view.form_with(url: "/", webmcp: { tool: "bad name", description: "Bad" }) {} }
    f = CustomWebMCPTestBuilder.new(:task, nil, @view, {})
    assert_raises(WebMCP::DefinitionError) { f.text_field(:title, webmcp: { param_title: "Not in spec" }) }
  end

  def test_manifest_helpers_are_page_opt_in_and_safe
    original_registry = WebMCP.registry
    WebMCP.instance_variable_set(:@registry, WebMCP::Registry.new)
    WebMCP.register(tool(description: "</ScRiPt><!--&\u2028".html_safe))
    WebMCP.register(tool(name: "other"))
    html = @view.webmcp_manifest_tag(:find_tasks)
    assert html.html_safe?
    script = parse(html).at_css("script")
    assert script.key?("data-webmcp-autostart")
    refute parse(@view.webmcp_manifest_tag(:find_tasks, autostart: false)).at_css("script").key?("data-webmcp-autostart")
    assert_equal 'nonce"<&', script["nonce"]
    manifest = JSON.parse(script.content)
    assert_equal ["find_tasks"], manifest["tools"].map { |entry| entry["name"] }
    assert_equal "X-CSRF-Token", manifest["transport"]["csrf"]["header"]
    assert_equal [], JSON.parse(parse(@view.webmcp_manifest_tag).at_css("script").content)["tools"]
    assert_raises(WebMCP::DefinitionError) { @view.webmcp_manifest_tag(:unknown) }
    runtime = parse(@view.webmcp_runtime_tag).at_css("script")
    assert_equal "/assets/webmcp/runtime.js", runtime["src"]
    assert_equal "module", runtime["type"]
    assert_equal 'nonce"<&', runtime["nonce"]
    assert_empty runtime.content
  ensure
    WebMCP.instance_variable_set(:@registry, original_registry)
  end

  def test_safe_marked_origin_trial_meta
    old_token = WebMCP.config.origin_trial_token
    WebMCP.config.origin_trial_token = '"<&'.html_safe
    html = @view.webmcp_origin_trial_meta_tag
    assert html.html_safe?
    assert_equal '"<&', parse(html).at_css("meta")["content"]
    assert_includes html, "&quot;&lt;&amp;"
  ensure
    WebMCP.config.origin_trial_token = old_token
  end
end
