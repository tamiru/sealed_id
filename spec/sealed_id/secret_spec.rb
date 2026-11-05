RSpec.describe 'choosing the secret' do
  around do |example|
    assigned = SealedId.instance_variable_get(:@secret)
    environment = ENV.fetch('SEALED_ID_SECRET', nil)
    SealedId.secret = nil
    ENV.delete('SEALED_ID_SECRET')
    example.run
  ensure
    SealedId.secret = assigned
    environment ? ENV['SEALED_ID_SECRET'] = environment : ENV.delete('SEALED_ID_SECRET')
  end

  let(:klass) do
    Class.new(ActiveRecord::Base) do
      define_singleton_method(:name) { 'SecretFoo' }
      self.table_name = :foos
      sealed_id
    end
  end

  it 'reads SEALED_ID_SECRET' do
    ENV['SEALED_ID_SECRET'] = TEST_SECRET
    expect(SealedId.secret).to eq TEST_SECRET
  end

  it 'gives the same tokens on any machine with the same value' do
    ENV['SEALED_ID_SECRET'] = TEST_SECRET
    expect(klass.sealed_id_codec.encode(1)).to eq SealedId::Codec.new(TEST_SECRET, 'SecretFoo').encode(1)
  end

  it 'treats an empty value as unset' do
    ENV['SEALED_ID_SECRET'] = ''
    expect(SealedId.secret).to be_nil
  end

  it 'refuses to run with neither' do
    expect { klass.sealed_id_codec }.to raise_error(ArgumentError, /32 bytes/)
  end

  it 'prefers an explicitly assigned secret' do
    ENV['SEALED_ID_SECRET'] = TEST_SECRET
    SealedId.secret = OTHER_SECRET
    expect(SealedId.secret).to eq OTHER_SECRET
  end

  it 'prefers a secret set on the model' do
    ENV['SEALED_ID_SECRET'] = TEST_SECRET
    own = Class.new(ActiveRecord::Base) do
      define_singleton_method(:name) { 'SecretFoo' }
      self.table_name = :foos
      sealed_id secret: OTHER_SECRET
    end
    expect(own.sealed_id_codec.encode(1)).to eq SealedId::Codec.new(OTHER_SECRET, 'SecretFoo').encode(1)
  end
end
