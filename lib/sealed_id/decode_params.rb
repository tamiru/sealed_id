module SealedId
  # Turns tokens in permitted params back into primary keys, using the model's associations to pick each key's model:
  #
  #   decode_params(Student, params.expect(student: [:name, :program_id, { course_ids: [] }]))
  #
  # Handles +id+, belongs_to foreign keys, +*_ids+ and nested +*_attributes+. Blank values stay as they are, so a form
  # can still clear an association. An invalid token raises SealedId::InvalidToken rather than becoming nil, which
  # would silently clear the association, or staying a string, which ActiveRecord would cast to the wrong integer.
  # Integers are invalid too: this is the request boundary, and a raw id in a JSON body must not get through.
  module DecodeParams
    private

    def decode_params(model, params)
      Decoder.call(model, params)
    end

    module Decoder
      module_function

      def call(model, params)
        attributes = ActiveSupport::HashWithIndifferentAccess.new(params)
        attributes.each_with_object(ActiveSupport::HashWithIndifferentAccess.new) do |(key, value), decoded|
          decoded[key] = decode_key(model, key.to_s, value)
        end
      end

      def decode_key(model, key, value)
        if key == 'id' then decode_token(model, value)
        elsif key.end_with?('_ids') then decode_many(model, key, value)
        elsif key.end_with?('_id') then decode_foreign_key(model, key, value)
        elsif key.end_with?('_attributes') then decode_nested(model, key, value)
        else value
        end
      end

      def decode_foreign_key(model, key, value)
        reflection = model.reflect_on_all_associations(:belongs_to).find { |r| r.foreign_key.to_s == key }
        return value unless reflection

        if reflection.polymorphic?
          raise ArgumentError, "decode_params can't tell which model #{model.name}##{key} refers to; decode it yourself"
        end

        decode_token(reflection.klass, value)
      end

      def decode_many(model, key, value)
        reflection = model.reflect_on_association(key.delete_suffix('_ids').pluralize)
        return value unless reflection

        Array(value).map { |token| decode_token(reflection.klass, token) }
      end

      def decode_nested(model, key, value)
        reflection = model.reflect_on_association(key.delete_suffix('_attributes'))
        return value unless reflection

        klass = reflection.klass
        case value
        when Array then value.map { |attributes| call(klass, attributes) }
        when Hash then indexed?(value) ? value.transform_values { |attributes| call(klass, attributes) } : call(klass, value)
        else value
        end
      end

      # Rails sends collections from forms as { "0" => {...}, "1" => {...} }.
      def indexed?(hash)
        hash.keys.all? { |key| key.to_s.match?(/\A\d+\z/) }
      end

      def decode_token(klass, value)
        return value if value.blank? && !value.is_a?(Numeric)
        return value unless klass.respond_to?(:unseal)

        klass.unseal(value) || raise(InvalidToken, "Invalid sealed id for #{klass.name}: #{value.inspect.truncate(100)}")
      end
    end
    private_constant :Decoder
  end
end
