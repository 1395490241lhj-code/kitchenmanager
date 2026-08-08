import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

import { normalizeIngredientAmount } from '../src/ingredients.js';

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8'),
);

const readiness = readJson(
  'data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json',
);
const crosswalk = readJson(
  'data/source-restoration/dazhong-chuancai-1979-crosswalk-dry-run.v1.json',
);
const catalog = readJson(
  'data/source-restoration/dazhong-chuancai-1979-catalog.v1.json',
);
const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');

const curatedIds = new Set(curated.recipes.map((r) => r.id));
const fullIds = new Set(full.recipes.map((r) => r.id));

const VALID_DISPOSITIONS = new Set([
  'existing-project-match',
  'new-recipe-candidate',
  'blocked-source-review',
  'blocked-alternate-source',
  'blocked-crosswalk',
]);

const crosswalkById = new Map(crosswalk.entries.map((e) => [e.entryId, e]));
const catalogById = new Map(catalog.entries.map((e) => [e.entryId, e]));

const newCandidates = () => readiness.entries.filter(
  (entry) => entry.promotionDisposition === 'new-recipe-candidate',
);

test('manifest covers exactly 147 entries with no duplicates', () => {
  const ids = readiness.entries.map((entry) => entry.entryId);
  assert.equal(ids.length, 147);
  assert.equal(new Set(ids).size, 147);
  assert.deepEqual(new Set(ids), new Set(catalog.entries.map((e) => e.entryId)));
});

test('dispositions are valid and sum to 147', () => {
  const counts = {};
  for (const entry of readiness.entries) {
    assert.ok(VALID_DISPOSITIONS.has(entry.promotionDisposition), entry.entryId);
    counts[entry.promotionDisposition] = (counts[entry.promotionDisposition] ?? 0) + 1;
  }
  assert.equal(Object.values(counts).reduce((sum, n) => sum + n, 0), 147);
  assert.deepEqual(readiness.summary.dispositionCounts, counts);
});

test('disposition follows the priority rule against crosswalk facts', () => {
  for (const entry of readiness.entries) {
    const walk = crosswalkById.get(entry.entryId);
    const { classification, sourceQuality } = entry;
    assert.equal(classification, walk.proposedClassification, entry.entryId);
    assert.equal(sourceQuality, walk.sourceQuality, entry.entryId);

    let expected;
    if (sourceQuality === 'alternate-source-required') {
      expected = 'blocked-alternate-source';
    } else if (sourceQuality === 'needs-source-review') {
      expected = 'blocked-source-review';
    } else if (classification === 'probable-match-needs-review') {
      expected = 'blocked-crosswalk';
    } else if (classification === 'exact-name' || classification === 'confirmed-alias') {
      expected = 'existing-project-match';
    } else {
      expected = 'new-recipe-candidate';
    }
    assert.equal(entry.promotionDisposition, expected, entry.entryId);
  }
});

test('all 81 confirmed mappings avoid new-recipe-candidate', () => {
  const confirmed = readiness.entries.filter((entry) => (
    entry.classification === 'exact-name' || entry.classification === 'confirmed-alias'
  ));
  assert.equal(confirmed.length, 81);
  assert.equal(
    confirmed.filter((entry) => entry.promotionDisposition === 'new-recipe-candidate').length,
    0,
  );
  assert.equal(readiness.summary.confirmedProjectMappingTotal, 81);
});

test('new-recipe-candidate equals book-only and ready intersection', () => {
  const expected = readiness.entries.filter((entry) => (
    entry.classification === 'book-only'
    && entry.sourceQuality === 'ready-for-later-promotion-review'
  ));
  assert.equal(readiness.summary.newRecipeCandidateCount, expected.length);
  assert.deepEqual(readiness.summary.newRecipeCandidateIds, expected.map((e) => e.entryId).sort());
  for (const entry of expected) {
    assert.equal(entry.promotionDisposition, 'new-recipe-candidate', entry.entryId);
  }
});

