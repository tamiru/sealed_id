require 'sealed_id/version'

module SealedId
  class Error < StandardError; end
  class InvalidToken < Error; end

  RAW_IDS_KEY = :sealed_id_raw_ids
  private_constant :RAW_IDS_KEY

  class << self
    # The default secret for every model. May be callable. At least 32 bytes.
    attr_accessor :secret

    # Inside the block, +find+ reads digit-only strings as primary keys.
    # Only use it for ids the application produced itself, never for ones taken from a request.
    def with_raw_ids
      previous = Thread.current[RAW_IDS_KEY]
      Thread.current[RAW_IDS_KEY] = true
      yield
    ensure
      Thread.current[RAW_IDS_KEY] = previous
    end

    def raw_ids?
      Thread.current[RAW_IDS_KEY] == true
    end

    def install_global_id_support
      return unless defined?(GlobalID::Locator)

      require 'sealed_id/global_id_locator'
      GlobalID::Locator.singleton_class.prepend(GlobalIdLocator)
    end
  end
end

if defined?(Rails::Railtie)
  require 'sealed_id/railtie'
elsif defined?(ActiveRecord)
  require 'sealed_id/model'
  ActiveRecord::Base.include SealedId::Model
  SealedId.install_global_id_support
end
