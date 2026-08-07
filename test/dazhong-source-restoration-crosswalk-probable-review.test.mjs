import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8'),
);

const review = readJson(
  'data/source-restoration/dazhong-chuancai-1979-crosswalk-probable-review.v1.json',
);
const crosswalk = readJson(
  'data/source-restoration/dazhong-chuancai-1979-crosswalk-dry-run.v1.json',
);
const nameMatches = readJson(
  'data/source-restoration/dazhong-chuancai-1979-name-matches.v1.json',
);

const VALID_DECISIONS = new Set([
  'confirmed-alias',
  'remain-probable',
  'reject-candidate',
]);

const VALID_CONFIDENCE = new Set(['high', 'medium', 'low']);

// The probable review adjudicated the historical probable set (the five
// name-only suspected_match entries), not only the entries that remain
// probable after adjudication.
const EXPECTED_ENTRY_IDS = new Set(
  nameMatches.bookMatches
    .filter((e) => e.classification.id === 'suspected_match')
    .map((e) => e.entryId),
);

test('probable review covers exactly the 5 historical probable entries with no duplicates', () => {
  const ids = review.items.map((item) => item.entryId);
  assert.equal(ids.length, 5);
  assert.equal(new Set(ids).size, 5);
  assert.deepEqual(new Set(ids), EXPECTED_ENTRY_IDS);
});

test('every item carries all required audit fields', () => {
  const required = [
    'entryId',
    'bookName',
    'candidateProjectName',
    'candidateProjectIds',
    'candidateEntityNote',
    'sourceEvidence',
    'candidateEvidence',
    'similarities',
    'differences',
    'decision',
    'confidence',
    'rationale',
    'crosswalkImpact',
  ];
  for (const item of review.items) {
    for (const field of required) {
      assert.ok(
        Object.prototype.hasOwnProperty.call(item, field),
        `${item.entryId} missing ${field}`,
      );
    }
    assert.ok(Array.isArray(item.sourceEvidence) && item.sourceEvidence.length > 0, item.entryId);
    assert.ok(Array.isArray(item.candidateEvidence) && item.candidateEvidence.length > 0, item.entryId);
    assert.ok(Array.isArray(item.similarities), item.entryId);
    assert.ok(Array.isArray(item.differences), item.entryId);
  }
});

test('decisions and confidence values are valid', () => {
  for (const item of review.items) {
    assert.ok(VALID_DECISIONS.has(item.decision), `${item.entryId} invalid decision`);
    assert.ok(VALID_CONFIDENCE.has(item.confidence), `${item.entryId} invalid confidence`);
  }
});

test('confirmed-alias decisions must have confidence=high', () => {
  const confirmed = review.items.filter((item) => item.decision === 'confirmed-alias');
  assert.ok(confirmed.length >= 1);
  for (const item of confirmed) {
    assert.equal(item.confidence, 'high', `${item.entryId} must be high to confirm`);
  }
});

test('remain-probable / reject-candidate never produce confirmed projectIds', () => {
  for (const item of review.items) {
    if (item.decision === 'confirmed-alias') continue;
    assert.ok(
      !Object.prototype.hasOwnProperty.call(item, 'projectIds'),
      `${item.entryId} must not carry confirmed projectIds`,
    );
    assert.ok(
      !Object.prototype.hasOwnProperty.call(item, 'projectName'),
      `${item.entryId} must not carry confirmed projectName`,
    );
  }
});

test('review summary counts match the items', () => {
  const counts = { 'confirmed-alias': 0, 'remain-probable': 0, 'reject-candidate': 0 };
  for (const item of review.items) {
    counts[item.decision] += 1;
  }
  assert.equal(review.summary.reviewed, review.items.length);
  assert.equal(review.summary.confirmedAlias, counts['confirmed-alias']);
  assert.equal(review.summary.remainProbable, counts['remain-probable']);
  assert.equal(review.summary.rejectCandidate, counts['reject-candidate']);
  for (const item of review.items) {
    assert.equal(review.summary.byEntry[item.entryId], item.decision);
  }
});

test('review candidates are consistent with the unchanged crosswalk probable entries', () => {
  const crosswalkById = new Map(
    crosswalk.entries.map((entry) => [entry.entryId, entry]),
  );
  for (const item of review.items) {
    const crosswalkEntry = crosswalkById.get(item.entryId);
    assert.ok(crosswalkEntry, `${item.entryId} missing in crosswalk`);
    if (item.decision === 'confirmed-alias') {
      assert.equal(crosswalkEntry.proposedClassification, 'confirmed-alias', item.entryId);
      assert.equal(crosswalkEntry.projectName, item.candidateProjectName, item.entryId);
      assert.equal(crosswalkEntry.candidateProjectName, null, item.entryId);
      assert.ok(crosswalkEntry.projectIds.length > 0, item.entryId);
    } else if (item.decision === 'reject-candidate') {
      assert.equal(crosswalkEntry.proposedClassification, 'book-only', item.entryId);
      assert.equal(crosswalkEntry.projectName, null, item.entryId);
      assert.equal(crosswalkEntry.candidateProjectName, null, item.entryId);
      assert.deepEqual(crosswalkEntry.projectIds, [], item.entryId);
      assert.deepEqual(crosswalkEntry.candidateProjectIds, [], item.entryId);
    } else {
      assert.equal(crosswalkEntry.proposedClassification, 'probable-match-needs-review', item.entryId);
      assert.equal(crosswalkEntry.candidateProjectName, item.candidateProjectName, item.entryId);
      assert.equal(crosswalkEntry.reviewRequired, true, item.entryId);
    }
  }
});

test('review artifact asserts no promotion and no write-back', () => {
  assert.equal(review.baseline.applicationReady, false);
  assert.equal(review.purpose.includes('不开始 promotion'), true);
});
