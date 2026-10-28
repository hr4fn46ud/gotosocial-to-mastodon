# Changelog

All notable changes are recorded here. Versions follow Semantic Versioning.

## [0.2.0] - 2026-10-28

First public release as **gotosocial-to-mastodon**.

### Added

- English command help, errors, progress, documentation and test fixtures.
- Standalone `--version` in both scripts and consistent release metadata.
- Native-installation quick start, source authentication guide, Docker notes,
  archive specification and troubleshooting reference.
- MIT license, contributor/security guidance, GitHub issue/PR templates and CI.
- Reproducible source packaging with ZIP, tar.gz and SHA-256 checksums.
- Explicit completion summary after apply.

### Preserved

- Historical timestamps and ordered status IDs, media/alt text/focus, content
  warnings, visibility and language.
- Optional exclusion of archived replies and complete long-post threads.
- Read-only preview, checksum verification, source-scoped export resume,
  transactional per-source import and durable per-part duplicate protection.
- Existing 0.1.x archive format, mapping table and continuation keys.
- Exact Mastodon 4.7.3 destination guard and quiet archive-import behavior.

### Validation

- Development build used in an operator-reported real migration: 140 original
  sources imported as 147 statuses, including seven two-part threads. A rerun
  recognized all 140 sources; a rendered historical media post was inspected.
- Local/CI unit tests remain distinct from a full automated Mastodon integration
  test. Other destination versions and Docker import are not claimed as tested.

## [0.1.3] - 2026-10-28

Pre-public development build: complete long-post threads, per-part mappings,
historical ID ordering and source-level transaction tests.

## [0.1.2] - 2026-10-28

Pre-public development build: `--exclude-replies` and separate ignored counts.

## [0.1.1] - 2026-10-28

Pre-public development build: fix empty media placeholders incorrectly rejecting
media posts during preflight; retain normal validation on import.

## [0.1.0] - 2026-10-28

Initial private development package with configurable export, verified archive
and Mastodon Rails importer.

[0.2.0]: https://github.com/hr4fn46ud/gotosocial-to-mastodon/releases/tag/v0.2.0
