source 'https://rubygems.org'

gemspec

gem 'activerecord', "~> #{ENV.fetch('ACTIVE_RECORD_VERSION', nil)}.0" if ENV['ACTIVE_RECORD_VERSION'].to_s != ''
gem 'sqlite3', "~> #{ENV.fetch('SQLITE3_VERSION', nil)}" if ENV['SQLITE3_VERSION'].to_s != ''

# These ActiveSupport lines pass an option to JSON.generate that json 3 rejects, which breaks signed global ids.
gem 'json', '< 3' if ENV['ACTIVE_RECORD_VERSION'].to_s.match?(/\A(6\.|7\.[01]|8\.0)/)

# Bundler can't load timeout 0.6 on Ruby 2.7.
gem 'timeout', '< 0.6' if RUBY_VERSION < '3.0'
