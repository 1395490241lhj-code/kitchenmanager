import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8'),
);

const catalog = readJson(
  'data/source-restoration/dazhong-chuancai-1979-catalog.v1.json',
);
const plan = readJson(
  'data/source-restoration/dazhong-chuancai-1979-batch-plan.v1.json',
);
const matches = readJson(
  'data/source-restoration/dazhong-chuancai-1979-name-matches.v1.json',
);
const restored = readJson(
  'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
);
const probableReview = readJson(
  'data/source-restoration/dazhong-chuancai-1979-crosswalk-probable-review.v1.json',
);

const catalogById = new Map(catalog.entries.map((entry) => [entry.entryId, entry]));
const matchById = new Map(matches.bookMatches.map((entry) => [entry.entryId, entry]));
const planById = new Map(plan.batches.map((batch) => [batch.batchId, batch]));

// Entries whose canonical projectMatch legitimately diverges from the
// name-matches name-only baseline because body evidence adjudicated them.
const adjudicatedByEntryId = new Map(
  probableReview.items
    .filter((item) => (
      (item.decision === 'confirmed-alias' || item.decision === 'reject-candidate')
      && item.confidence === 'high'
    ))
    .map((item) => [item.entryId, item]),
);

const expectedProjectClassification = (matchId) => ({
  exact_name: 'exact-name',
  clear_alias: 'confirmed-alias',
  suspected_match: 'probable-match-needs-review',
  book_only: 'book-only',
})[matchId];

test('restored recipes remain non-production and cover a contiguous batch prefix', () => {
  assert.equal(restored.applicationReady, false);
  assert.equal(restored.scope.intermediateOnly, true);
  assert.equal(restored.scope.householdServingScale, false);
  assert.equal(restored.scope.productionRecipeGenerated, false);
  assert.equal(restored.scope.productionSchemaExpanded, false);
  assert.equal(restored.scope.productionPatchGenerated, false);
  assert.equal(restored.scope.cacheStampUpdated, false);
  assert.equal(restored.scope.uiChanged, false);
  assert.equal(restored.source.pdfSha256,
    'd7d5d62ea1585bbc1cba3f78eeda4e1ffddbae702180af5ea7fef25cd65f3c41');
  assert.equal(restored.source.ocrUsedAsAuthority, false);

  const expectedCompleted = plan.batches
    .slice(0, restored.completedBatchIds.length)
    .map((batch) => batch.batchId);
  assert.deepEqual(restored.completedBatchIds, expectedCompleted);
  const expectedEntryIds = plan.batches
    .slice(0, restored.completedBatchIds.length)
    .flatMap((batch) => batch.entryIds);
  assert.deepEqual(restored.recipes.map((recipe) => recipe.entryId), expectedEntryIds);
  assert.equal(new Set(expectedEntryIds).size, expectedEntryIds.length);

  assert.equal(restored.summary.catalogEntryCount, 147);
  assert.equal(restored.summary.processedRecipeCount, restored.recipes.length);
  assert.equal(restored.summary.remainingRecipeCount, 147 - restored.recipes.length);
  assert.equal(restored.summary.completedBatchCount, restored.completedBatchIds.length);
  assert.equal(restored.summary.ingredientEntryCount,
    restored.recipes.flatMap((recipe) => recipe.ingredients).length);

  if (restored.status === 'complete-reviewed-intermediate-only') {
    assert.equal(restored.recipes.length, 147);
    assert.equal(restored.completedBatchIds.length, 11);
    assert.equal(restored.summary.remainingRecipeCount, 0);
  }
});

