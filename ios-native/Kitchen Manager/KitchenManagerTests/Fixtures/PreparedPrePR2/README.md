# Genuine pre-PR2 Prepared store

`prepared-pre-pr2.store` is synthetic XCTest data, generated before the PR2
optional field existed, using the actual app module and unchanged factory/model
sources at `cdcae1424fafba7ffbe82ccdb6c339a6d695f599`.

- The factory contains all 18 model types; every model table is populated,
  including two same-name Prepared rows with distinct UUIDs, counts and states.
- `provenance.json` records the 17 owning source-file hashes, all 18 entity
  version hashes, row counts, old column layout and fixture SHA-256.
- `fixture-writer.swift.txt` preserves the one-use XCTest producer. It explicitly
  verifies 18 entities and absence of `portionGroupingData`. For regeneration,
  use the exact baseline app sources, compile this producer as a test, and select
  a new synthetic output directory; never erase an existing simulator directory.
- The producer process exited before copying its store. SQLite backup consolidated
  the closed old store into this standalone resource without changing its schema
  or rows. Original store/WAL/SHM and writer test results remain in task evidence.
- The resource intentionally has no WAL/SHM sidecars. The main file independently
  passes integrity/data checks; read the frozen original with SQLite immutable
  mode and migrate a copy through the production factory.

Do not replace this fixture with current model classes initialized with nil
metadata: that would no longer prove an existing Prepared row-layout upgrade.
`PreparedPortionGroupingSchemaUpgradeTests` checks all original user columns and
UUIDs, repeat opening and new grouped writes. It retains upgraded database and
user-column attachments in the native result bundle.
