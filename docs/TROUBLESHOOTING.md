# Troubleshooting

## Unsupported posts are not an importer crash

Without `--skip-unsupported`, the importer prints the complete preflight report
and exits with an error if any source is unsupported. Inspect `posts[].reasons`.
The default is deliberately all-or-review, not silent omission.

| Reason | Meaning / action |
| --- | --- |
| `visibility` | Unsupported visibility, including direct messages; never made public automatically |
| `followers_only_requires_option` | Add `--include-followers-only` only if the new audience is acceptable |
| `external_or_missing_reply_parent` | Foreign-account reply or absent parent; `--exclude-replies` omits all archived replies |
| `unsupported_reply_parent` | A self-reply depends on a rejected source |
| Text character limit exceeded | Use `--split-long-posts` if you want complete linked threads |
| `cannot_split: ...` | Content warning or an indivisible entity cannot fit within the limit |
| `media_limit`, `mixed_media`, `media_type` | Destination attachment restrictions |
| `media_file_too_large`, `media_description_too_long` | Destination size/description limit |
| `poll`, `quote`, `boost` | Unsupported object type |
| `previous_import_changed` | The intended payload differs from a previous import; keep the same flags or review source edits |
| `previous_import_incomplete` | A thread part's durable mapping is missing |
| `previous_import_missing_or_deleted` | A mapped status is missing, deleted or belongs elsewhere |
| `previous_import_thread_changed` | A continuation no longer replies to the mapped previous part |
| `reply_excluded` | Policy exclusion, reported as ignored rather than unsupported |

Other validation messages come from the installed Mastodon models and may follow
its configured language. The importer does not disable those validations.

## Wrong Mastodon version

The supported destination is exactly 4.7.3. Fork/version suffixes and other patch
versions are rejected too. Request support with the exact version; maintainers
need to review models, callbacks, serializers, IDs and media behavior first.

## Token or export problems

- HTTP 401/403: verify the token's source instance, user ownership and read scopes.
- HTTP 429/5xx: bounded retries are automatic; rerun later with the same directory
  if the server asks for more than five minutes or retries are exhausted.
- Source identity mismatch: use a separate output directory for each source.
- Incomplete manifest/checksum error: finish or resume the export, then verify it.
  Do not edit hashes just to get past the check.
- `Permission denied`: the Mastodon service user needs read/traverse access to the
  entire archive. Docker copies may need an ownership adjustment.

## An apply run stopped

Keep the archive and full error. Successfully completed sources remain imported;
the failing source's database changes are rolled back. After fixing the cause,
repeat the same command with the same target and selection/splitting flags.

The mapping table is part of the database backup. Do not delete it to force a
rerun: that can duplicate content. A hard kill may leave unreferenced object-store
files, which need normal storage maintenance.

For a bug report, include the tool version (`--version`), Mastodon version,
deployment type, sanitized summary/reason codes and the first error. Remove
tokens, private post bodies, account metadata and private media URLs. See
[CONTRIBUTING.md](../CONTRIBUTING.md).