test('every processed recipe keeps visual source, method, material, and mapping boundaries', () => {
  const allowedClassifications = new Set([
    'exact-name',
    'confirmed-alias',
    'probable-match-needs-review',
    'book-only',
  ]);
  for (const recipe of restored.recipes) {
    const catalogEntry = catalogById.get(recipe.entryId);
    assert.ok(catalogEntry, `unknown catalog entry ${recipe.entryId}`);
    assert.equal(recipe.bookName, catalogEntry.bookName);
    assert.equal(recipe.category, catalogEntry.category);
    assert.equal(recipe.source.pdfStartPage, catalogEntry.pdfPage);
    assert.equal(recipe.source.bookStartPage, catalogEntry.bookPage);
    assert.equal(recipe.source.pdfEndPage - recipe.source.bookEndPage, 13);
    assert.equal(recipe.titleVisualCheck.matchesCatalog, true);
    assert.ok(['high', 'medium', 'low'].includes(recipe.titleVisualCheck.confidence));
    assert.ok(recipe.titleVisualCheck.observedText);

    const isVerifiedContentMissing = recipe.contentMissing === true
      && recipe.uncertainties.some((u) => u.type === 'page-boundary');
    const isVerifiedContentIncomplete = recipe.contentIncomplete === true
      && recipe.contentMissing !== true
      && recipe.uncertainties.some((u) => u.type === 'page-boundary'
        && u.reasonCode === 'source-content-missing');
    if (isVerifiedContentMissing) {
      assert.equal(recipe.ingredients.length, 0);
      assert.equal(recipe.methodSummary.steps.length, 0);
    } else if (isVerifiedContentIncomplete) {
      // A genuinely truncated printed page: whatever is visible must still
      // be well-formed, but the normal non-empty/2-6-step thresholds do not
      // apply because part of the page itself is missing.
      assert.ok(recipe.methodSummary.steps.length >= 1);
      assert.ok(recipe.methodSummary.steps.length <= 6);
    } else {
      assert.ok(recipe.ingredients.length > 0);
      assert.ok(recipe.methodSummary.steps.length >= 2);
      assert.ok(recipe.methodSummary.steps.length <= 6);
    }
    assert.deepEqual(
      recipe.methodSummary.steps.map((step) => step.order),
      recipe.methodSummary.steps.map((_, index) => index + 1),
    );
    assert.ok(recipe.methodSummary.steps.every((step) => step.summary));
    if (!isVerifiedContentMissing && !(isVerifiedContentIncomplete && recipe.characteristicsSummary === null)) {
      assert.ok(recipe.characteristicsSummary);
    }
    assert.ok(Array.isArray(recipe.methodOnlyIngredients));
    assert.ok(Array.isArray(recipe.confirmedReadings));
    assert.ok(Array.isArray(recipe.uncertainties));
    for (const key of [
      'tools',
      'containers',
      'fuels',
      'cleaningMaterials',
      'nonEdiblePackaging',
    ]) {
      assert.ok(Array.isArray(recipe.nonIngredientMaterials[key]));
    }

    const sourceMatch = matchById.get(recipe.entryId);
    assert.ok(allowedClassifications.has(recipe.projectMatch.classification));
    const adjudication = adjudicatedByEntryId.get(recipe.entryId);
    if (adjudication?.decision === 'confirmed-alias') {
      assert.equal(recipe.projectMatch.classification, 'confirmed-alias');
      assert.equal(recipe.projectMatch.projectName, adjudication.candidateProjectName);
      assert.deepEqual(recipe.projectMatch.projectIds, adjudication.candidateProjectIds);
      assert.equal(recipe.projectMatch.candidateProjectName, null);
      assert.equal(recipe.projectMatch.reviewRequired, false);
    } else if (adjudication?.decision === 'reject-candidate') {
      assert.equal(recipe.projectMatch.classification, 'book-only');
      assert.equal(recipe.projectMatch.projectName, null);
      assert.deepEqual(recipe.projectMatch.projectIds, []);
      assert.equal(recipe.projectMatch.candidateProjectName, null);
      assert.equal(recipe.projectMatch.reviewRequired, false);
    } else {
      assert.equal(
        recipe.projectMatch.classification,
        expectedProjectClassification(sourceMatch.classification.id),
      );
      if (recipe.projectMatch.classification === 'probable-match-needs-review') {
        assert.equal(recipe.projectMatch.projectName, null);
        assert.deepEqual(recipe.projectMatch.projectIds, []);
        assert.equal(recipe.projectMatch.candidateProjectName, sourceMatch.projectName);
        assert.equal(recipe.projectMatch.reviewRequired, true);
      } else if (recipe.projectMatch.classification === 'book-only') {
        assert.equal(recipe.projectMatch.projectName, null);
        assert.deepEqual(recipe.projectMatch.projectIds, []);
        assert.equal(recipe.projectMatch.candidateProjectName, null);
        if (isVerifiedContentIncomplete) {
          assert.equal(recipe.projectMatch.reviewRequired, true);
        }
      } else {
        assert.equal(recipe.projectMatch.projectName, sourceMatch.projectName);
        assert.ok(recipe.projectMatch.projectIds.length > 0);
        if (isVerifiedContentIncomplete) {
          assert.equal(recipe.projectMatch.reviewRequired, true);
        } else {
          assert.equal(recipe.projectMatch.reviewRequired, false);
        }
      }
    }
  }
});

