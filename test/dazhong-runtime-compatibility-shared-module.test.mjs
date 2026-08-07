import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

import { classifyIngredientCompatibility, userRealisticProbes, POULTRY_PROBES } from '../scripts/dazhong-runtime-compatibility.mjs';

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8'),
);

// This module was extracted verbatim from the frozen Batch 1 runtime audit
// (scripts/build-dazhong-chuancai-batch1-runtime-audit.mjs). It must
// reproduce the frozen Batch 1 audit results exactly, field-for-field, so
// Batch 2+ can reuse the same verified classification without re-deriving
// or drifting from Batch 1 semantics.

const frozenAudit = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch1-runtime-audit.v1.json');

test('shared module reproduces every frozen Batch 1 core compatibility result exactly', () => {
  assert.equal(frozenAudit.coreCompatibility.length, 7);
  for (const entry of frozenAudit.coreCompatibility) {
    const result = classifyIngredientCompatibility(entry.item, entry.qty, entry.unit);
    assert.equal(result.compatibility, entry.compatibility, `${entry.productionId}:${entry.item}`);
    assert.equal(result.canonical, entry.canonical, `${entry.productionId}:${entry.item}`);
    assert.equal(result.role, entry.role, `${entry.productionId}:${entry.item}`);
    assert.equal(result.familyKey ?? null, entry.ingredientFamilyKey ?? null, `${entry.productionId}:${entry.item}`);
    assert.equal(result.guessKitchenUnit, entry.guessKitchenUnit, `${entry.productionId}:${entry.item}`);
    assert.deepEqual(result.normalizedQuantity, entry.normalizedQuantity, `${entry.productionId}:${entry.item}`);
    assert.deepEqual(result.reasons, entry.reasons, `${entry.productionId}:${entry.item}`);
    assert.deepEqual(result.probes, entry.probes, `${entry.productionId}:${entry.item}`);
  }
});

test('shared module reproduces every frozen Batch 1 non-core observation exactly', () => {
  assert.equal(frozenAudit.nonCoreObservations.length, 12);
  for (const entry of frozenAudit.nonCoreObservations) {
    const result = classifyIngredientCompatibility(entry.item, entry.qty, entry.unit);
    assert.equal(result.role, entry.role, `${entry.productionId}:${entry.item}`);
    assert.equal(result.compatibility, null, `${entry.productionId}:${entry.item}`);
    assert.equal(result.observation, entry.observation, `${entry.productionId}:${entry.item}`);
    assert.notEqual(entry.role, 'core', `${entry.productionId}:${entry.item}`);
  }
});

test('shared module aggregate counts still match the frozen Batch 1 summary (5 exact / 2 unit-confirmation / 0 unresolved)', () => {
  const counts = { 'exact-compatible': 0, 'expected-unit-confirmation': 0, 'unresolved-name-match': 0 };
  for (const entry of frozenAudit.coreCompatibility) {
    const result = classifyIngredientCompatibility(entry.item, entry.qty, entry.unit);
    counts[result.compatibility] += 1;
  }
  assert.equal(counts['exact-compatible'], 5);
  assert.equal(counts['expected-unit-confirmation'], 2);
  assert.equal(counts['unresolved-name-match'], 0);
  assert.deepEqual(counts, frozenAudit.summary.coreCompatibilityCounts);
});

test('non-core role is never assigned a compatibility value', () => {
  const result = classifyIngredientCompatibility('盐', '5', 'g');
  assert.equal(result.role, 'seasoning');
  assert.equal(result.compatibility, null);
  assert.match(result.observation, /不参与库存名称兼容三分类/);
});

test('userRealisticProbes always includes the identity probe and poultry probes for chicken-like items', () => {
  const probes = userRealisticProbes('仔母鸡');
  assert.ok(probes.includes('仔母鸡'), 'missing identity probe');
  for (const poultryProbe of POULTRY_PROBES) {
    assert.ok(probes.includes(poultryProbe), `missing poultry probe ${poultryProbe}`);
  }
});

test('finite normalized quantity is always returned for exact-mass/exact-count inputs', () => {
  const result = classifyIngredientCompatibility('莲花白', '750', 'g');
  assert.equal(result.normalizedQuantity.finite, true);
  assert.equal(Number.isFinite(Number(result.normalizedQuantity.qty)), true);
});

test('re-derived coreCompatibility/nonCoreObservations arrays are byte-identical to the frozen Batch 1 artifact', () => {
  const curated = readJson('data/sichuan-recipes.curated.json');
  const ledger = readJson('data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json');
  const quantityReview = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch1-quantity-review.v1.json');
  const promotedIds = new Set(
    (ledger.batches ?? []).flatMap((batch) => (batch.entries ?? []).map((entry) => entry.productionId)),
  );
  const quantityReviewByKey = new Map(
    (quantityReview.records ?? []).map((record) => [`${record.productionId}:${record.item}`, record]),
  );

  const coreCompatibility = [];
  const nonCoreObservations = [];
  for (const id of [...promotedIds].sort()) {
    const recipe = curated.recipes.find((entry) => entry.id === id);
    const ingredients = curated.recipe_ingredients[id] || [];
    for (const ingredient of ingredients) {
      const { item, qty, unit } = ingredient;
      const result = classifyIngredientCompatibility(item, qty, unit);
      const quantityRecord = quantityReviewByKey.get(`${id}:${item}`);
      const baseRecord = {
        productionId: id,
        recipeName: recipe.name,
        item,
        qty,
        unit,
        canonical: result.canonical,
        role: result.role,
        ingredientFamilyKey: result.familyKey,
        guessKitchenUnit: result.guessKitchenUnit,
        sourceRawQuantityText: quantityRecord?.sourceRawQuantityText ?? null,
        normalizedQuantitySource: quantityRecord?.normalizedQuantity ?? null,
        quantityProvenanceNote: quantityRecord
          ? `qty/unit 来自 source-restoration canonical 数量（raw「${quantityRecord.sourceRawQuantityText}」→ ${quantityRecord.normalizedQuantity.kind} ${quantityRecord.normalizedQuantity.qty}${quantityRecord.normalizedQuantity.unit ?? ''}），未经人工改值。`
          : null,
        normalizedQuantity: result.normalizedQuantity,
      };
      if (result.role !== 'core') {
        nonCoreObservations.push({ ...baseRecord, observation: result.observation });
        continue;
      }
      coreCompatibility.push({
        ...baseRecord,
        identityMatch: result.identityMatch,
        probes: result.probes,
        compatibility: result.compatibility,
        reasons: result.reasons,
      });
    }
  }

  assert.deepEqual(coreCompatibility, frozenAudit.coreCompatibility);
  assert.deepEqual(nonCoreObservations, frozenAudit.nonCoreObservations);
});
