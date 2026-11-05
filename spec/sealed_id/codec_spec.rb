require 'securerandom'

RSpec.describe SealedId::Codec do
  subject(:codec) { described_class.new('k' * 32, 'Foo') }

  it 'produces a valid RFC 9562 version 8 UUID' do
    expect(codec.encode(1)).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
  end

  it 'keeps the wire format stable, because changing it would break every existing URL' do
    expect(codec.encode(1)).to eq 'e909cdbf-7657-8efe-b10f-f8f6814d684b'
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

  it 'rejects random UUIDs of the same version' do
    guesses = Array.new(5_000) { SecureRandom.uuid.sub(/\A(.{14})./, '\18') }
    expect(guesses.filter_map { |t| codec.decode(t) }).to eq []
  end

  it 'rejects a token from another secret' do
    expect(codec.decode(described_class.new('z' * 32, 'Foo').encode(1))).to be_nil
  end

  it 'rejects a token from another scope' do
    expect(codec.decode(described_class.new('k' * 32, 'Bar').encode(1))).to be_nil
  end

  it 'rejects uppercase, so each id has one valid token' do
    expect(codec.decode(codec.encode(1).upcase)).to be_nil
  end

  it 'rejects a trailing newline' do
    expect(codec.decode("#{codec.encode(1)}\n")).to be_nil
  end

  [nil, '', 'short', 'k' * 31].each do |secret|
    it "rejects the secret #{secret.inspect}" do
      expect { described_class.new(secret, 'Foo') }.to raise_error(ArgumentError, /32 bytes/)
    end
  end

  it 'gives the same results across threads' do
    expected = codec.encode(12_345)
    results = Array.new(8) { Thread.new { Array.new(200) { codec.encode(12_345) } } }.flat_map(&:value)
    expect(results.uniq).to eq [expected]
  end
end
