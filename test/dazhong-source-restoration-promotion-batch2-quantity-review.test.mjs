import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

import { normalizeIngredientAmount, RECIPE_UNIT_WHITELIST } from '../src/ingredients.js';

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8'),
);

const quantityReview = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch2-quantity-review.v1.json');
const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch2-dry-run.v1.json');

test('Batch 2 quantity review has exactly 29 unique source-restoration records', () => {
  assert.equal(quantityReview.records.length, 29);
  const keys = new Set(quantityReview.records.map((r) => `${r.productionId}:${r.item}`));
  assert.equal(keys.size, 29);
  assert.equal(quantityReview.summary.recordCount, 29);
  assert.equal(quantityReview.summary.keys.length, 29);
});

test('every record is field-for-field identical to the frozen dry-run quantityReviewPreview', () => {
  const dryRunByKey = new Map(
    dryRun.quantityReviewPreview.records.map((r) => [`${r.productionId}:${r.item}`, r]),
  );
  assert.equal(dryRun.quantityReviewPreview.recordCount, 29);
  for (const record of quantityReview.records) {
    const key = `${record.productionId}:${record.item}`;
    const source = dryRunByKey.get(key);
    assert.ok(source, `${key} missing from frozen dry-run quantityReviewPreview`);
    assert.equal(record.entryId, source.entryId, key);
    assert.equal(record.recipeName, source.recipeName, key);
    assert.equal(record.qty, source.qty, key);
    assert.equal(record.unit, source.unit, key);
    assert.equal(record.evidenceType, source.evidenceType, key);
    assert.equal(record.canonicalSourceFile, source.canonicalSourceFile, key);
    assert.equal(record.sourceRawQuantityText, source.sourceRawQuantityText, key);
    assert.deepEqual(record.normalizedQuantity, source.normalizedQuantity, key);
    assert.equal(record.reviewStatus, source.reviewStatus, key);
  }
});

test('every record satisfies the quality gate: approved, source-restoration, exact-only, whitelisted unit, finite normalization', () => {
  for (const record of quantityReview.records) {
    const key = `${record.productionId}:${record.item}`;
    assert.equal(record.reviewStatus, 'approved', key);
    assert.equal(record.evidenceType, 'source-restoration', key);
    assert.ok(['exact-mass', 'exact-count'].includes(record.normalizedQuantity.kind), key);
    assert.equal(record.qty, String(record.normalizedQuantity.qty), key);
    if (record.normalizedQuantity.kind === 'exact-mass') {
      assert.equal(record.unit, 'g', key);
    }
    assert.ok(RECIPE_UNIT_WHITELIST.includes(record.unit), `${key} unit ${record.unit}`);
    const normalized = normalizeIngredientAmount(record.qty, record.unit);
    assert.ok(Number.isFinite(Number(normalized.qty)), `${key} non-finite qty`);
    assert.ok(normalized.unit, `${key} empty unit`);
  }
});

test('unit distribution is all grams (29 g, 0 other units)', () => {
  assert.deepEqual(quantityReview.summary.unitCounts, { g: 29 });
});

test('records cover exactly the five Batch 2 promoted production ids', () => {
  const productionIds = new Set(quantityReview.records.map((r) => r.productionId));
  assert.deepEqual([...productionIds].sort(), ['dz1979-p187', 'dz1979-p188', 'dz1979-p196', 'dz1979-p202', 'dz1979-p205']);
});

test('artifact reports zero verification problems and applicationReady=false', () => {
  assert.deepEqual(quantityReview.verificationProblems, []);
  assert.equal(quantityReview.applicationReady, false);
});

test('the frozen Batch 2 dry-run itself is untouched by this promotion', () => {
  assert.deepEqual(dryRun.selection.selectedEntryIds, ['dz1979-p187', 'dz1979-p202', 'dz1979-p205', 'dz1979-p188', 'dz1979-p196']);
  assert.deepEqual(dryRun.verificationProblems, []);
});
