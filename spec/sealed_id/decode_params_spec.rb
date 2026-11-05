require 'sealed_id/decode_params'

RSpec.describe SealedId::DecodeParams do
  subject(:controller) { Class.new { include SealedId::DecodeParams }.new }

  def decode(model, params)
    controller.send(:decode_params, model, params)
  end

  before do
    stub_const('Program', Class.new(ActiveRecord::Base) do
      self.table_name = :foos
      sealed_id
    end)
    stub_const('Plain', Class.new(ActiveRecord::Base) { self.table_name = :plains })
    stub_const('Bar', Class.new(ActiveRecord::Base) do
      self.table_name = :bars
      sealed_id
      belongs_to :foo, class_name: 'Program', optional: true
      belongs_to :previous_program, class_name: 'Program', foreign_key: :foo_id, inverse_of: false, optional: true
      belongs_to :plain, optional: true
      belongs_to :owner, polymorphic: true, optional: true
    end)
    stub_const('Owner', Class.new(ActiveRecord::Base) do
      self.table_name = :foos
      sealed_id
      has_many :bars, foreign_key: :foo_id, inverse_of: false
      has_many :categories, class_name: 'Bar', foreign_key: :foo_id, inverse_of: false
      accepts_nested_attributes_for :bars
    end)
  end

  let(:token) { Program.sealed_id_codec.encode(5) }
  let(:bar_token) { Bar.sealed_id_codec.encode(7) }

  it 'decodes id with the model itself' do
    expect(decode(Bar, id: bar_token)[:id]).to eq 7
  end

  it 'decodes a belongs_to foreign key with the associated model' do
    expect(decode(Bar, foo_id: token)[:foo_id]).to eq 5
  end

  it 'finds the association by foreign key when its name differs' do
    klass = Class.new(ActiveRecord::Base) do
      define_singleton_method(:name) { 'Transfer' }
      self.table_name = :bars
      sealed_id
      belongs_to :previous_program, class_name: 'Program', foreign_key: :foo_id, inverse_of: false, optional: true
    end
    expect(decode(klass, foo_id: token)[:foo_id]).to eq 5
  end

  it 'decodes *_ids with the associated model' do
    expect(decode(Owner, bar_ids: [bar_token])[:bar_ids]).to eq [7]
  end

  it 'uses real pluralization for *_ids' do
    expect(decode(Owner, category_ids: [bar_token])[:category_ids]).to eq [7]
  end

  it 'decodes nested attributes given as a hash' do
    expect(decode(Owner, bars_attributes: { id: bar_token })[:bars_attributes][:id]).to eq 7
  end

  it 'decodes nested attributes given as an array' do
    expect(decode(Owner, bars_attributes: [{ id: bar_token }])[:bars_attributes][0][:id]).to eq 7
  end

  it 'decodes indexed nested attributes from forms' do
    decoded = decode(Owner, bars_attributes: { '0' => { id: bar_token, foo_id: token } })
    expect(decoded[:bars_attributes]['0']).to eq('id' => 7, 'foo_id' => 5)
  end

  it 'keeps the raw id fields_for emits for nested records' do
    decoded = decode(Owner, bars_attributes: { '0' => { id: '7', foo_id: token } })
    expect(decoded[:bars_attributes]['0']).to eq('id' => '7', 'foo_id' => 5)
  end

  it 'still refuses a raw foreign key inside nested attributes' do
    expect { decode(Owner, bars_attributes: { '0' => { foo_id: '5' } }) }.to raise_error(SealedId::InvalidToken)
  end

  it 'still refuses a raw id at the top level' do
    expect { decode(Bar, id: '7') }.to raise_error(SealedId::InvalidToken)
  end

  it 'leaves other keys alone' do
    expect(decode(Bar, name: 'x', national_id: '12ab')).to eq('name' => 'x', 'national_id' => '12ab')
  end

  it 'leaves ids for models without the macro alone' do
    expect(decode(Bar, plain_id: '3')[:plain_id]).to eq '3'
  end

  it 'keeps blanks so a form can clear an association' do
    expect(decode(Owner, bar_ids: [''], id: '')).to eq('bar_ids' => [''], 'id' => '')
  end

  it 'accepts permitted parameters' do
    params = ActionController::Parameters.new(foo_id: token).permit(:foo_id)
    expect(decode(Bar, params)[:foo_id]).to eq 5
  end

  it 'refuses unpermitted parameters' do
    params = ActionController::Parameters.new(foo_id: token)
    expect { decode(Bar, params) }.to raise_error(ActionController::UnfilteredParameters)
  end

  [['a raw id string', '5'], ['a raw JSON integer', 5], ['garbage', '@@@'],
   ['a cast-looking token', '12abcdef']].each do |label, value|
    it "raises for #{label} rather than clearing the association or casting it" do
      expect { decode(Bar, foo_id: value) }.to raise_error(SealedId::InvalidToken)
    end
  end

  it 'raises for a token issued for another model' do
    expect { decode(Bar, foo_id: bar_token) }.to raise_error(SealedId::InvalidToken)
  end

  it 'refuses to guess a polymorphic key' do
    expect { decode(Bar, owner_id: token) }.to raise_error(ArgumentError, /polymorphic|which model/)
  end
end
