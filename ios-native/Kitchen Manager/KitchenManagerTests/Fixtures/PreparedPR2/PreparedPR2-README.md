# Genuine PR2-layout synthetic store

Produced from the exact merged PR2 baseline `ef23d688c8e72107b60acff0c2e7755289994bd0`, with its unchanged 18-model factory and model sources. The one-use XCTest writer is preserved as inert text. No PR3 record class was used.

All 18 user tables are populated. Prepared includes two same-name count-only records, linked 3+1 chicken portions (8000 decigrams) and rounded 2×333+1×334 allocations. The raw schema has grouping but no lifecycle column.

`prepared-pr2-provenance.json` records exact owning source hashes, entity hashes, original SQLite sidecars, expected complete user values and standalone file hash. The producer process ended before copying original main/WAL/SHM into retained task evidence. SQLite backup consolidated a disposable copy; before/after user values match. The standalone resource has no sidecars. Open this original with SQLite immutable mode; migrate only copies.

For regeneration use the exact baseline, preserved writer and a new owned synthetic output directory. Do not overwrite this fixture, pre-PR2 fixture, historical evidence or an existing simulator directory. Retained producer source archive, baseline input manifest, native receipts and original store sidecars are under the PR3 Slice2 evidence directory. This fixture proves old layout only; later active lifecycle mapping requires fresh acceptance.
