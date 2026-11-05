require 'openssl'

module SealedId
  # Encodes an integer id as a UUID-shaped token by encrypting a single AES block, which holds the 64-bit id, a 32-bit
  # tag naming the model, and 32 zero bits.
  #
  # Every model shares one key, so tokens are unique by construction: AES is one-to-one for a given key, and no two
  # records have the same id and tag. The tag also lets the server tell which model a token belongs to.
  #
  # AES is a pseudorandom permutation, so without the key every token looks like 128 random bits, and knowing other id
  # and token pairs doesn't help. A guess hits an existing record with probability records / 2^128. The tag and zero
  # bits authenticate the block: a changed token decrypts to random bits, which pass for a given model with probability
  # 2^-64, and even then only count if that id exists.
  #
  # ECB is safe here because only one block is ever encrypted, and a repeatable token for each id is the point.
  class Codec
    MIN_SECRET_BYTES = 32
    MIN_DISTINCT_BYTES = 8
    MAX_ID = (2**64) - 1
    # Lowercase only, so each id has exactly one valid token.
    FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/.freeze

    attr_reader :tag

    def initialize(secret, scope)
      check_secret(secret.to_s)
      @key = OpenSSL::HMAC.digest('SHA256', secret.to_s, 'sealed_id/v1/aes')
      @tag = OpenSSL::Digest::SHA256.digest(scope.to_s).unpack1('N')
    end

    # Returns the token for an id, or nil if the id can't be encoded.
    def encode(id)
      return unless id.is_a?(Integer) && id.between?(0, MAX_ID)

      hex = aes(:encrypt, [id, tag, 0].pack('Q>NN')).unpack1('H*')
      "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
    end

    # Returns the id for a token issued to this model with this key, or nil for anything else.
    def decode(token)
      return unless token.is_a?(String) && token.valid_encoding? && FORMAT.match?(token)

      id, token_tag, check = aes(:decrypt, [token.delete('-')].pack('H*')).unpack('Q>NN')
      id if token_tag == tag && check.zero?
    end

    private

    # A cipher object holds state, so each call builds its own to stay thread safe.
    def aes(direction, block)
      cipher = OpenSSL::Cipher.new('aes-256-ecb').public_send(direction)
      cipher.key = @key
      cipher.padding = 0
      cipher.update(block) + cipher.final
    end

    # Can't measure randomness, but does catch placeholders such as "x" * 32 before tokens are issued with them.
    def check_secret(secret)
      if secret.bytesize < MIN_SECRET_BYTES
        raise ArgumentError, "sealed_id needs a secret of at least #{MIN_SECRET_BYTES} bytes. " \
                             'Set SealedId.secret, or pass secret: to the model.'
      end
      return if secret.bytes.uniq.size >= MIN_DISTINCT_BYTES

      raise ArgumentError, 'sealed_id needs a random secret, but this one repeats too few characters. ' \
                           'Generate one with `bin/rails secret`.'
    end
  end
end
