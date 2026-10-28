# Archive format and durable mappings

## Layout

```text
manifest.json
identity.json
account.json
posts/STATUS_ID.json
media/STATUS_ID-MEDIA_ID.EXT
```

`manifest.json` contains `format: "gts-mastodon-migrator/1"`, `complete: true`,
source identity, export time, an ordered list of post files, excluded boost count
and a file map of SHA-256 digests and byte sizes. New exports also include
`exporter_version`. This optional field does not change the format version.

Each post JSON stores the original status API response, the authenticated source
response and media metadata including local path, original URL, size, digest,
description, type and focus. Status and attachment order are retained.

The importer verifies all listed files, ownership, date bounds, media order and
path containment. It rejects path traversal and symlinks resolving outside the
archive. Checksums detect damage; they do not authenticate an untrusted archive.
Use archives from sources you trust.

## Resume behavior

An export locks its directory and checks its saved source identity before reuse.
It removes any previous completion manifest before refreshing the data. Media
can be reused if their URL and digest still match. A completed rerun references
only the latest exported records; unreferenced older files may remain on disk.
Use a fresh directory when a physically clean archive is required.

The export is not an atomic snapshot of a concurrently edited account. It
follows descending IDs until an empty page, rejecting repeated/out-of-order IDs.
Each media download is staged and replaces its destination after completion.

## Database mapping

The table `gts_migrator_imports` has these columns:

| Column | Meaning |
| --- | --- |
| `target_account_id` | Local destination account ID |
| `source_key` | Source account URL plus original status ID; a suffix identifies continuations |
| `status_id` | New local Mastodon status ID |
| `payload_sha256` | Hash of the intended import content and selected split parts |
| timestamps | Mapping creation/update time |

`target_account_id + source_key` is unique. The first thread part retains the
original mapping key; subsequent parts use `/gts-migrator-part/N` suffixes.
Source identity, not an archive directory or token, determines deduplication.

Reruns check every mapped part for account ownership, local status, deletion,
payload hash and continuation linkage. They will not silently reconstruct a
deleted or manually changed mapping. Keep the same splitting flags on reruns.

The format string, table name and part-key namespace intentionally remain unchanged
from the 0.1.x development builds. Renaming the project must not invalidate
existing archives or duplicate already imported posts.
