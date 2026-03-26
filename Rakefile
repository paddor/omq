# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

desc "Run omqcat CLI tests"
task "test:cli" do
  sh "sh test/omqcat/system_test.sh"
end

task default: :test
