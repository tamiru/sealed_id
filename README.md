# sealed_id

Unguessable, UUID-shaped public ids for ActiveRecord, with no new column or migration.

Your tables keep their integer primary keys. URLs get an encrypted token that can't be guessed, and raw ids from requests are refused.

```ruby
class Foo < ApplicationRecord
  sealed_id
end

foo = Foo.create
foo.id                 # => 1, still your integer primary key
foo.to_param           # => "d42fc60c-c23f-84e2-8a9c-7a3cd44e450c"

Foo.find(foo.to_param) # => #<Foo id: 1>
Foo.find("1")          # => ActiveRecord::RecordNotFound
Foo.find("garbage")    # => ActiveRecord::RecordNotFound
Foo.find(1)            # => #<Foo id: 1>
```

Your routes and `find` calls work unchanged, and invalid ids become a normal 404.

## Requirements

Ruby 2.7 or newer, and Rails or ActiveRecord 6.0 to 8.1. Primary keys must be integers up to 64 bits. Models with UUID or composite primary keys keep their normal behavior, so the macro can sit on `ApplicationRecord` alongside them.

## Installation

Add the gem to your Gemfile. It isn't on RubyGems yet, so install it from GitHub:

```ruby
gem "sealed_id", github: "tamiru/sealed_id"
```

### Set a secret

Tokens are derived from a secret of at least 32 bytes. **Changing the secret changes every public URL**, so choose one you won't need to rotate.

In Rails, the secret defaults to `secret_key_base`, but a dedicated value is safer because you can then rotate `secret_key_base` freely. Generate one with `bin/rails secret`, add it with `bin/rails credentials:edit`, then:

```ruby
# config/initializers/sealed_id.rb
SealedId.secret = Rails.application.credentials.sealed_id_secret!
```

Outside Rails, you must set `SealedId.secret` yourself.

## Usage

Put the macro on one model, or on `ApplicationRecord` for all of them.

```ruby
foo.sealed_id                # the token
Foo.unseal(token)            # the integer id, or nil if the token is invalid
Foo.with_sealed_ids(a, b)    # a relation; raises SealedId::InvalidToken for an invalid token
```

`find` also accepts several tokens and respects scopes, so `current_user.foos.find(token)` only finds that user's records.

### Options

```ruby
sealed_id secret: ENV.fetch("FOO_SECRET"), # overrides SealedId.secret; may be callable
          scope: "foos"                    # defaults to the base class name
```

Tokens are tied to the `scope`, so a token for one model is never valid for another. Before renaming a model, set `scope` to its current class name, or its URLs will change.

### Decoding form params

Forms send tokens for foreign keys too, so controllers get a private `decode_params` method. Pass the model and your permitted params:

```ruby
def student_params
  decode_params(Student, params.require(:student).permit(:name, :program_id, course_ids: []))
end
```

It handles `id`, `belongs_to` foreign keys (including custom `foreign_key:` names), `*_ids` and nested `*_attributes`, using your associations to choose the model for each key. Other keys and models without the macro are left alone, and blank values stay blank so forms can clear an association.

An invalid token raises `SealedId::InvalidToken`, which Rails returns as a 404. It never becomes `nil`, which would silently clear the association, and it never stays a string, which ActiveRecord would cast to the wrong integer. Raw ids are refused too, including integers in a JSON body.

Polymorphic keys raise `ArgumentError`, because the model can't be known safely. Check the type against an allow-list and call `Model.unseal` yourself.

### Nested forms

`fields_for` adds a hidden field holding the record's raw id, which `decode_params` refuses, so **an unchanged nested form returns a 404**. Emit the token instead:

```erb
<%= form.fields_for :kids, include_id: false do |kid| %>
  <%= kid.hidden_field :id, value: kid.object.to_param %>
  <%= kid.text_field :name %>
<% end %>
```

### Keeping old ids working

If ids from an earlier scheme must survive, such as on printed documents or QR codes, pass a `legacy` decoder. Old ids keep resolving while every new link uses a sealed token. This example needs the `hashids` gem in your Gemfile:

```ruby
class Student < ApplicationRecord
  OLD_IDS = Hashids.new("Student", 10) # the settings the old ids were issued with

  sealed_id legacy: lambda { |token|
    numbers = OLD_IDS.decode(token)
    numbers.first if numbers.one?
  }
end
```

The decoder takes a string of up to 64 characters and returns an integer id or `nil`. Raising `ArgumentError` also counts as invalid.

**Anything `legacy` accepts is only as hard to guess as the old scheme.** Use it only on models that need it, and remove it when the old ids no longer matter.

### ActiveJob and GlobalID

These keep working automatically. GlobalID stores the raw id, and sealed_id reads it as a raw id only on that internal path.

To look up a raw id string you produced yourself, use `SealedId.with_raw_ids { Foo.find("3") }`. Never do this with ids from a request.

## Security notes

- **Never pass a token to `delete`, `destroy_by`, `where(id:)`, `find_by(id:)` or `exists?`.** Only `find` and `with_sealed_ids` understand tokens. The others cast the string to an integer and act on **a different record**: `Foo.delete("7a3d54ce-...")` deletes record 7, whatever the token really refers to. Decode first with `Foo.unseal`, which returns `nil` for an invalid token.
- **This isn't access control.** Anyone holding a valid URL can use it, so always authorize access to the record you load.
- **Decoding isn't authorization.** `decode_params` confirms a token is valid, not that this user may link to that record. Check that separately.
- **`find` accepts integers.** A JSON body of `{"id": 3}` makes `params[:id]` an `Integer`, which `find` accepts because application code relies on it. Use `Foo.find(params[:id].to_s)` for ids from JSON. `decode_params` already refuses them.
- **Raw ids appear elsewhere.** `as_json` and `to_json` include `id`, while `dom_id`, `cache_key`, nested-form hidden fields and global ids all use the raw value. Remove them from anything public if the id itself is sensitive.

## How it works

Each id is encrypted and authenticated using HMAC-SHA256 with keys derived from your secret, then laid out as a valid version 8 UUID ([RFC 9562](https://www.rfc-editor.org/rfc/rfc9562)). The mapping is deterministic, so a record always has the same token, with no storage needed.

Each id maps to exactly one of 2^122 possible values, and all others are rejected. With a strong secret, a guess succeeds with the same odds as guessing a random UUIDv4, and tokens don't show ids, their order or how many records exist.

There are two limits to that. If two ids happen to share an internal 58-bit tag, their tokens reveal the XOR of those two ids. That only becomes likely at around 500 million records, and it exposes nothing else. This construction is also specific to this gem and **hasn't had an independent cryptographic review**.

| | sealed_id | Random UUID column |
| --- | --- | --- |
| Migration and backfill | Not needed | Required |
| Works on existing records | Yes | After backfill |
| If the secret leaks | All tokens can be decoded and forged | Nothing to leak |
| Replace one record's token | Not possible | Update the column |
| Change the secret | Every URL changes | Not applicable |
| Query by token in SQL | No, decode it first | Yes |

If a leaked secret or being unable to revoke a token isn't acceptable for your data, use a random UUID column instead.

## Development

```
bundle install
bundle exec rake
```

## License

MIT. See [LICENSE](LICENSE). Finder behavior derives from [acts_as_hashids](https://github.com/dtaniwaki/acts_as_hashids) by Daisuke Taniwaki.
