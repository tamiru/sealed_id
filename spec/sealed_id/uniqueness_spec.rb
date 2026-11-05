class UniqueFoo < ActiveRecord::Base
  self.table_name = :foos
  sealed_id
end

class UniqueBar < ActiveRecord::Base
  self.table_name = :bars
  sealed_id
end

class UniqueOwnSecret < ActiveRecord::Base
  self.table_name = :plains
  sealed_id secret: OTHER_SECRET
end

class UniqueParent < ActiveRecord::Base
  self.table_name = :foos
  sealed_id scope: 'unique-parent'
end

class UniqueChild < UniqueParent; end

class UniqueWithoutMacro < ActiveRecord::Base
  self.table_name = :foos
end

RSpec.describe 'token uniqueness and model identity' do
  describe 'uniqueness' do
    let(:codecs) { %w[Student Teacher Course Zone Region].map { |scope| SealedId::Codec.new(TEST_SECRET, scope) } }

    it 'never gives two records in one model the same token' do
      tokens = (0..20_000).map { |id| UniqueFoo.sealed_id_codec.encode(id) }
      expect(tokens.uniq.size).to eq tokens.size
    end

    it 'gives the same id a different token in each model' do
      expect(codecs.map { |codec| codec.encode(1) }.uniq.size).to eq codecs.size
    end

    it 'never repeats a token across models' do
      tokens = codecs.flat_map { |codec| (1..5_000).map { |id| codec.encode(id) } }
      expect(tokens.uniq.size).to eq 25_000
    end

    it 'is the same token every time for one record' do
      record = UniqueFoo.create!
      expect(Array.new(3) { UniqueFoo.find(record.id).to_param }.uniq).to eq [record.to_param]
    end

    it 'uses one key for every model, which is what makes uniqueness certain rather than likely' do
      keys = codecs.map { |codec| codec.instance_variable_get(:@key) }
      expect(keys.uniq.size).to eq 1
    end

    it 'gives each model its own tag' do
      expect(codecs.map(&:tag).uniq.size).to eq codecs.size
    end
  end

  describe 'SealedId.model_for' do
    it 'knows which model a token belongs to' do
      expect(SealedId.model_for(UniqueFoo.sealed_id_codec.encode(7))).to eq UniqueFoo
    end

    it 'tells apart two models with the same id' do
      models = [UniqueFoo, UniqueBar].map { |model| SealedId.model_for(model.sealed_id_codec.encode(7)) }
      expect(models).to eq [UniqueFoo, UniqueBar]
    end

    it 'knows models with their own secret' do
      expect(SealedId.model_for(UniqueOwnSecret.sealed_id_codec.encode(7))).to eq UniqueOwnSecret
    end

    it 'gives the base class for single-table inheritance' do
      expect(SealedId.model_for(UniqueChild.sealed_id_codec.encode(7))).to eq UniqueParent
    end

    ['@@@', '', nil, 5, '5', "\xFF", '00000000-0000-4000-8000-000000000000', 'a' * 100_000].each do |value|
      it "is nil for #{value.inspect[0, 30]}" do
        expect(SealedId.model_for(value)).to be_nil
      end
    end

    it 'is nil for a token issued under another secret' do
      expect(SealedId.model_for(SealedId::Codec.new('zyxwvutsrqponmlkjihgfedcba987654', 'UniqueFoo').encode(7))).to be_nil
    end

    it 'does not offer models without the macro' do
      expect(SealedId.models).not_to include(UniqueWithoutMacro)
    end
  end

  describe 'SealedId.locate' do
    let!(:foo) { UniqueFoo.create! }

    it 'finds the record from the token alone' do
      expect(SealedId.locate(foo.to_param)).to eq foo
    end

    it 'finds the right record when two models use the same id' do
      bar = UniqueBar.create!(id: foo.id)
      expect([SealedId.locate(foo.to_param), SealedId.locate(bar.to_param)]).to eq [foo, bar]
    end

    it 'is nil when the record was deleted' do
      token = foo.to_param
      foo.destroy
      expect(SealedId.locate(token)).to be_nil
    end

    it 'is nil for garbage' do
      expect(SealedId.locate('@@@')).to be_nil
    end

    it 'SealedId.find raises when there is no record' do
      expect { SealedId.find('@@@') }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'SealedId.find returns the record' do
      expect(SealedId.find(foo.to_param)).to eq foo
    end
  end

  describe 'two models sharing a scope' do
    before do
      stub_const('CollideOne', Class.new(ActiveRecord::Base) do
        self.table_name = :foos
        sealed_id scope: 'shared'
      end)
      stub_const('CollideTwo', Class.new(ActiveRecord::Base) do
        self.table_name = :bars
        sealed_id scope: 'shared'
      end)
    end

    it 'is refused, because their tokens could collide' do
      expect { SealedId.models }.to raise_error(SealedId::Error, /CollideOne.*CollideTwo|CollideTwo.*CollideOne/)
    end
  end
end
