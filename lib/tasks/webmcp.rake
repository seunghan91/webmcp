# frozen_string_literal: true

require "digest"
require "fileutils"

namespace :webmcp do
  desc "Copy the canonical runtime into Rails assets and record its SHA-256"
  task :sync_runtime do
    root = File.expand_path("../..", __dir__)
    source = File.join(root, "runtime/webmcp-runtime.js")
    abort "Missing #{source}; the runtime lane must supply it before packaging" unless File.file?(source)
    destination = File.join(root, "app/assets/javascripts/webmcp/runtime.js")
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp(source, destination)
    FileUtils.mkdir_p(File.join(root, "conformance"))
    digest = Digest::SHA256.file(destination).hexdigest
    File.write(File.join(root, "conformance/RUNTIME.sha256"), "#{digest}  runtime/webmcp-runtime.js\n")
    puts "Synced webmcp/runtime.js (sha256:#{digest})"
  end
end
