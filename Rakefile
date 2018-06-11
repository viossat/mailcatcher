require "fileutils"
require "rubygems"

require "mail_catcher/version"

desc "Compile assets"
task "assets" do
  system "npm", "run", "build" or fail
end

desc "Package as Gem"
task "package" => ["assets"] do
  require "rubygems/package"
  require "rubygems/specification"

  spec_file = File.expand_path("../mailcatcher.gemspec", __FILE__)
  spec = Gem::Specification.load(spec_file)

  Gem::Package.build spec
end

desc "Release Gem to RubyGems"
task "release" => ["package"] do
  %x[gem push mailcatcher-#{MailCatcher::VERSION}.gem]
end

require "rdoc/task"

RDoc::Task.new(:rdoc => "doc",:clobber_rdoc => "doc:clean", :rerdoc => "doc:force") do |rdoc|
  rdoc.title = "MailCatcher #{MailCatcher::VERSION}"
  rdoc.rdoc_dir = "doc"
  rdoc.main = "README.md"
  rdoc.rdoc_files.include "lib/**/*.rb"
end

require "rake/testtask"

Rake::TestTask.new do |task|
  task.pattern = "spec/*_spec.rb"
end

task :test => :assets

task :default => :test
