require 'openssl'
require 'active_support/security_utils'

module SealedId
  # Encodes an integer id as a version 8 UUID (RFC 9562) using deterministic authenticated encryption.
  #
  # The 122 free bits hold a 58-bit tag, an HMAC of the id, and the 64-bit id encrypted with a keystream derived from
  # that tag. Each id maps to exactly one of 2^122 values and the rest fail authentication, so without the key a guess
  # succeeds with the same probability as guessing a random UUIDv4. Two ids sharing a tag reveal the XOR of those two
  # ids; that takes roughly 2^29 records to become likely and exposes nothing else.
  class Codec
    MIN_SECRET_BYTES = 32
    MAX_ID = (2**64) - 1
    TAG_MASK = (2**58) - 1
    LOW_MASK = (2**62) - 1
    # Lowercase only, so each id has exactly one valid token.
    FORMAT = /\A([0-9a-f]{8})-([0-9a-f]{4})-8([0-9a-f]{3})-([89ab][0-9a-f]{3})-([0-9a-f]{12})\z/.freeze

    def initialize(secret, scope)
      if secret.to_s.bytesize < MIN_SECRET_BYTES
        raise ArgumentError, "sealed_id needs a secret of at least #{MIN_SECRET_BYTES} bytes. " \
                             'Set SealedId.secret, or pass secret: to the model.'
      end

      @mac_key = derive_key(secret, 'mac', scope)
      @enc_key = derive_key(secret, 'enc', scope)
    end

    # Returns the token for an id, or nil if the id can't be encoded.
    def encode(id)
      return unless id.is_a?(Integer) && id.between?(0, MAX_ID)

      tag = tag_for(id)
      format_uuid((tag << 64) | (id ^ keystream(tag)))
    end

    # Returns the id for a token this key produced, or nil for anything else.
    def decode(token)
      value = parse_uuid(token)
      return unless value

      tag = value >> 64
      id = (value & MAX_ID) ^ keystream(tag)
      id if ActiveSupport::SecurityUtils.secure_compare(tag.to_s, tag_for(id).to_s)
    end

    private

    def derive_key(secret, purpose, scope)
      OpenSSL::HMAC.digest('SHA256', secret.to_s, "sealed_id/v1/#{purpose}/#{scope}")
    end

    def tag_for(id)
      prf(@mac_key, id) & TAG_MASK
    end

    def keystream(tag)
      prf(@enc_key, tag)
    end

    def prf(key, number)
      OpenSSL::HMAC.digest('SHA256', key, [number].pack('Q>')).unpack1('Q>')
    end

    def format_uuid(value)
      high = value >> 74
      mid = (value >> 62) & 0xfff
      low = (0b10 << 62) | (value & LOW_MASK)
      hex = format('%<high>012x8%<mid>03x%<low>016x', high: high, mid: mid, low: low)
      "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
    end

    def parse_uuid(token)
      match = FORMAT.match(token)
      return unless match

      high = "#{match[1]}#{match[2]}".to_i(16)
      low = "#{match[4]}#{match[5]}".to_i(16) & LOW_MASK
      (high << 74) | (match[3].to_i(16) << 62) | low
    end
  end
end