test('p173 is blocked-crosswalk with reviewRequired preserved', () => {
  const p173 = readiness.entries.find((entry) => entry.entryId === 'dz1979-p173');
  assert.equal(p173.promotionDisposition, 'blocked-crosswalk');
  assert.equal(p173.classification, 'probable-match-needs-review');
  assert.equal(p173.sourceQuality, 'ready-for-later-promotion-review');
  assert.deepEqual(p173.projectIds, []);
});

test('all 12 alternate-source entries are blocked-alternate-source', () => {
  const alt = readiness.entries.filter((entry) => entry.sourceQuality === 'alternate-source-required');
  assert.equal(alt.length, 12);
  for (const entry of alt) {
    assert.equal(entry.promotionDisposition, 'blocked-alternate-source', entry.entryId);
  }
});

test('needs-source-review never enters new-recipe-candidate', () => {
  for (const entry of readiness.entries) {
    if (entry.sourceQuality === 'needs-source-review') {
      assert.notEqual(entry.promotionDisposition, 'new-recipe-candidate', entry.entryId);
    }
  }
});

test('existing-project-match IDs are real and blockers are explicit', () => {
  for (const entry of readiness.entries) {
    if (entry.promotionDisposition === 'existing-project-match') {
      assert.ok(entry.projectIds.length > 0, entry.entryId);
      for (const { library, id } of entry.projectIds) {
        const idSet = library === 'curated' ? curatedIds : fullIds;
        assert.ok(idSet.has(id), `${entry.entryId} dangling ${library}/${id}`);
      }
    }
    assert.ok(Array.isArray(entry.blockingReasons), entry.entryId);
    assert.ok(entry.proposedProductionAction, entry.entryId);
  }
});

test('every new-recipe-candidate carries the full conversion preview', () => {
  const required = [
    'proposedName',
    'proposedTags',
    'proposedIdStrategy',
    'ingredientTarget',
    'methodTarget',
    'provenanceStrategy',
    'schemaGapNotes',
    'methodPreview',
    'productionIngredientPlan',
  ];
  const candidates = readiness.entries.filter((e) => e.promotionDisposition === 'new-recipe-candidate');
  assert.ok(candidates.length > 0);
  for (const entry of candidates) {
    for (const field of required) {
      assert.ok(
        Object.prototype.hasOwnProperty.call(entry, field),
        `${entry.entryId} missing ${field}`,
      );
    }
    assert.equal(entry.proposedName, catalogById.get(entry.entryId).bookName, entry.entryId);
    assert.ok(entry.proposedIdStrategy.length > 0, entry.entryId);
    assert.ok(entry.methodPreview.length > 0, entry.entryId);
    assert.ok(entry.productionIngredientPlan.inventoryIngredients.length > 0, entry.entryId);
    assert.ok(['exact-comparable', 'mixed', 'display-only']
      .includes(entry.productionIngredientPlan.quantityReadiness), entry.entryId);
  }
});

test('exact-mass ingredients convert to numeric string qty with unit g', () => {
  for (const entry of newCandidates()) {
    for (const ingredient of entry.productionIngredientPlan.inventoryIngredients) {
      if (!ingredient.inventoryComparable) continue;
      const conversion = ingredient.conversionReason;
      if (conversion.startsWith('exact-mass')) {
        assert.equal(ingredient.unit, 'g', entry.entryId);
        assert.ok(/^\d+(\.\d+)?$/.test(ingredient.qty), `${entry.entryId} qty not numeric string`);
        assert.equal(ingredient.displayQuantity, null, entry.entryId);
      }
    }
  }
});

test('exact-count ingredients convert to numeric string qty with the real count unit', () => {
  let seen = 0;
  for (const entry of newCandidates()) {
    for (const ingredient of entry.productionIngredientPlan.inventoryIngredients) {
      if (!ingredient.conversionReason.startsWith('exact-count')) continue;
      seen += 1;
      assert.equal(ingredient.inventoryComparable, true, entry.entryId);
      assert.ok(/^\d+(\.\d+)?$/.test(ingredient.qty), entry.entryId);
      assert.ok(ingredient.unit && ingredient.unit !== 'g', `${entry.entryId} unit=${ingredient.unit}`);
      assert.equal(ingredient.displayQuantity, null, entry.entryId);
    }
  }
  assert.ok(seen > 0, 'expected at least one exact-count conversion');
});

