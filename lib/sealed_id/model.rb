require_relative 'core'

module SealedId
  module Model
    extend ActiveSupport::Concern

    module ClassMethods
      # Options:
      #   secret: overrides SealedId.secret for this model. May be callable.
      #   scope:  separates this model's tokens from other models'. Defaults to the base class name, so set it
      #           before renaming a model to keep its URLs working.
      #   legacy: a callable taking a string and returning an integer id or nil, so ids issued before adopting this
      #           gem keep working, such as those printed on documents. New tokens are still sealed. Anything it
      #           accepts is only as hard to guess as the old scheme, so use it only on models that need it.
      def sealed_id(secret: nil, scope: nil, legacy: nil)
        include SealedId::Core unless ancestors.include?(SealedId::Core)

        options = { secret: secret, scope: scope, legacy: legacy }.freeze
        define_singleton_method(:sealed_id_options) { options }
        private_class_method :sealed_id_options
      end
    end
  end
end
