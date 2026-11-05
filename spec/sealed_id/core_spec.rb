# Permanent, because Rails 6 caches the class behind an association name across examples.
class AssociatedBar < ActiveRecord::Base
  self.table_name = :bars
  sealed_id
end

class AssociatedPlain < ActiveRecord::Base
  self.table_name = :plains
end

RSpec.describe SealedId::Core do
  def build_model(table, name, include_gid: false, **options)
    Class.new(ActiveRecord::Base) do
      define_singleton_method(:name) { name }
      self.table_name = table
      include GlobalID::Identification if include_gid
      sealed_id(**options)
    end
  end

  let(:model) { build_model(:foos, 'Foo') }
  let!(:one) { model.create! }
  let!(:two) { model.create! }

  describe '#to_param' do
    it 'returns the sealed id' do
      expect(one.to_param).to eq one.sealed_id
    end

    it 'is nil before saving' do
      expect(model.new.to_param).to be_nil
    end
  end

  describe '.find' do
    it 'finds by token' do
      expect(model.find(one.to_param)).to eq one
    end

    it 'finds by integer, for application code' do
      expect(model.find(one.id)).to eq one
    end

    it 'still reloads' do
      expect(one.reload).to eq one
    end

    [
      :raw, '@@@', '-1', '', ' ', '0x1', '1_0', "1\n", '+1', '1.5', "\xFF", "\xFF".b, "1\u0000",
      "'; DROP TABLE foos; --", nil, :sym, { a: 1 }, 'a' * 1_000_000
    ].each do |input|
      it "raises RecordNotFound for #{input.inspect[0, 30]}" do
        value = input == :raw ? one.id.to_s : input
        expect { model.find(value) }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    it 'does not echo long input into the message' do
      expect { model.find('@' * 10_000) }.to raise_error(ActiveRecord::RecordNotFound) { |e|
        expect(e.message.length).to be < 150
      }
    end

    it 'does not echo a raw id into the message' do
      missing = model.maximum(:id) + 100
      expect { model.find(missing) }.to raise_error(ActiveRecord::RecordNotFound) { |e|
        expect(e.message).not_to include("'=#{missing}")
      }
    end

    it 'exposes not-found details for rescue handlers' do
      expect { model.find('@@@') }.to raise_error(ActiveRecord::RecordNotFound) { |e|
        expect([e.model, e.primary_key]).to eq %w[Foo id]
      }
    end

    it 'refuses a token issued for another model' do
      other = build_model(:foos, 'Other')
      expect { model.find(other.find(one.id).to_param) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'accepts several arguments' do
      expect(model.find(one.to_param, two.to_param)).to eq [one, two]
    end

    it 'returns records in the requested order' do
      expect(model.find([two.to_param, one.to_param])).to eq [two, one]
    end

    it 'honours an explicit order' do
      expect(model.order(id: :desc).find([one.to_param, two.to_param])).to eq [two, one]
    end

    it 'returns an array for an array' do
      expect(model.find([one.to_param])).to be_an(Array)
    end

    it 'returns an empty array for an empty array' do
      expect(model.find([])).to eq []
    end

    it 'tolerates duplicates' do
      expect(model.find([one.to_param, one.id])).to eq [one]
    end

    it 'raises if any id in a batch is invalid' do
      expect { model.find([one.to_param, '@']) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'supports a block' do
      expect(model.find { |record| record == two }).to eq two
    end

    it 'runs a single query' do
      queries = []
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') { |*, p| queries << p[:sql] }
      model.find(one.to_param)
      ActiveSupport::Notifications.unsubscribe(subscriber)
      expect(queries.grep(/SELECT/).size).to eq 1
    end

    it 'honours relation scope' do
      expect { model.none.find(one.to_param) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe '.unseal' do
    it 'returns the id' do
      expect(model.unseal(one.to_param)).to eq one.id
    end

    [nil, 1, '@@@', "\xFF"].each do |input|
      it "returns nil for #{input.inspect}" do
        expect(model.unseal(input)).to be_nil
      end
    end
  end

  describe 'legacy tokens' do
    let(:old_id) { one.id }
    let(:calls) { [] }
    let(:legacy_model) do
      seen = calls
      build_model(:foos, 'Foo', legacy: lambda { |token|
        seen << token
        raise ArgumentError, 'bad' if token == 'raises'

        token.start_with?('old') ? token.delete_prefix('old').to_i : nil
      })
    end

    it 'accepts an id from the old scheme' do
      expect(legacy_model.find("old#{old_id}").id).to eq old_id
    end

    it 'still accepts sealed tokens' do
      expect(legacy_model.find(one.to_param).id).to eq old_id
    end

    it 'keeps issuing sealed tokens' do
      expect(legacy_model.find(old_id).to_param).to eq one.to_param
    end

    it 'treats a decoder ArgumentError as invalid' do
      expect(legacy_model.unseal('raises')).to be_nil
    end

    it 'does not offer a forged UUID to the decoder' do
      legacy_model.unseal(one.to_param.sub(/.\z/) { |c| c == '0' ? '1' : '0' })
      expect(calls).to eq []
    end

    it 'never passes oversized input to the decoder' do
      legacy_model.unseal('a' * 1_000_000)
      expect(calls).to eq []
    end

    it 'is off by default' do
      expect { model.find("old#{old_id}") }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe '.with_sealed_ids' do
    it 'returns a relation' do
      expect(model.with_sealed_ids(one.to_param, two.to_param).order(:id).to_a).to eq [one, two]
    end

    it 'raises for an invalid token' do
      expect { model.with_sealed_ids(one.to_param, '@') }.to raise_error(SealedId::InvalidToken)
    end

    it 'is catchable by a generic rescue' do
      expect(SealedId::InvalidToken.ancestors).to include(StandardError)
    end

    it 'bounds input echoed into the message' do
      expect { model.with_sealed_ids('@' * 10_000) }.to raise_error(SealedId::InvalidToken) { |e|
        expect(e.message.length).to be < 250
      }
    end
  end

  describe 'with_raw_ids' do
    it 'allows raw id strings only inside the block' do
      expect(SealedId.with_raw_ids { model.find(one.id.to_s) }).to eq one
      expect(SealedId.raw_ids?).to be false
    end

    it 'restores the state after an error' do
      expect { SealedId.with_raw_ids { raise 'boom' } }.to raise_error('boom')
      expect(SealedId.raw_ids?).to be false
    end
  end

  describe 'GlobalID' do
    before { SealedId.install_global_id_support }

    let(:klass) do
      stub_const('GlobalFoo', Class.new(ActiveRecord::Base) do
        self.table_name = :foos
        include GlobalID::Identification

        sealed_id
      end)
    end
    let(:record) { klass.create! }

    it 'round-trips through locate' do
      expect(GlobalID::Locator.locate(record.to_global_id)).to eq record
    end

    it 'round-trips through locate_many' do
      expect(GlobalID::Locator.locate_many([record.to_global_id])).to eq [record]
    end

    it 'round-trips a signed global id' do
      expect(GlobalID::Locator.locate_signed(record.to_sgid.to_s)).to eq record
    end
  end

  describe 'associations' do
    let(:bar_class) { AssociatedBar }
    let(:extension) do
      Module.new do
        def hi
          :hi
        end
      end
    end

    def owner_class(association = :bars, **options)
      target = { bars: 'AssociatedBar', plains: 'AssociatedPlain' }.fetch(association)
      Class.new(ActiveRecord::Base) do
        define_singleton_method(:name) { 'Owner' }
        self.table_name = :foos
        sealed_id
        has_many association, class_name: target, foreign_key: :foo_id, inverse_of: false, **options
      end
    end

    it 'finds its own record by token' do
      owner = owner_class.create!
      bar = bar_class.create!(foo_id: owner.id)
      expect(owner.bars.find(bar.to_param)).to eq bar
    end

    it 'cannot reach another owner\'s record by token' do
      theirs = bar_class.create!(foo_id: owner_class.create!.id)
      expect { owner_class.create!.bars.find(theirs.to_param) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'cannot reach another owner\'s record by integer' do
      theirs = bar_class.create!(foo_id: owner_class.create!.id)
      expect { owner_class.create!.bars.find(theirs.id) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'finds nothing through an unsaved owner' do
      theirs = bar_class.create!(foo_id: owner_class.create!.id)
      expect { owner_class.new.bars.find(theirs.to_param) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'accepts extend: with a module' do
      expect(owner_class(extend: extension).create!.bars.hi).to eq :hi
    end

    it 'accepts extend: with a frozen array' do
      expect(owner_class(extend: [extension].freeze).create!.bars.hi).to eq :hi
    end

    it 'leaves find alone on associated models without the macro' do
      owner = owner_class(:plains).create!
      plain = AssociatedPlain.create!(foo_id: owner.id)
      expect(owner.plains.find(plain.id)).to eq plain
    end
  end

  describe 'non-integer primary keys' do
    let(:klass) { build_model(:uuid_things, 'UuidThing') }
    let!(:record) { klass.create!(id: 'abc-123') }

    it 'keeps the normal param' do
      expect(record.to_param).to eq 'abc-123'
    end

    it 'keeps the normal find' do
      expect(klass.find('abc-123')).to eq record
    end
  end

  describe 'configuration' do
    it 'rejects misspelled options' do
      expect { build_model(:foos, 'Foo', secrte: 'x' * 32) }.to raise_error(ArgumentError, /secrte/)
    end

    it 'refuses to run with a short secret' do
      expect { build_model(:foos, 'Foo', secret: 'short').sealed_id_codec }.to raise_error(ArgumentError, /32 bytes/)
    end

    it 'refuses to run with no secret' do
      allow(SealedId).to receive(:secret).and_return(nil)
      expect { build_model(:foos, 'Foo').sealed_id_codec }.to raise_error(ArgumentError, /32 bytes/)
    end

    it 'uses a per-model secret over the global one' do
      other = build_model(:foos, 'Foo', secret: 'z' * 32)
      expect(other.sealed_id_codec.encode(1)).not_to eq model.sealed_id_codec.encode(1)
    end

    it 'follows a callable secret that changes' do
      current = 'a' * 32
      klass = build_model(:foos, 'Foo', secret: -> { current })
      first = klass.sealed_id_codec.encode(1)
      current = 'b' * 32
      expect(klass.sealed_id_codec.encode(1)).not_to eq first
    end

    it 'keeps tokens stable across a rename when scope is set' do
      before_rename = build_model(:foos, 'Foo', scope: 'foos').sealed_id_codec.encode(1)
      expect(build_model(:foos, 'Renamed', scope: 'foos').sealed_id_codec.encode(1)).to eq before_rename
    end

    it 'reuses the codec' do
      expect(model.sealed_id_codec).to equal(model.sealed_id_codec)
    end
  end
end
