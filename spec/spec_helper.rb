$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'simplecov'
SimpleCov.start do
  minimum_coverage 90
  add_filter ['spec/', 'railtie.rb', 'version.rb']
end

# Rails 7.0 and older reference Logger without requiring it, which fails with current concurrent-ruby.
require 'logger'
require 'active_record'
require 'action_controller/metal/strong_parameters'
require 'global_id'

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Migration.verbose = false
ActiveRecord::Schema.define do
  create_table(:foos)
  create_table(:bars) { |t| t.integer :foo_id }
  create_table(:plains) { |t| t.integer :foo_id }
  create_table(:uuid_things, id: :string)
end

require 'sealed_id'

GlobalID.app = 'test'
SignedGlobalID.verifier = GlobalID::Verifier.new('verifier-secret')
TEST_SECRET = 'abcdefghijklmnopqrstuvwxyz012345'.freeze
OTHER_SECRET = '543210zyxwvutsrqponmlkjihgfedcba'.freeze
SealedId.secret = TEST_SECRET

RSpec.configure do |config|
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }
  config.order = :random
  Kernel.srand config.seed

  # Records created by one example must not satisfy, or collide with, another under random ordering.
  config.around do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end
end
