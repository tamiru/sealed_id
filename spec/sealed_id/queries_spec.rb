# Permanent, because Rails 6 caches the class behind an association name across examples.
class QueryFoo < ActiveRecord::Base
  self.table_name = :foos
  sealed_id
end

class QueryBar < ActiveRecord::Base
  self.table_name = :bars
  sealed_id
  belongs_to :foo, class_name: 'QueryFoo', optional: true
end

class QueryLegacyFoo < ActiveRecord::Base
  self.table_name = :foos
  sealed_id legacy: ->(token) { token.delete_prefix('old').to_i if token.start_with?('old') }
end

# ActiveRecord would cast a token to the integer at its start, so these act on a different record unless handled.
RSpec.describe 'queries given a token' do
  let!(:target) { QueryFoo.create! }
  # A token that casts to a real, different record: the dangerous case.
  let(:token) { pick_token }
  let(:bystander) { QueryFoo.create!(id: token.to_i) }

  def pick_token
    @pick_token ||= begin
      id = (target.id..(target.id + 5_000)).find do |candidate|
        cast = QueryFoo.sealed_id_codec.encode(candidate).to_i
        cast.positive? && cast != candidate
      end
      QueryFoo.create!(id: id) unless QueryFoo.exists?(id)
      QueryFoo.sealed_id_codec.encode(id)
    end
  end

  def token_record
    QueryFoo.find(token)
  end

  before { bystander }

  it 'really is the dangerous case' do
    expect([token.to_i, token_record.id == token.to_i]).to eq [bystander.id, false]
  end

  it 'where finds the right record' do
    expect(QueryFoo.where(id: token).to_a).to eq [token_record]
  end

  it 'where accepts a string key' do
    expect(QueryFoo.where('id' => token).to_a).to eq [token_record]
  end

  it 'where accepts an array of tokens' do
    expect(QueryFoo.where(id: [token, target.to_param]).to_a).to match_array([token_record, target].uniq)
  end

  it 'where on a relation finds the right record' do
    expect(QueryFoo.order(:id).where(id: token).to_a).to eq [token_record]
  end

  it 'find_by finds the right record' do
    expect(QueryFoo.find_by(id: token)).to eq token_record
  end

  it 'find_by on a relation finds the right record' do
    expect(QueryFoo.where.not(id: nil).find_by(id: token)).to eq token_record
  end

  it 'find_by! finds the right record' do
    expect(QueryFoo.find_by!(id: token)).to eq token_record
  end

  it 'exists? with a token checks the right record' do
    id = token_record.id
    QueryFoo.where(id: id).delete_all
    expect(QueryFoo.exists?(token)).to be false
  end

  it 'exists? with a hash checks the right record' do
    id = token_record.id
    QueryFoo.where(id: id).delete_all
    expect(QueryFoo.exists?(id: token)).to be false
  end

  it 'exists? still works with a token, integers and no argument' do
    expect([QueryFoo.exists?(token), QueryFoo.exists?(target.id), QueryFoo.exists?]).to eq [true, true, true]
  end

  it 'delete removes the right record and leaves the other alone' do
    id = token_record.id
    expect(QueryFoo.delete(token)).to eq 1
    expect([QueryFoo.exists?(id), QueryFoo.exists?(bystander.id)]).to eq [false, true]
  end

  it 'delete with an array removes the right records' do
    id = token_record.id
    QueryFoo.delete([token])
    expect([QueryFoo.exists?(id), QueryFoo.exists?(bystander.id)]).to eq [false, true]
  end

  it 'destroy_by removes the right record' do
    expect(QueryFoo.destroy_by(id: token).map(&:id)).to eq [QueryFoo.unseal(token)]
    expect(QueryFoo.exists?(bystander.id)).to be true
  end

  it 'delete_by removes the right record' do
    QueryFoo.delete_by(id: token)
    expect([QueryFoo.exists?(QueryFoo.unseal(token)), QueryFoo.exists?(bystander.id)]).to eq [false, true]
  end

  it 'destroy with a token removes the right record' do
    QueryFoo.destroy(token)
    expect([QueryFoo.exists?(QueryFoo.unseal(token)), QueryFoo.exists?(bystander.id)]).to eq [false, true]
  end

  it 'update_all through where touches only the right record' do
    bar = QueryBar.create!(foo_id: bystander.id)
    QueryBar.where(foo_id: token).update_all(foo_id: nil)
    expect(bar.reload.foo_id).to eq bystander.id
  end

  it 'decodes a foreign key with the associated model' do
    bar = QueryBar.create!(foo_id: QueryFoo.unseal(token))
    other = QueryBar.create!(foo_id: bystander.id)
    expect(QueryBar.where(foo_id: token).to_a).to eq [bar]
    expect(QueryBar.where(foo_id: token).to_a).not_to include(other)
  end

  it 'finds nothing for a forged token rather than the integer it starts with' do
    forged = '77777777-7777-4777-8777-777777777777'
    QueryFoo.create!(id: 77_777_777)
    expect(QueryFoo.where(id: forged).to_a).to eq []
  end

  it 'does not delete anything for a forged token' do
    QueryFoo.create!(id: 77_777_777)
    expect(QueryFoo.delete('77777777-7777-4777-8777-777777777777')).to eq 0
  end

  it 'leaves integers and other values alone' do
    expect(QueryFoo.where(id: target.id).to_a).to eq [target]
  end

  it 'leaves UUID values in string columns alone' do
    uuid = '77777777-7777-4777-8777-777777777777'
    klass = Class.new(ActiveRecord::Base) do
      define_singleton_method(:name) { 'UuidKeyed' }
      self.table_name = :uuid_things
      sealed_id
    end
    record = klass.create!(id: uuid)
    expect(klass.where(id: uuid).to_a).to eq [record]
  end

  it 'still understands legacy ids through unseal, not through cast queries' do
    expect(QueryLegacyFoo.unseal("old#{target.id}")).to eq target.id
  end
end
