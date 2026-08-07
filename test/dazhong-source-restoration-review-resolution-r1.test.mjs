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

const results = readJson(
  'data/source-restoration/dazhong-chuancai-1979-review-resolution-r1-results.v1.json',
);

const queueEntryIds = new Set(queue.items.map((item) => item.entryId));

const VALID_STATUSES = new Set([
  'resolved',
  'confirmed-unresolved',
  'needs-alternate-source',
]);

test('R1 results itemsReviewedCount matches the actual items array length', () => {
  assert.equal(results.itemsReviewedCount, results.items.length);
});

test('R1 resultCounts is mechanically derived from items[].status', () => {
  const actualCounts = { resolved: 0, 'confirmed-unresolved': 0, 'needs-alternate-source': 0 };
  for (const item of results.items) {
    assert.ok(
      Object.prototype.hasOwnProperty.call(actualCounts, item.status),
      `unexpected status on ${item.entryId}: ${item.status}`,
    );
    actualCounts[item.status] += 1;
  }
  assert.deepEqual(results.resultCounts, actualCounts);
});

test('every R1 item status is one of the three allowed values', () => {
  for (const item of results.items) {
    assert.ok(
      VALID_STATUSES.has(item.status),
      `${item.entryId} has invalid status: ${item.status}`,
    );
  }
});

test('resolved + confirmed-unresolved + needs-alternate-source sums to itemsReviewedCount', () => {
  const { resolved, 'confirmed-unresolved': confirmedUnresolved, 'needs-alternate-source': needsAlternateSource } = results.resultCounts;
  assert.equal(
    resolved + confirmedUnresolved + needsAlternateSource,
    results.itemsReviewedCount,
  );
});

test('every R1 item entryId belongs to the A_local-scan-recheck classification set', () => {
  const aSet = new Set(classification.classification['A_local-scan-recheck']);
  for (const item of results.items) {
    assert.ok(
      aSet.has(item.entryId),
      `${item.entryId} is not in A_local-scan-recheck`,
    );
  }
});

test('every R1 item entryId exists in the review queue', () => {
  for (const item of results.items) {
    assert.ok(
      queueEntryIds.has(item.entryId),
      `${item.entryId} is not present in the review queue`,
    );
  }
});

test('no duplicate entryId within R1 results items', () => {
  const seen = new Set();
  for (const item of results.items) {
    assert.ok(!seen.has(item.entryId), `duplicate entryId: ${item.entryId}`);
    seen.add(item.entryId);
  }
});
