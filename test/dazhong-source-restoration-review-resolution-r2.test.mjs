import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8'),
);

const queue = readJson(
  'data/source-restoration/dazhong-chuancai-1979-review-queue.v1.json',
);

const classification = readJson(
  'data/source-restoration/dazhong-chuancai-1979-review-resolution-r1-classification.v1.json',
);

const r1Results = readJson(
  'data/source-restoration/dazhong-chuancai-1979-review-resolution-r1-results.v1.json',
);

const r2Results = readJson(
  'data/source-restoration/dazhong-chuancai-1979-review-resolution-r2-results.v1.json',
);

const catalog = readJson(
  'data/source-restoration/dazhong-chuancai-1979-catalog.v1.json',
);
const catalogBookNameByEntryId = new Map(
  catalog.entries.map((entry) => [entry.entryId, entry.bookName]),
);

const queueEntryIds = new Set(queue.items.map((item) => item.entryId));

const VALID_STATUSES = new Set([
  'resolved',
  'confirmed-unresolved',
  'needs-alternate-source',
]);

test('R2 results itemsReviewedCount matches the actual items array length', () => {
  assert.equal(r2Results.itemsReviewedCount, r2Results.items.length);
});

test('R2 resultCounts is mechanically derived from items[].status', () => {
  const actualCounts = { resolved: 0, 'confirmed-unresolved': 0, 'needs-alternate-source': 0 };
  for (const item of r2Results.items) {
    assert.ok(
      Object.prototype.hasOwnProperty.call(actualCounts, item.status),
      `unexpected status on ${item.entryId}: ${item.status}`,
    );
    actualCounts[item.status] += 1;
  }
  assert.deepEqual(r2Results.resultCounts, actualCounts);
});

test('every R2 item status is one of the three allowed values', () => {
  for (const item of r2Results.items) {
    assert.ok(
      VALID_STATUSES.has(item.status),
      `${item.entryId} has invalid status: ${item.status}`,
    );
  }
});

test('resolved + confirmed-unresolved + needs-alternate-source sums to itemsReviewedCount', () => {
  const { resolved, 'confirmed-unresolved': confirmedUnresolved, 'needs-alternate-source': needsAlternateSource } = r2Results.resultCounts;
  assert.equal(
    resolved + confirmedUnresolved + needsAlternateSource,
    r2Results.itemsReviewedCount,
  );
});

test('every R2 item entryId belongs to the A_local-scan-recheck classification set', () => {
  const aSet = new Set(classification.classification['A_local-scan-recheck']);
  for (const item of r2Results.items) {
    assert.ok(
      aSet.has(item.entryId),
      `${item.entryId} is not in A_local-scan-recheck`,
    );
  }
});

test('every R2 item entryId exists in the review queue', () => {
  for (const item of r2Results.items) {
    assert.ok(
      queueEntryIds.has(item.entryId),
      `${item.entryId} is not present in the review queue`,
    );
  }
});

test('no duplicate entryId within R2 results items', () => {
  const seen = new Set();
  for (const item of r2Results.items) {
    assert.ok(!seen.has(item.entryId), `duplicate entryId: ${item.entryId}`);
    seen.add(item.entryId);
  }
});

test('R2 items do not duplicate entryIds already resolved/confirmed in R1', () => {
  const r1Ids = new Set(r1Results.items.map((item) => item.entryId));
  for (const item of r2Results.items) {
    assert.ok(
      !r1Ids.has(item.entryId),
      `${item.entryId} was already reviewed in R1 and should not reappear in R2`,
    );
  }
});

test('R2 semantic-only exclusions (p184/p194/p197) are not present in R2 visually-reviewed items', () => {
  const semanticOnlyIds = new Set(
    r2Results.semanticOnlyExclusions.map((entry) => entry.entryId),
  );
  assert.deepEqual(
    semanticOnlyIds,
    new Set(['dz1979-p184', 'dz1979-p194', 'dz1979-p197']),
  );
  const reviewedIds = new Set(r2Results.items.map((item) => item.entryId));
  for (const id of semanticOnlyIds) {
    assert.ok(!reviewedIds.has(id), `${id} should be semantic-only, not visually reviewed`);
  }
});

test('semantic-only exclusions keep modernSummary null and are not resolved/confirmed', () => {
  for (const entry of r2Results.semanticOnlyExclusions) {
    assert.equal(entry.modernSummary, null);
    assert.equal(entry.disposition, 'semantic-only / no-further-visual');
  }
});

test('R2 remainingAEntries covers exactly the 7 A-category entries not reviewed in R1', () => {
  const aSet = new Set(classification.classification['A_local-scan-recheck']);
  const r1Ids = new Set(r1Results.items.map((item) => item.entryId));
  const expectedRemaining = [...aSet].filter((id) => !r1Ids.has(id));
  assert.deepEqual(
    new Set(r2Results.remainingAEntries),
    new Set(expectedRemaining),
  );
  assert.equal(r2Results.remainingACount, expectedRemaining.length);
});

test('R2 visually reviewed items + semantic-only exclusions cover all remaining A entries', () => {
  const reviewedIds = new Set(r2Results.items.map((item) => item.entryId));
  const semanticOnlyIds = new Set(
    r2Results.semanticOnlyExclusions.map((entry) => entry.entryId),
  );
  const covered = new Set([...reviewedIds, ...semanticOnlyIds]);
  assert.deepEqual(covered, new Set(r2Results.remainingAEntries));
});

test('R2 does not modify R1 files (identity check against known R1 counts)', () => {
  assert.equal(r1Results.itemsReviewedCount, 5);
  assert.deepEqual(r1Results.resultCounts, {
    resolved: 4,
    'confirmed-unresolved': 1,
    'needs-alternate-source': 0,
  });
});

test('dz1979-p131 remains confirmed-unresolved in R1 and is absent from R2', () => {
  const p131 = r1Results.items.find((item) => item.entryId === 'dz1979-p131');
  assert.ok(p131, 'dz1979-p131 should exist in R1 results');
  assert.equal(p131.status, 'confirmed-unresolved');
  const r2Ids = new Set(r2Results.items.map((item) => item.entryId));
  assert.ok(!r2Ids.has('dz1979-p131'), 'dz1979-p131 should not reappear in R2');
});

test('every R1/R2 item bookName matches the catalog bookName for its entryId', () => {
  for (const item of r1Results.items) {
    const expected = catalogBookNameByEntryId.get(item.entryId);
    assert.ok(expected, `${item.entryId} must exist in the catalog`);
    assert.equal(
      item.bookName,
      expected,
      `R1 ${item.entryId} bookName "${item.bookName}" must match catalog bookName "${expected}"`,
    );
  }
  for (const item of r2Results.items) {
    const expected = catalogBookNameByEntryId.get(item.entryId);
    assert.ok(expected, `${item.entryId} must exist in the catalog`);
    assert.equal(
      item.bookName,
      expected,
      `R2 ${item.entryId} bookName "${item.bookName}" must match catalog bookName "${expected}"`,
    );
  }
  for (const entry of r2Results.semanticOnlyExclusions) {
    const expected = catalogBookNameByEntryId.get(entry.entryId);
    assert.ok(expected, `${entry.entryId} must exist in the catalog`);
    assert.equal(
      entry.bookName,
      expected,
      `R2 semanticOnlyExclusions ${entry.entryId} bookName "${entry.bookName}" must match catalog bookName "${expected}"`,
    );
  }
});
