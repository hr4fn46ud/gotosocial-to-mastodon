# gotosocial-to-mastodon

[![CI](https://github.com/hr4fn46ud/gotosocial-to-mastodon/actions/workflows/ci.yml/badge.svg)](https://github.com/hr4fn46ud/gotosocial-to-mastodon/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/hr4fn46ud/gotosocial-to-mastodon)](https://github.com/hr4fn46ud/gotosocial-to-mastodon/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Export your own GoToSocial posts and original media, then import them into an
existing Mastodon account with their original publication dates. Long posts can
be preserved as linked threads instead of being truncated.

**This is an administrator-operated archive importer.** It runs inside Mastodon
through Rails; a regular Mastodon access token is insufficient. It creates new
local posts and URLs, rather than moving existing ActivityPub objects.

## Compatibility and validation

| Component | Supported / verified |
| --- | --- |
| Export host | Linux or macOS, Python 3.9+, standard library only |
| Source | GoToSocial's authenticated Mastodon-compatible account/status/source API |
| Standalone archive check | Ruby 2.6+; no Mastodon installation needed |
| Destination | **Mastodon 4.7.3 only**, with administrator access |
| Installation | Native installation or Docker Compose |

The development build was used in a real migration: 373 archived records,
230 archived replies excluded, three direct messages excluded, and 140 original
posts imported as 147 Mastodon statuses. Seven long posts became two-part threads.
A subsequent run recognized all 140 sources as already imported. An operator
also checked a rendered post with its historical date, media, links and hashtags.
These are operator-reported results, not an automated end-to-end test suite. The
source server's GoToSocial version was not recorded.

Other Mastodon versions are rejected, because this importer depends on internal
models and callbacks. Do not remove the version guard without reviewing those
internals and testing on a disposable instance.

## What it preserves

- Original publication timestamp and historical, correctly ordered status IDs.
- Post text, links, content warnings, sensitive flags and language.
- Original media downloads, attachment order, alt text and image focus.
- Public and unlisted visibility; GoToSocial `unlocked` becomes `unlisted`.
- Self-reply relationships when included and both posts are supported.
- Complete long-post text as optional linked threads.
- Durable duplicate protection across reruns and new archive directories.

The import does not enqueue normal ActivityPub delivery, timeline delivery,
subscription emails or link crawling. Status webhooks and FASP content/trend
announcements are suppressed for the new objects. Normal local counters and
search indexing remain active. Imported public posts are accessible on the target
profile and can subsequently be fetched, shared or boosted normally.

## Quick start: native Mastodon installation

### 1. Download

Download a versioned archive from [Releases](https://github.com/hr4fn46ud/gotosocial-to-mastodon/releases),
or clone the repository. Release assets include SHA-256 checksums.

```sh
git clone https://github.com/hr4fn46ud/gotosocial-to-mastodon.git
cd gotosocial-to-mastodon
python3 export.py --version
ruby import.rb --version
```

### 2. Get a source token

Create a managed application in your GoToSocial settings and authorize a user
token with `read:accounts read:statuses` or the broader `read` scope. See
[Authentication](docs/AUTHENTICATION.md) for the settings-panel workflow.

No Mastodon API token is required for import. Source and destination accounts,
domains and paths are always supplied by you; none are embedded in the tool.

### 3. Export and verify

Set the source server, local username and desired archive directory:

```sh
printf 'GoToSocial HTTPS base URL: '
read -r GTS_SERVER
printf 'Local GoToSocial username: '
read -r GTS_USER
printf 'Archive directory: '
read -r ARCHIVE

python3 export.py \
  --source "$GTS_SERVER" \
  --account "$GTS_USER" \
  --output "$ARCHIVE"

ruby import.rb --archive "$ARCHIVE" --check-archive
```

The exporter prompts for the token without echoing it. You may alternatively use
`--token-file /path/to/token` or `GTS_TOKEN`. Do not put tokens in command arguments,
screenshots, bug reports or Git. `--account` is an optional safeguard: its value
must match the local username of the authenticated account.

To resume an interrupted export, run the same command with the same directory.
Post metadata is refreshed; previously downloaded media with matching hashes and
URLs is reused. A complete manifest is written only after successful pagination
and all media downloads. Empty accounts produce valid empty archives.

Stop posting or editing during the final export: the API does not provide an
atomic snapshot of a changing account. Protect the archive; it may contain
private posts and direct messages even if you later exclude them from import.

### 4. Transfer to the Mastodon server

Copy **`import.rb` and the entire archive directory** to the target server. The
archive directory is the folder containing `manifest.json`, not a ZIP file.
Both must be readable by the operating-system user running Mastodon. Neither
`export.py` nor the source token is needed on the destination.

Create the destination Mastodon account first. As the Mastodon operating-system
user, enter the installation directory and set these values:

```sh
# Run from the Mastodon installation directory, as its service user.
printf 'Absolute path to import.rb: '
read -r IMPORT_SCRIPT
printf 'Absolute archive path on this server: '
read -r ARCHIVE
printf 'Existing local Mastodon username: '
read -r TARGET_USER
```

`TARGET_USER` is the bare local username, without `@` or a domain. Use the Ruby
environment already configured for your Mastodon installation.

### 5. Preview

For original posts only, with long posts preserved as threads:

```sh
RAILS_ENV=production bundle exec rails runner "$IMPORT_SCRIPT" \
  --archive "$ARCHIVE" \
  --target-user "$TARGET_USER" \
  --exclude-replies \
  --split-long-posts
```

**Without `--apply`, no posts or mapping table are written.** The JSON report
shows what would be imported or excluded. Unsupported posts cause an error after
the report, so they cannot be silently omitted. Read their reasons before adding
`--skip-unsupported`. A preview does not run the destination's media encoders.

### 6. Import

Back up the destination database and media storage, and test on a disposable copy
before a production import. After reviewing the preview, repeat it with `--apply`:

```sh
RAILS_ENV=production bundle exec rails runner "$IMPORT_SCRIPT" \
  --archive "$ARCHIVE" \
  --target-user "$TARGET_USER" \
  --exclude-replies \
  --split-long-posts \
  --apply
```

If you intentionally accept every exclusion shown in the preview, add
`--skip-unsupported` to that command. It applies to **all** unsupported reasons,
including validation errors, not just direct messages.

After import, repeat the preview with the same selection and splitting flags.
Successful sources should be reported as `already_imported`, with
`statuses_to_create: 0`. Check dates, media, alt text and thread links in the UI.

For containers, see [Docker Compose](docs/DOCKER.md).

## Import options

| Option | Meaning |
| --- | --- |
| `--archive DIR` | Complete local export directory; required |
| `--target-user NAME` | Existing local destination username; required except for integrity checks |
| `--check-archive` | Verify archive files, hashes and ownership without Rails |
| `--apply` | Actually import after preflight; omitted by default |
| `--exclude-replies` | Ignore all archived replies, including self-replies |
| `--split-long-posts` | Preserve posts exceeding the text limit as linked threads |
| `--skip-unsupported` | Explicitly omit every post with unsupported reasons |
| `--include-followers-only` | Include followers-only posts for the target account's followers |
| `--report FILE` | Save the preflight JSON report; no post bodies or tokens |
| `--version` | Print the tool version and exit |

### Long posts

Splitting uses Mastodon's own character-counting rules, including URL weighting,
mentions, Unicode graphemes and the content-warning budget. Word boundaries are
preferred; exceptionally long words are split between graphemes. URLs and mentions
are kept intact. A warning or indivisible entity that cannot fit is reported.

Each continuation replies to the previous part. All parts retain the original
timestamp, language, visibility, content warning and sensitive flag; increasing
historical IDs preserve their order. Attachments appear on the first part only.
No numbering is inserted. Mastodon's normal trimming of outer whitespace still
applies at part boundaries.

`--exclude-replies` excludes **old archived replies**. It does not prevent new
continuations created by `--split-long-posts`.

## Report fields

| Field | Meaning |
| --- | --- |
| `importable` | New, supported **source posts**, not generated status count |
| `already_imported` | Sources whose saved mapping and destination statuses validate |
| `unsupported` | Sources that would be omitted with `--skip-unsupported` |
| `ignored_replies` | Archived replies excluded by policy |
| `split_threads` | Supported sources represented by multiple parts |
| `statuses_to_create` | Actual new Mastodon statuses, including continuations |
| `posts[].parts` | Planned number of parts for a source |
| `posts[].reasons` | Why a source is unsupported or ignored |

`importable + already_imported + unsupported + ignored_replies` equals the number
of source records in the manifest. The saved report is a **preflight report**;
it is not a transaction log. Apply progress is printed separately.

## Limits you should know

- **New identities and URLs:** likes, boosts and other people's replies do not
  transfer. Follower moves, follows, profiles, lists, bookmarks and pins are
  separate concerns. This tool does not change them or delete anything at source.
- **Different servers/domains:** replacing GoToSocial with Mastodon under the
  same domain requires a separate identity migration. This tool does not migrate
  actor keys or preserve old object URLs. Detectable same-domain cases are rejected;
  split account/web domains still require the operator to verify the distinction.
- **Replies:** replies to other accounts and replies whose parent is missing
  are unsupported. Supported self-replies can be retained or excluded explicitly.
- **Visibility:** direct messages are never imported. Followers-only posts need
  an explicit option and become visible to the **target account's** followers,
  which may differ from the original audience.
- **Unsupported content:** polls and quote posts are not imported. Boosts are
  excluded at export. Custom emoji images are not installed automatically.
- **Formatting:** plain-text sources are used directly; other sources are
  converted from rendered HTML into text with links. Rich formatting and edit
  history are not preserved. Mentions remain text and do not create notifications.
  Links to old posts are not rewritten. The last edit timestamp is retained.
- **Destination limits:** attachment counts, sizes, formats, descriptions and
  dimensions remain subject to Mastodon's validation and media processing. The
  archive contains original bytes; Mastodon may transcode or strip metadata.
- **Reruns:** completed sources are skipped. Changed source content, deleted
  destination parts and incomplete mappings are reported, not overwritten.

See [Troubleshooting](docs/TROUBLESHOOTING.md) for reason codes and common errors.

## Storage and recovery

The importer adds **one database table, `gts_migrator_imports`**, on the first
write. It stores the source key, destination account/status IDs and semantic
payload hash. Each thread part gets a mapping. Keep this table in database
backups; deleting it removes duplicate protection.

One source post, all its generated parts, attachments and mapping rows share a
database transaction. A failed continuation rolls back that source's entire thread;
previously completed sources remain. An advisory lock prevents concurrent imports
to the same destination account.

Database rollback cannot undo object-store writes. Cleanup after a caught error
is best effort; a hard process termination may leave unused media files. A full
undo requires restoring your backup; there is no automatic rollback command.

The archive format and mapping namespace retain their development-era names for
backward compatibility. Archives and import mappings from versions 0.1.x remain
usable. See [Archive format](docs/ARCHIVE-FORMAT.md).

## Development

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md).

```sh
make test
make release-check
```

The suite uses synthetic archives and local storage doubles. It does not start
Mastodon, PostgreSQL or a production media pipeline. CI exercises Linux and macOS
with multiple Python/Ruby versions. Successful CI does not add destination-version
support beyond the explicit guard.

## License

[MIT](LICENSE). Mastodon and GoToSocial are separate upstream projects with their
own licenses. This project neither bundles nor modifies their source code.
