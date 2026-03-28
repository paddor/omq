# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "minitest"
gem "rake"
gem "benchmark-ips"

if ENV["DEV_ENV"]
  gem "cztop",     require: false
  gem "zstd-ruby", require: false
end
