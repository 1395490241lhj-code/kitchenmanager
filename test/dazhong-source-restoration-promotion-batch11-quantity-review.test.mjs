import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const readJson = (file) => JSON.parse(fs.readFileSync(new URL(`../${file}`, import.meta.url), 'utf8'));
const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch11-dry-run.v1.json');
const review = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch11-quantity-review.v1.json');

test('quantity review is mechanically copied and its statistics are derived from records', () => {
  assert.deepEqual(review.records, dryRun.quantityReviewPreview.records);
  assert.equal(review.summary.recordCount, review.records.length);
  assert.equal(review.summary.productionRecipeCount, new Set(review.records.map((record) => record.productionId)).size);
  const unitCounts = {};
  for (const record of review.records) unitCounts[record.unit] = (unitCounts[record.unit] ?? 0) + 1;
  assert.deepEqual(review.summary.unitCounts, unitCounts);
  assert.equal(review.records.length, 21);
  assert.deepEqual(unitCounts, { g: 20, '个': 1 });
});

test('all four dual rows register 500g base input and no consumed fields', () => {
  const expected = [
    ['dz1979-p222', '菜油'],
    ['dz1979-p224', '菜油'],
    ['dz1979-p226', '菜油'],
    ['dz1979-p226', '干豆粉'],
  ];
  for (const [id, item] of expected) {
    const record = review.records.find((candidate) => candidate.productionId === id && candidate.item === item);
    assert.ok(record, `${id}:${item}`);
    assert.equal(record.qty, '500');
    assert.equal(record.unit, 'g');
  }
  assert.equal(JSON.stringify(review.records).includes('consumed'), false);
  assert.equal(dryRun.sidecarValidation.joins.length, 4);
});

test('quantity review stays non-production and reports no problems', () => {
  assert.equal(review.applicationReady, false);
  assert.match(review.evidencePolicy, /required input/);
  assert.deepEqual(review.verificationProblems, []);
  assert.deepEqual(dryRun.verificationProblems, []);
});
