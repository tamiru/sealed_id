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

Add the gem to your Gemfile:

```ruby
gem "sealed_id", "~> 0.1"
```

### Set a secret

Tokens are derived from a secret of at least 32 bytes. **Changing the secret changes every public URL**, so choose one you won't need to rotate.

The simplest way is an environment variable, which the gem reads automatically. Generate a value with `bin/rails secret`, then set it wherever the app runs:

```
SEALED_ID_SECRET=<your generated value>
```

Environments with the same value produce the same tokens, so a link or database copy from one works in another. Machines that share the production value can also decode and forge production tokens, so give production its own value unless you need this.

The order of precedence is `secret:` on the model, then `SealedId.secret = ...` in an initializer, then `SEALED_ID_SECRET`. In Rails, `secret_key_base` is the fallback, which differs per environment and would change your links if rotated, so set a dedicated value in production. Outside Rails, there's no fallback.

## Usage

Put the macro on one model, or on `ApplicationRecord` for all of them.

```ruby
foo.sealed_id                # the token
Foo.unseal(token)            # the integer id, or nil if the token is invalid
Foo.with_sealed_ids(a, b)    # a relation; raises SealedId::InvalidToken for an invalid token
```

`find` also accepts several tokens and respects scopes, so `current_user.foos.find(token)` only finds that user's records.

### Finding the model from a token

Every token records which model it belongs to, readable only with your secret:

```ruby
SealedId.model_for(token) # => Foo, or nil if the token isn't valid
SealedId.locate(token)    # => the record, or nil
SealedId.find(token)      # => the record, or raises ActiveRecord::RecordNotFound
```

`locate` and `find` search every model, so **always check that the caller may see the record they return**. For a request that should only reach one model, use `Foo.find(token)`, which refuses another model's token. With single-table inheritance, `model_for` returns the base class, and `locate` returns the actual subclass.

### Options

```ruby
sealed_id secret: ENV.fetch("FOO_SECRET"), # overrides SealedId.secret; may be callable
          scope: "foos"                    # defaults to the base class name
```

Tokens are tied to the `scope`, so a token for one model is never valid for another. Before renaming a model, set `scope` to its current class name, or its URLs will change. Each model needs its own scope: `SealedId.model_for` and the other lookups above raise `SealedId::Error` if two share one.

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

`fields_for` works unchanged. It adds a hidden field holding the nested record's raw id, and `decode_params` keeps that one raw value, because nested attributes only ever match records already inside the parent's association. Other ids in nested attributes must still be tokens.

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

- **Some queries still don't understand tokens.** `find`, `where`, `find_by`, `exists?`, `delete`, `delete_by` and `destroy_by` all handle tokens for the primary key and `belongs_to` foreign keys. `where.not`, conditions on joined tables (`where(foos: { id: token })`) and raw SQL don't: they cast the string to an integer and act on **a different record**, so `"7a3d54ce-..."` becomes 7. The same applies to `legacy` ids in any query other than `find`. Decode first with `Foo.unseal`, which returns `nil` for an invalid token.
- **This isn't access control.** Anyone holding a valid URL can use it, so always authorize access to the record you load.
- **Decoding isn't authorization.** `decode_params` confirms a token is valid, not that this user may link to that record. Check that separately.
- **`find` accepts integers.** A JSON body of `{"id": 3}` makes `params[:id]` an `Integer`, which `find` accepts because application code relies on it. Use `Foo.find(params[:id].to_s)` for ids from JSON. `decode_params` already refuses them.
- **Raw ids appear elsewhere.** `as_json` and `to_json` include `id`, while `dom_id`, `cache_key`, nested-form hidden fields and global ids all use the raw value. Remove them from anything public if the id itself is sensitive.

## How it works

Each token is one AES-256 block holding the 64-bit id, a 32-bit tag naming the model and 32 zero bits, using a key derived from your secret with HMAC-SHA256, then written in UUID format. The mapping is deterministic, so a record always has the same token, with no storage needed.

**Tokens are unique by construction.** All models using the same secret share one key, AES is one-to-one for a given key, and no two records have the same id and tag, so two records can't get the same token. This is a mathematical guarantee rather than a low probability, so there's no need for a unique index or for retrying on a collision. The exception is a model with its own `secret:`, where a clash with another model is only astronomically unlikely, as with random UUIDs.

With a strong secret, tokens don't show ids, models, their order or how many records exist, knowing other id and token pairs doesn't help an attacker, and a guess is less likely to succeed than guessing a random UUIDv4. A changed token decrypts to random bits, which fail the tag and zero checks.

There are three things to know:

- **Tokens are shaped like UUIDs, but aren't valid under RFC 9562.** Their version and variant bits are random, because the full 128 bits hold the encrypted block. Databases and most parsers accept them, but a validator that checks for a specific UUID version will reject them.
- **Your secret decides everything.** The gem refuses short or obviously repetitive secrets, but it can't measure randomness, so generate yours with `bin/rails secret`.
- **This hasn't had an independent review.** AES is standard, but this gem's use of it hasn't been audited.

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

### Publishing

A matching `v*.*.*` tag publishes the gem using trusted publishing (OIDC), so the repository needs no registry secrets. Register a trusted publisher on [RubyGems](https://rubygems.org/gems/sealed_id) with these values:

| Field | Value |
| --- | --- |
| Repository | `tamiru/sealed_id` |
| Workflow | `release.yml` |
| Environment | `release` |

```bash
# Bump the version in lib/sealed_id/version.rb and update CHANGELOG.md, then
git tag v0.1.0
git push origin v0.1.0
```

If a publish fails, re-run the failed jobs. A version already on RubyGems is skipped, so a partial release can be finished safely.

## License

MIT. See [LICENSE](LICENSE).
