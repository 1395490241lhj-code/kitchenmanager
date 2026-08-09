import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { normalizeIngredientAmount, RECIPE_UNIT_WHITELIST } from '../src/ingredients.js';

const readJson = (file) => JSON.parse(fs.readFileSync(new URL('../' + file, import.meta.url), 'utf8'));
const quantityReview = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch10-quantity-review.v1.json');
const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch10-dry-run.v1.json');

test('Batch 10 quantity review contains only 22 real structured exact quantities', () => {
  assert.equal(quantityReview.records.length, 22);
  assert.equal(quantityReview.summary.recordCount, 22);
  assert.deepEqual(quantityReview.summary.unitCounts, { g: 19, '根': 3 });
  assert.equal(new Set(quantityReview.records.map((record) => record.productionId + ':' + record.item)).size, 22);
  for (const record of quantityReview.records) {
    assert.notEqual(record.qty, null);
    assert.notEqual(record.unit, null);
    assert.ok(['exact-mass', 'exact-count'].includes(record.normalizedQuantity.kind));
    assert.equal(record.qty, String(record.normalizedQuantity.qty));
    assert.ok(RECIPE_UNIT_WHITELIST.includes(record.unit));
    assert.ok(Number.isFinite(Number(normalizeIngredientAmount(record.qty, record.unit).qty)));
    assert.equal(record.reviewStatus, 'approved');
    assert.equal(record.evidenceType, 'source-restoration');
  }
});

test('review records are field-for-field copied from dry-run and exclude all non-exact null 花椒', () => {
  assert.deepEqual(quantityReview.records, dryRun.quantityReviewPreview.records);
  assert.equal(quantityReview.records.some((record) => record.item === '花椒'), false);
  assert.deepEqual([...new Set(quantityReview.records.map((record) => record.productionId))].sort(), [
    'dz1979-p201', 'dz1979-p203', 'dz1979-p207',
  ]);
  for (const item of dryRun.items) {
    const pepper = item.proposedOverlayIngredients[item.productionId].find((ingredient) => ingredient.item === '花椒');
    assert.deepEqual(pepper, { item: '花椒', qty: null, unit: null });
  }
});

test('quantity review and dry-run report zero problems without promotion', () => {
  assert.deepEqual(quantityReview.verificationProblems, []);
  assert.deepEqual(dryRun.verificationProblems, []);
  assert.equal(quantityReview.applicationReady, false);
  assert.deepEqual(dryRun.selection.selectedEntryIds, ['dz1979-p203', 'dz1979-p201', 'dz1979-p207']);
});
