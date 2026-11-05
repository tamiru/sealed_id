# frozen_string_literal: true

require_relative 'lib/sealed_id/version'

Gem::Specification.new do |spec|
  spec.name          = 'sealed_id'
  spec.version       = SealedId::VERSION

  spec.authors       = ['Tamiru Hailu']
  spec.email         = ['tamiruhailu@gmail.com']

  spec.summary       = 'Unguessable, UUID-shaped public ids for ActiveRecord, with no migration.'
  spec.description   = 'Encrypts integer primary keys into UUID-shaped tokens for URLs, and refuses raw ids from requests.'
  spec.homepage      = 'https://github.com/tamiru/sealed_id'
  spec.license       = 'MIT'

  # An allow-list, so editor settings, CI config and anything else added to the repo never ship in the gem.
  spec.files = Dir.glob('{lib/**/*.rb,LICENSE,README.md,CHANGELOG.md}', base: __dir__)
  spec.require_paths = ['lib']

  spec.required_ruby_version = '>= 2.7'

  spec.add_dependency 'activerecord', '>= 6.0', '< 8.2'

  spec.add_development_dependency 'actionpack', '>= 6.0', '< 8.2'
  spec.add_development_dependency 'globalid', '>= 1.0'
  spec.add_development_dependency 'rake', '>= 12.0'
  spec.add_development_dependency 'rspec', '>= 3.10'
  spec.add_development_dependency 'rubocop', '>= 1.0'
  spec.add_development_dependency 'rubocop-rspec', '>= 2.0'
  # simplecov 1.x doesn't parse on every Ruby this gem supports.
  spec.add_development_dependency 'simplecov', '>= 0.21', '< 1.0'
  spec.add_development_dependency 'sqlite3', '>= 1.4'

  spec.metadata['rubygems_mfa_required'] = 'true'
end