test('non-exact quantities are never fabricated as exact', () => {
  for (const entry of newCandidates()) {
    for (const ingredient of entry.productionIngredientPlan.inventoryIngredients) {
      if (ingredient.inventoryComparable) continue;
      assert.equal(ingredient.qty, null, entry.entryId);
      assert.equal(ingredient.unit, null, entry.entryId);
      assert.ok(ingredient.displayQuantity, entry.entryId);
      assert.ok(/exact-mass|exact-count/.test(ingredient.conversionReason) === false, entry.entryId);
    }
  }
});

test('unallocated group totals are never split into per-member quantities', () => {
  // No unallocated-group-total ingredient exists in the 39 candidates, but
  // if one ever appears the plan must not assign qty to it.
  for (const entry of newCandidates()) {
    for (const ingredient of entry.productionIngredientPlan.inventoryIngredients) {
      if (!ingredient.conversionReason.includes('unallocated-group-total')) continue;
      assert.equal(ingredient.qty, null, entry.entryId);
      assert.equal(ingredient.unit, null, entry.entryId);
      assert.equal(ingredient.inventoryComparable, false, entry.entryId);
    }
  }
});

test('every inventoryComparable plan item normalizes to finite qty and non-empty unit', () => {
  for (const entry of newCandidates()) {
    for (const ingredient of entry.productionIngredientPlan.inventoryIngredients) {
      if (!ingredient.inventoryComparable) continue;
      const normalized = normalizeIngredientAmount(ingredient.qty, ingredient.unit);
      assert.ok(Number.isFinite(Number(normalized.qty)), `${entry.entryId} ${ingredient.productionItem}`);
      assert.ok(normalized.unit, `${entry.entryId} ${ingredient.productionItem} empty unit`);
    }
  }
});

test('proposed tags are strictly ["川菜", category] for every new candidate', () => {
  const candidates = newCandidates();
  assert.ok(candidates.length > 0);
  for (const entry of candidates) {
    assert.deepEqual(
      entry.proposedTags,
      ['川菜', entry.category],
      entry.entryId,
    );
  }
});

test('no automatic 素菜 or main-ingredient tags are inferred', () => {
  for (const entry of newCandidates()) {
    assert.ok(!entry.proposedTags.includes('素菜'), entry.entryId);
    const semanticTags = ['猪肉', '牛肉', '鸡肉', '鸭肉', '鱼', '兔肉', '豆腐', '鸡蛋', '虾'];
    for (const tag of semanticTags) {
      assert.ok(!entry.proposedTags.includes(tag), `${entry.entryId} inferred ${tag}`);
    }
  }
});

test('39 new-recipe-candidates are unchanged', () => {
  assert.equal(readiness.summary.newRecipeCandidateCount, 39);
  assert.equal(
    readiness.entries.filter((e) => e.promotionDisposition === 'new-recipe-candidate').length,
    39,
  );
});

test('disposition statistics stay 50/39/45/12/1', () => {
  assert.deepEqual(readiness.summary.dispositionCounts, {
    'existing-project-match': 50,
    'new-recipe-candidate': 39,
    'blocked-source-review': 45,
    'blocked-alternate-source': 12,
    'blocked-crosswalk': 1,
  });
});