test('quantity normalization preserves uncertainty and grouped allocations', () => {
  const ingredients = restored.recipes.flatMap((recipe) => recipe.ingredients);
  const allowedKinds = new Set([
    'exact-mass',
    'exact-count',
    'range-mass',
    'range-count',
    'approximate-mass',
    'approximate-count',
    'qualitative-amount',
    'unresolved',
  ]);

  for (const ingredient of ingredients) {
    assert.ok(ingredient.rawItemText);
    assert.ok(ingredient.rawQuantityText);
    assert.ok(ingredient.conversionBasis);
    assert.ok(allowedKinds.has(ingredient.normalizedQuantity.kind));
    assert.ok(['high', 'medium', 'low'].includes(ingredient.confidence.recognition));
    assert.ok(['high', 'medium', 'low', 'unresolved']
      .includes(ingredient.confidence.conversion));

    const quantity = ingredient.normalizedQuantity;
    if (quantity.kind === 'exact-mass') {
      assert.equal(quantity.unit, 'g');
      assert.ok(Number.isFinite(quantity.qty));
      if (quantity.consumedQty !== undefined || quantity.consumedUnit !== undefined) {
        assert.equal(quantity.consumedUnit, 'g');
        if (quantity.consumedQty !== undefined) {
          assert.ok(Number.isFinite(quantity.consumedQty));
        } else {
          assert.ok(Number.isFinite(quantity.consumedReferenceQty));
          assert.equal(typeof quantity.consumedQualifier, 'string');
          assert.notEqual(quantity.consumedQualifier.trim(), '');
        }
      }
    }
    if (quantity.kind.startsWith('approximate-')
      || quantity.kind === 'qualitative-amount') {
      assert.equal(quantity.qty, null);
    }
    if (quantity.kind === 'unresolved') {
      assert.equal(quantity.qty, null);
      assert.equal(quantity.unit, null);
      assert.notEqual(ingredient.conversionCandidate?.accepted, true);
    }
    if (ingredient.memberQuantityMode === 'same-for-each') {
      assert.equal(ingredient.groupTotal, undefined);
      assert.ok(ingredient.members.length >= 2);
      for (const member of ingredient.members) {
        assert.equal(member.qty, quantity.qty);
        assert.equal(member.unit, quantity.unit);
      }
    }
    if (ingredient.memberQuantityMode === 'unallocated-group-total') {
      assert.ok(ingredient.groupTotal);
      assert.ok(ingredient.members.length >= 2);
      for (const member of ingredient.members) {
        assert.equal(member.qty, null);
        assert.equal(member.unit, null);
      }
    }
  }
});

test('approved pilot readings remain intact whenever their recipes are processed', () => {
  const byName = new Map(restored.recipes.map((recipe) => [recipe.bookName, recipe]));
  const saltFriedPork = byName.get('炒盐煎肉');
  if (saltFriedPork) {
    const grouped = saltFriedPork.ingredients.find(
      (ingredient) => ingredient.rawItemText === '混合油、郫县豆瓣',
    );
    assert.equal(grouped.rawQuantityText, '各一两');
    assert.equal(grouped.memberQuantityMode, 'same-for-each');
    assert.deepEqual(grouped.members, [
      { item: '混合油', qty: 50, unit: 'g' },
      { item: '郫县豆瓣', qty: 50, unit: 'g' },
    ]);
    const confirmed = saltFriedPork.confirmedReadings ?? [];
    assert.ok(confirmed.some((entry) => entry.raw === '待肉片炒干水汽现油时'));
  }

  const pigFeet = byName.get('姜汁蹄花');
  if (pigFeet) {
    const confirmed = pigFeet.confirmedReadings ?? [];
    assert.ok(confirmed.some((entry) => entry.raw === '煮耙捞起'));
    assert.match(pigFeet.methodSummary.steps.map((step) => step.summary).join(''), /软烂/);
  }

  const soup = byName.get('豌豆肥肠汤');
  if (soup) {
    const seasoning = soup.ingredients.find(
      (ingredient) => ingredient.rawItemText === '味精、胡椒',
    );
    assert.equal(seasoning.rawQuantityText, '各三分');
    assert.deepEqual(seasoning.members, [
      { item: '味精', qty: 1.5, unit: 'g' },
      { item: '胡椒', qty: 1.5, unit: 'g' },
    ]);
  }
});

