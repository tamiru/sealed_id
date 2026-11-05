require 'sealed_id/model'

module SealedId
  class Railtie < Rails::Railtie
    # Runs before the app's config/initializers, so an initializer setting SealedId.secret takes precedence.
    initializer 'sealed_id.default_secret' do
      SealedId.secret ||= -> { Rails.application.secret_key_base }
    end

    initializer 'sealed_id.include_model' do
      ActiveSupport.on_load(:active_record) { include SealedId::Model }
    end

    initializer 'sealed_id.include_controller' do
      ActiveSupport.on_load(:action_controller) do
        require 'sealed_id/decode_params'
        include SealedId::DecodeParams

        ActionDispatch::ExceptionWrapper.rescue_responses['SealedId::InvalidToken'] = :not_found
      end
    end

    config.after_initialize { SealedId.install_global_id_support }
  end
end
