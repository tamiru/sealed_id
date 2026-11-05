# Changelog

## 0.1.0

- Encrypt integer primary keys into unique, UUID-shaped tokens with AES-256, with no new column or migration.
- Refuse raw ids in `find` from requests, while integers, ActiveJob and GlobalID keep working.
- Make `where`, `find_by`, `exists?`, `delete`, `delete_by` and `destroy_by` understand tokens.
- Add `SealedId.model_for`, `locate` and `find` to resolve any token to its model and record.
- Add `decode_params` for foreign keys in forms, and a `legacy` option for ids issued by an earlier scheme.
- Read the secret from `SEALED_ID_SECRET`, and refuse short or repetitive secrets.
- Finder behavior derives from [acts_as_hashids](https://github.com/dtaniwaki/acts_as_hashids).
