require 'securerandom'

RSpec.describe SealedId::Codec do
  subject(:codec) { described_class.new(TEST_SECRET, 'Foo') }

  it 'produces a UUID-shaped token' do
    expect(codec.encode(1)).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
  end

  it 'keeps the wire format stable, because changing it would break every existing URL' do
    expect(codec.encode(1)).to eq '52b3f823-016c-5262-b8ee-9658c76aac9f'
  end

  it 'matches an independent AES-256 calculation, so the format is the standard cipher and nothing else' do
    key = OpenSSL::HMAC.digest('SHA256', TEST_SECRET, 'sealed_id/v1/aes')
    cipher = OpenSSL::Cipher.new('aes-256-ecb').encrypt
    cipher.key = key
    cipher.padding = 0
    block = [1].pack('Q>') + OpenSSL::Digest.digest('SHA256', 'Foo')[0, 4] + "\0\0\0\0".b
    expect(codec.encode(1).delete('-')).to eq((cipher.update(block) + cipher.final).unpack1('H*'))
  end

  it 'gives consecutive ids unrelated values' do
    a, b = [1, 2].map { |id| codec.encode(id).delete('-') }
    expect(a.chars.zip(b.chars).count { |x, y| x == y }).to be < 12
  end

  it 'never repeats a value' do
    expect((1..5_000).map { |id| codec.encode(id) }.uniq.size).to eq 5_000
  end

  [0, 1, 255, 2**32, (2**63) - 1, (2**64) - 1].each do |id|
    it "round-trips #{id}" do
      expect(codec.decode(codec.encode(id))).to eq id
    end
  end

  [-1, 2**64, nil, '1', 1.5].each do |id|
    it "refuses to encode #{id.inspect}" do
      expect(codec.encode(id)).to be_nil
    end
  end

  it 'rejects every single-character change' do
    token = codec.encode(1234)
    changed = token.chars.each_index.reject { |i| token[i] == '-' }.map do |i|
      token.dup.tap { |t| t[i] = t[i] == '0' ? '1' : '0' }
    end
    expect(changed.filter_map { |t| codec.decode(t) }).to eq []
  end

  it 'rejects random UUIDs' do
    expect(Array.new(5_000) { SecureRandom.uuid }.filter_map { |t| codec.decode(t) }).to eq []
  end

  it 'rejects a token from another secret' do
    expect(codec.decode(described_class.new(OTHER_SECRET, 'Foo').encode(1))).to be_nil
  end

  it 'rejects a token from another scope' do
    expect(codec.decode(described_class.new(TEST_SECRET, 'Bar').encode(1))).to be_nil
  end

  it 'rejects uppercase, so each id has one valid token' do
    expect(codec.decode(codec.encode(1).upcase)).to be_nil
  end

  it 'rejects a trailing newline' do
    expect(codec.decode("#{codec.encode(1)}\n")).to be_nil
  end

  [nil, 1, '', "\xFF" * 16].each do |input|
    it "rejects #{input.inspect[0, 20]}" do
      expect(codec.decode(input)).to be_nil
    end
  end

  [nil, '', 'short', 'abcdefgh' * 3].each do |secret|
    it "rejects the short secret #{secret.inspect}" do
      expect { described_class.new(secret, 'Foo') }.to raise_error(ArgumentError, /32 bytes/)
    end
  end

  ['k' * 32, 'x' * 64, 'abc' * 20].each do |secret|
    it "rejects the placeholder secret #{secret[0, 6]}..." do
      expect { described_class.new(secret, 'Foo') }.to raise_error(ArgumentError, /random secret/)
    end
  end

  it 'accepts a generated hex secret' do
    expect { described_class.new(SecureRandom.hex(64), 'Foo') }.not_to raise_error
  end

  it 'gives the same results across threads' do
    expected = codec.encode(12_345)
    results = Array.new(8) { Thread.new { Array.new(200) { codec.encode(12_345) } } }.flat_map(&:value)
    expect(results.uniq).to eq [expected]
  end
end
