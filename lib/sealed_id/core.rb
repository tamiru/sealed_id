require_relative 'codec'

module SealedId
  module Core
    extend ActiveSupport::Concern

    # Longer than any token, and bounds what reaches a legacy decoder, whose cost may grow with input length.
    MAX_TOKEN_LENGTH = 64

    # The public token for this record, or nil if it has no integer id yet.
    def sealed_id
      key = id
      self.class.sealed_id_codec.encode(key) if key.is_a?(Integer)
    end

    def to_param
      sealed_id || super
    end

    module FinderMethods
      def find(*args, &block)
        return (respond_to?(:detect) ? self : all).detect(&block) if block
        return super unless respond_to?(:sealed_primary_key?) && sealed_primary_key?

        ids = args.flatten
        args.size > 1 || args.first.is_a?(Array) ? find_many_sealed(ids) : find_one_sealed(ids.first)
      end

      private

      def find_one_sealed(id)
        key = sealed_id_to_primary_key(id)
        record = where(primary_key => key).take if key
        record || raise_sealed_not_found([sealed_error_label(id, key)], 0, 1)
      end

      def find_many_sealed(ids)
        keys = ids.map { |id| sealed_id_to_primary_key(id) }
        wanted = keys.uniq
        scope = where(primary_key => wanted.compact)
        records = scope.to_a

        if records.size != wanted.size
          labels = ids.zip(keys).map { |id, key| sealed_error_label(id, key) }.uniq
          raise_sealed_not_found(labels, records.size, wanted.size)
        end

        scope.order_values.any? ? records : records.index_by(&:id).values_at(*wanted)
      end

      # Never echoes a raw primary key, and bounds whatever the caller sent so it can't bloat logs.
      def sealed_error_label(id, key)
        (key && sealed_id_codec.encode(key)) || id.to_s.truncate(64)
      end

      def raise_sealed_not_found(ids, result_size, expected_size)
        if ids.size == 1
          error = "Couldn't find #{name} with '#{primary_key}'=#{ids.first.inspect}"
        else
          error = "Couldn't find all #{name.pluralize} with '#{primary_key}': "
          error += "(#{ids.map(&:inspect).join(', ')}) (found #{result_size} results, but was looking for #{expected_size})"
        end

        raise ActiveRecord::RecordNotFound.new(error, name, primary_key, ids)
      end
    end

    # Makes queries understand tokens. ActiveRecord would otherwise cast "7a3d54ce-..." to 7 and act on a different
    # record, which is how Foo.delete(token) would remove the wrong row.
    module RelationMethods
      include FinderMethods

      # Everything built on +where+ passes through here, including delete_by, destroy_by and Foo.delete.
      def where!(opts, *rest)
        opts = klass.sealed_conditions(opts) if opts.is_a?(Hash) && klass.respond_to?(:sealed_conditions)
        super
      end

      def exists?(conditions = :none)
        return super unless klass.respond_to?(:sealed_conditions)

        conditions = { primary_key => conditions } if conditions.is_a?(String) && Codec::FORMAT.match?(conditions)
        super(klass.sealed_conditions(conditions))
      end
    end

    module ClassMethods
      include FinderMethods

      # Matches no record, for a token that isn't valid.
      NO_RECORD = -1

      # The class-level find_by has its own fast path, which skips +where+.
      def find_by(arg, *args)
        super(sealed_conditions(arg), *args)
      end

      # Replaces tokens in query conditions with the primary keys they stand for. A token is never right for an integer
      # column, so this can't change what a correct query means.
      def sealed_conditions(conditions)
        return conditions unless conditions.is_a?(Hash)

        conditions.to_h { |column, value| [column, sealed_condition_value(column.to_s, value)] }
      end

      # Building a codec derives keys, so keep the last one. It is keyed by secret because a callable secret may vary,
      # and the pair is swapped in whole so concurrent readers never see a mismatch.
      def sealed_id_codec
        secret = sealed_id_secret
        cached_secret, cached = @sealed_id_codec_cache
        return cached if cached && cached_secret == secret

        scope = sealed_id_options[:scope] || base_class.name
        Codec.new(secret, scope).tap { |codec| @sealed_id_codec_cache = [secret, codec].freeze }
      end

      # Returns the primary key for a token, or nil if the token isn't valid for this model.
      def unseal(token)
        return unless token.is_a?(String) && token.valid_encoding? && token.length <= MAX_TOKEN_LENGTH

        sealed_id_codec.decode(token) || unseal_legacy(token)
      end

      # A relation of the records with these tokens. Raises SealedId::InvalidToken if any token isn't valid.
      def with_sealed_ids(*tokens)
        tokens = tokens.flatten
        keys = tokens.map { |token| unseal(token) }
        raise InvalidToken, "Invalid sealed id: #{tokens.inspect.truncate(200)}" if keys.include?(nil)

        where(primary_key => keys)
      end

      # Resolves a value given to +find+ to a primary key, or nil if it can't refer to a record.
      #
      # Numerics are trusted because application code and Rails itself pass them around. Strings may come from a URL,
      # so they must be valid tokens, unless the caller opted in with SealedId.with_raw_ids.
      def sealed_id_to_primary_key(value)
        return value.to_i if value.is_a?(Numeric)
        return unless value.is_a?(String) && value.valid_encoding?
        return value.to_i if SealedId.raw_ids? && value.match?(/\A\d{1,20}\z/)

        unseal(value)
      end

      # Only integer keys can be sealed. Others (UUIDs, composite keys) keep ActiveRecord's behavior, so the macro can
      # sit on ApplicationRecord alongside such models.
      def sealed_primary_key?
        primary_key.is_a?(String) && type_for_attribute(primary_key).type == :integer
      end

      def has_many(*args, &block) # rubocop:disable Naming/PredicatePrefix
        options = args.extract_options!
        options[:extend] = Array(options[:extend]) + [RelationMethods]
        super(*args, **options, &block)
      end

      def relation
        r = super
        r.extend RelationMethods
        r
      end

      private

      def sealed_condition_value(column, value)
        return value.map { |item| sealed_condition_value(column, item) } if value.is_a?(Array)
        return value unless value.is_a?(String) && Codec::FORMAT.match?(value)
        return value unless type_for_attribute(column).type == :integer

        target = column == primary_key ? self : sealed_foreign_key_target(column)
        (target.respond_to?(:unseal) && target.unseal(value)) || NO_RECORD
      end

      def sealed_foreign_key_target(column)
        reflection = reflect_on_all_associations(:belongs_to).find { |r| r.foreign_key.to_s == column }
        reflection.klass if reflection && !reflection.polymorphic?
      end

      def unseal_legacy(token)
        legacy = sealed_id_options[:legacy]
        return if legacy.nil? || Codec::FORMAT.match?(token)

        key = instance_exec(token, &legacy)
        key if key.is_a?(Integer)
      rescue ArgumentError
        nil
      end

      def sealed_id_secret
        secret = sealed_id_options[:secret] || SealedId.secret
        secret.respond_to?(:call) ? instance_exec(&secret) : secret
      end
    end
  end
end
