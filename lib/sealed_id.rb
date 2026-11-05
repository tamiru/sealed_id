require 'sealed_id/version'

module SealedId
  class Error < StandardError; end
  class InvalidToken < Error; end

  RAW_IDS_KEY = :sealed_id_raw_ids
  private_constant :RAW_IDS_KEY

  class << self
    attr_writer :secret

    # The default secret for every model, from SealedId.secret= or else the SEALED_ID_SECRET environment variable.
    # May be callable. At least 32 bytes.
    def secret
      return @secret if @secret

      value = ENV.fetch('SEALED_ID_SECRET', nil)
      value unless value.to_s.empty?
    end

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

    # The model a token was issued for, or nil if it isn't a valid token.
    def model_for(token)
      models.find { |model| model.sealed_id_codec.decode(token) }
    end

    # The record a token stands for, whichever model it belongs to, or nil if there isn't one.
    # This finds across every model, so always check the caller may see the record it returns.
    def locate(token)
      model = model_for(token)
      model&.find_by(model.primary_key => model.sealed_id_codec.decode(token))
    end

    # Like +locate+, but raises ActiveRecord::RecordNotFound.
    def find(token)
      locate(token) || raise(ActiveRecord::RecordNotFound, 'No record for this sealed id')
    end

    # Every model using sealed_id. Raises if two share a tag, because their tokens could not be told apart.
    def models
      eager_load_application
      found = ActiveRecord::Base.descendants.select { |model| sealed_root_model?(model) }
      found.group_by { |model| model.sealed_id_codec.tag }.each_value do |same_tag|
        next if same_tag.one?

        raise Error,
              "These models share a sealed_id scope, so their tokens would collide: #{same_tag.map(&:name).join(', ')}"
      end
      found
    end

    private

    # Only named top-level models: subclasses share their base class's tokens through single-table inheritance.
    def sealed_root_model?(model)
      model.respond_to?(:sealed_id_codec) && !model.abstract_class? && model.base_class == model &&
        model.name.to_s.safe_constantize.equal?(model)
    end

    # Models load on first use in development, so they wouldn't all be known yet.
    def eager_load_application
      return unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

      Rails.application.eager_load! unless Rails.application.config.eager_load
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
