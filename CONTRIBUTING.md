# Contributing

Issues and pull requests are welcome. Keep changes focused and include a concrete
before/after example, relevant tests and any archive/mapping compatibility impact.
Use English for code comments, CLI messages, documentation and discussions.

## Run the checks

Python 3.9+ and Ruby 2.6+ are sufficient for the local unit suite; no API tokens,
third-party Python packages, Rails installation or network access are required.

```sh
make test
make release-check
```

CI runs the suite on Linux and macOS. Storage doubles verify transaction intent;
they do not prove real Rails callbacks, PostgreSQL rollback or media transcoding.
Changes to the importer also need a disposable-instance test for the supported
Mastodon version.

## Compatibility rules

- Keep the archive format and durable import keys backward compatible, or provide
  an explicit migration and fixtures proving it works.
- Never bypass Mastodon validation to make an unsupported post pass.
- Never widen a post's visibility or silently truncate text.
- Keep read-only preflight free of database writes and media processing.
- Preserve transaction boundaries, duplicate protection and outbound-delivery
  suppression. Do not invoke the normal publishing service for archived posts.
- New Mastodon support needs an upstream review and a real test of historical
  IDs, media, self-replies, split threads, reruns and suppressed delivery.

## Reporting bugs

Include versions, the smallest reproduction, sanitized report fields and the
first error. Use synthetic records where possible. Do not attach your real archive
or credentials to a public issue. For sensitive reports, follow [SECURITY.md](SECURITY.md).

## Versioning and release

The project uses Semantic Versioning. `0.x` releases remain under active
development; read the changelog before upgrading. Update `VERSION`, both embedded
script versions and `CHANGELOG.md` together; `scripts/check.py` verifies agreement.
Scripts embed their version so `import.rb` remains independently deployable.

Release procedure:

1. Run `make test` and `make release-check`.
2. Commit all changes and confirm CI passes for that exact commit.
3. Build assets with `make dist` from the clean committed tree.
4. Tag that commit as `v<VERSION>` and publish a GitHub release with ZIP, tar.gz
   and `SHA256SUMS`. Do not move published tags or replace released contents.
5. Verify the public release, checksums and downloadable assets.

`scripts/build_release.py` packages only Git-tracked files and fixes archive
metadata to the commit timestamp. Private exports, reports and local tokens are
not release inputs. Reproducing a release requires the same commit and compatible
compression tooling.

Contributions are distributed under the project's [MIT license](LICENSE).