test('source, crosswalk, canonical, and production data are unchanged by this plan', () => {
  assert.deepEqual(crosswalk.summary.classificationCounts, {
    'exact-name': 74,
    'confirmed-alias': 7,
    'probable-match-needs-review': 1,
    'book-only': 65,
  });
  const restored = readJson(
    'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
  );
  assert.equal(restored.applicationReady, false);
  assert.deepEqual(
    restored.recipes.find((r) => r.entryId === 'dz1979-p173').projectMatch,
    {
      classification: 'probable-match-needs-review',
      projectName: null,
      projectIds: [],
      candidateProjectName: '干煸鳝鱼',
      reviewRequired: true,
    },
  );
  const productionIds = [
    ...curated.recipes.map((r) => r.id),
    ...full.recipes.map((r) => r.id),
  ];
  // The promoted Batch 1 ids are the only dz1979- ids present in production,
  // and they correspond exactly to the promoted readiness entries.
  const promoted = new Set(readiness.summary.promotedNewRecipeIds);
  const promotedInProduction = productionIds.filter((id) => id.startsWith('dz1979-'));
  assert.deepEqual(promotedInProduction.sort(), [...promoted].sort());
  assert.equal(promoted.size, 27);
});

test('proposed stable IDs are unique and do not collide with production prefixes', () => {
  const ids = readiness.entries
    .filter((e) => e.promotionDisposition === 'new-recipe-candidate')
    .map((e) => e.proposedIdStrategy);
  assert.equal(new Set(ids).size, ids.length);
  for (const id of ids) {
    assert.ok(!/^(ex--|fam-|comp-|static-|hoc-)/.test(id), id);
  }
});

test('manifest asserts no promotion and no production writes', () => {
  assert.equal(readiness.applicationReady, false);
  assert.equal(readiness.productionPromotion, false);
  assert.equal(readiness.summary.verificationProblems.length, 0);
  assert.equal(readiness.summary.schemaExtensionNeeded, false);
  assert.ok(readiness.productionChainAudit.recipeEntitySchema);
  assert.ok(readiness.productionChainAudit.ingredientStorage);
  assert.ok(readiness.productionChainAudit.iosConsumer);
  assert.ok(readiness.productionChainAudit.minimalPromotionBatchSuggestion);
});

test('promotionState marks exactly the promoted batch and keeps dispositions stable', () => {
  const promotedIds = new Set(readiness.summary.promotedNewRecipeIds);
  assert.equal(readiness.summary.promotedNewRecipeCount, 27);
  assert.equal(readiness.summary.remainingNewRecipeCandidateCount, 12);
  assert.deepEqual(promotedIds, new Set([
    'dz1979-p143',
    'dz1979-p180',
    'dz1979-p187',
    'dz1979-p188',
    'dz1979-p195',
    'dz1979-p196',
    'dz1979-p200',
    'dz1979-p202',
    'dz1979-p204',
    'dz1979-p205',
    'dz1979-p206',
    'dz1979-p212',
    'dz1979-p216',
    'dz1979-p218',
    'dz1979-p221',
    'dz1979-p183',
    'dz1979-p198',
    'dz1979-p153',
    'dz1979-p209',
    'dz1979-p223',
    'dz1979-p162',
    'dz1979-p186',
    'dz1979-p185',
    'dz1979-p219',
    'dz1979-p213',
    'dz1979-p159',
    'dz1979-p168',
  ]));
  const promotedEntries = readiness.entries.filter((entry) => promotedIds.has(entry.entryId));
  for (const entry of promotedEntries) {
    assert.equal(entry.promotionState, 'promoted', entry.entryId);
    // Disposition stays the pre-promotion source/matching classification.
    assert.equal(entry.promotionDisposition, 'new-recipe-candidate', entry.entryId);
    assert.equal(entry.sourceQuality, 'ready-for-later-promotion-review', entry.entryId);
  }
  const nonPromoted = readiness.entries.filter((entry) => !promotedIds.has(entry.entryId));
  for (const entry of nonPromoted) {
    assert.equal(entry.promotionState, 'not-promoted', entry.entryId);
  }
  assert.deepEqual(readiness.summary.dispositionCounts, {
    'existing-project-match': 50,
    'new-recipe-candidate': 39,
    'blocked-source-review': 45,
    'blocked-alternate-source': 12,
    'blocked-crosswalk': 1,
  });
  assert.equal(readiness.futureBatchSelectionRule.excludePromotionState, 'promoted');
});
