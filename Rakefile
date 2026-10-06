# frozen_string_literal: true

require "rake/testtask"
Rake::TestTask.new do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
end
load File.expand_path("lib/tasks/webmcp.rake", __dir__)
task default: :test

namespace :test do
  desc "Run the strict-CSP Rails/Turbo integration gate in system Google Chrome"
  task :integration do
    sh "node", "--test", "test/integration/browser.test.mjs"
  end

  desc "Build and install the gem in a fresh Rails app, precompile and test production assets"
  task :package do
    ruby "test/integration/package_smoke.rb"
  end
end
