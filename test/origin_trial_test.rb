# frozen_string_literal: true
require_relative "test_helper"

class OriginTrialTest < Minitest::Test
  def middleware(headers = {}, token: "token", **options)
    WebMCP::OriginTrial.new(->(_) { [200, headers, ["body"]] }, token: token, **options)
  end

  def test_missing_present_and_empty_tokens
    headers = {}.freeze
    result = middleware(headers).call({})
    assert_equal "token", result[1].find { |k, _| k.downcase == "origin-trial" }.last
    assert_empty headers
    ["Origin-Trial", "origin-trial", "ORIGIN-TRIAL"].each do |name|
      ["existing", ""].each do |value|
        assert_equal({ name => value }, middleware({ name => value }).call({})[1])
      end
    end
    [nil, ""].each { |token| assert_equal({}, middleware(token: token).call({})[1]) }
    assert_equal "token", middleware.call("rack.version" => [3, 0])[1]["origin-trial"]
  end

  def test_oac_warning_once_and_no_rewrite
    log = StringIO.new
    app = middleware({ "Origin-Agent-Cluster" => "?0" }, logger: Logger.new(log))
    2.times { assert_equal "?0", app.call({})[1]["Origin-Agent-Cluster"] }
    assert_equal 1, log.string.scan("may cause SecurityError").size
    quiet = StringIO.new
    middleware({ "origin-agent-cluster" => "?0" }, warn_on_oac_opt_out: false, logger: Logger.new(quiet)).call({})
    middleware({ "origin-agent-cluster" => "?0" }, token: "", logger: Logger.new(quiet)).call({})
    assert_empty quiet.string
  end

  def test_meta_escaping
    assert_equal '<meta http-equiv="origin-trial" content="&quot;&lt;&gt;&amp;&#39;">', WebMCP::OriginTrial.meta_tag(%("<>&'))
    assert_equal "", WebMCP::OriginTrial.meta_tag("")
  end
end