test('batch five readings keep consumed, grouped, and approximate quantities distinct', () => {
  const byName = new Map(restored.recipes.map((recipe) => [recipe.bookName, recipe]));

  const beefJerky = byName.get('麻辣牛肉干');
  if (beefJerky) {
    const oil = beefJerky.ingredients.find(
      (ingredient) => ingredient.rawItemText === '菜油',
    );
    assert.equal(oil.rawQuantityText, '一斤耗二两');
    assert.equal(oil.normalizedQuantity.qty, 500);
    assert.equal(oil.normalizedQuantity.consumedQty, 100);
    assert.equal(oil.normalizedQuantity.consumedUnit, 'g');
  }

  const sweetSourRibs = byName.get('糖醋排骨');
  if (sweetSourRibs) {
    const aromatics = sweetSourRibs.ingredients.find(
      (ingredient) => ingredient.rawItemText === '姜、蒜片',
    );
    assert.equal(aromatics.rawQuantityText, '五钱');
    assert.equal(aromatics.memberQuantityMode, 'unallocated-group-total');
    assert.deepEqual(aromatics.groupTotal, { qty: 25, unit: 'g' });
    for (const member of aromatics.members) {
      assert.equal(member.qty, null);
      assert.equal(member.unit, null);
    }
  }

  const steamedRibs = byName.get('粉蒸排骨');
  if (steamedRibs) {
    const pepper = steamedRibs.ingredients.find(
      (ingredient) => ingredient.rawItemText === '花椒',
    );
    assert.equal(pepper.rawQuantityText, '二十余粒');
    assert.equal(pepper.normalizedQuantity.kind, 'approximate-count');
    assert.equal(pepper.normalizedQuantity.qty, null);
    assert.equal(pepper.normalizedQuantity.qualifier, '余');
  }

  const cucumberPork = byName.get('黄瓜肉片');
  if (cucumberPork) {
    const picked = cucumberPork.ingredients.find(
      (ingredient) => ingredient.rawItemText === '泡红辣椒',
    );
    assert.equal(picked.rawQuantityText, '三根');
    assert.equal(picked.normalizedQuantity.kind, 'exact-count');
    assert.equal(picked.normalizedQuantity.unit, '根');
  }

  const kohlrabiBeef = byName.get('苤蓝烧牛肉');
  if (kohlrabiBeef) {
    assert.equal(kohlrabiBeef.titleVisualCheck.matchesCatalog, true);
    assert.equal(kohlrabiBeef.source.pdfStartPage, 120);
    assert.equal(kohlrabiBeef.source.pdfEndPage, 121);
  }
});

test('batch-plan completion state agrees with assembled recipes', () => {
  const completed = new Set(restored.completedBatchIds);
  for (const batch of plan.batches) {
    if (completed.has(batch.batchId)) {
      assert.ok(batch.status === 'completed-primary-reviewed' || batch.status === 'completed-external-reviewed');
      assert.equal(batch.processedEntryCount, batch.entryCount);
      assert.equal(batch.processing.workerVisualReview, true);
      assert.ok(batch.processing.primaryVisualReview === true || batch.processing.externalVisualReview !== undefined);
      assert.equal(batch.processing.ocrUsedAsAuthority, false);
      assert.equal(batch.processing.ingredientEntryCount,
        restored.recipes
          .filter((recipe) => recipe.batchId === batch.batchId)
          .flatMap((recipe) => recipe.ingredients).length);
    } else {
      assert.equal(batch.status, 'planned-not-started');
    }
    assert.ok(planById.has(batch.batchId));
  }
  assert.equal(plan.summary.processedRecipeCount, restored.recipes.length);
  assert.equal(plan.summary.completedBatchCount, restored.completedBatchIds.length);
  assert.equal(plan.summary.remainingRecipeCount, 147 - restored.recipes.length);
});
