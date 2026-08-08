import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(new URL('../' + relativePath, import.meta.url), 'utf8'),
);

const review = readJson('data/source-restoration/dazhong-chuancai-1979-runtime-name-blocker-review.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');
const ledger = readJson('data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');

const byId = new Map(review.items.map((item) => [item.entryId, item]));

test('review artifact is read-only, baseline-pinned, and covers only p137/p161', () => {
  assert.equal(review.schema, 'kitchenmanager.source-restoration.runtime-name-blocker-review.v1');
  assert.equal(review.baseline.commit, '06b2324a4aeca3db915d3c223e758ffa13eff890');
  assert.deepEqual(review.scope.reviewedEntryIds, ['dz1979-p137', 'dz1979-p161']);
  assert.equal(review.baseline.curatedCount, 157);
  assert.equal(review.baseline.promotedCount, 31);
  assert.equal(review.baseline.remainingCount, 8);
  assert.equal(review.baseline.applicationReady, false);
  assert.deepEqual(review.verificationProblems, []);
  assert.deepEqual(review.writeTargets, [
    'data/source-restoration/dazhong-chuancai-1979-runtime-name-blocker-review.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-runtime-name-blocker-review.v1.md',
  ]);
});

test('production, ledger, and readiness remain unchanged for the reviewed blockers', () => {
  assert.equal(curated.recipes.length, 157);
  assert.equal(full.recipes.length, 264);
  assert.equal(readiness.summary.promotedNewRecipeCount, 31);
  assert.equal(readiness.summary.remainingNewRecipeCandidateCount, 8);
  assert.equal(readiness.applicationReady, false);
  for (const id of ['dz1979-p137', 'dz1979-p161']) {
    assert.equal(readiness.entries.find((entry) => entry.entryId === id)?.promotionState, 'not-promoted', id);
    assert.equal(curated.recipes.some((recipe) => recipe.id === id), false, id);
    assert.equal(full.recipes.some((recipe) => recipe.id === id), false, id);
    assert.equal(
      (ledger.batches ?? []).some((batch) => (batch.entries ?? []).some((entry) => entry.entryId === id)),
      false,
      id,
    );
  }
  assert.deepEqual(review.productionInvariants.readinessStates, {
    'dz1979-p137': 'not-promoted',
    'dz1979-p161': 'not-promoted',
  });
});

test('p137 source and exact-alias recommendation are independently recorded', () => {
  const item = byId.get('dz1979-p137');
  assert.equal(item.source.bookPage, 137);
  assert.equal(item.source.pdfPage, 150);
  assert.equal(item.source.ingredientQuote, '子公鸡一只（约三斤）');
  assert.match(item.source.methodQuote, /子公鸡/);
  assert.equal(item.currentVocabulary.canonical, '子公鸡');
  assert.equal(item.currentVocabulary.familyKey, null);
  assert.deepEqual(item.currentVocabulary.aliases, []);
  assert.equal(item.currentVocabulary.role, 'core');
  assert.equal(item.currentRuntime.compatibility, 'unresolved-name-match');
  assert.equal(item.currentRuntime.identityMatch.coverageWithProductionUnit, 'exact');
  assert.equal(item.semanticEquivalence.existingEquivalentCanonical, '鸡肉');
  assert.equal(item.options.exactAlias.status, 'recommended');
  assert.equal(item.options.exactAlias.hypotheticalCanonical, '鸡肉');
  assert.deepEqual(item.options.exactAlias.chickenFamily.familyCandidates, [
    '鸡肉', '鸡脯肉', '鸡腿', '鸡翅',
  ]);
  assert.ok(item.options.exactAlias.stockProbes.every((probe) => (
    probe.strictNameMatch === true && probe.coverage === 'exact'
  )));
  assert.equal(item.options.independentCanonical.status, 'lower-compatibility');
  assert.equal(item.options.keepBlocked.status, 'safe-now');
  assert.equal(item.recommendation, 'exact-alias-to-鸡肉');
  assert.equal(item.safeToUnlockNow, false);
});

test('p161 source and independent-canonical recommendation reject meat and duck-blood mappings', () => {
  const item = byId.get('dz1979-p161');
  assert.equal(item.source.bookPage, 161);
  assert.equal(item.source.pdfPage, 174);
  assert.equal(item.source.ingredientQuote, '鸡血一斤');
  assert.match(item.source.methodQuote, /鸡血/);
  assert.equal(item.currentVocabulary.canonical, '鸡血');
  assert.equal(item.currentVocabulary.familyKey, null);
  assert.deepEqual(item.currentVocabulary.aliases, []);
  assert.equal(item.currentVocabulary.role, 'core');
  assert.equal(item.currentRuntime.compatibility, 'unresolved-name-match');
  assert.equal(item.currentRuntime.identityMatch.coverageWithProductionUnit, 'exact');
  assert.equal(item.semanticEquivalence.existingEquivalentCanonical, null);
  assert.deepEqual(item.semanticEquivalence.rejectedMappings.map((entry) => entry.candidate), ['鸡肉', '鸭血']);
  assert.equal(item.options.exactAlias.status, 'rejected');
  assert.equal(item.options.independentCanonical.status, 'recommended');
  const probes = new Map(item.options.independentCanonical.stockProbes.map((probe) => [probe.stockName, probe]));
  assert.equal(probes.get('鸡血').strictNameMatch, true);
  assert.equal(probes.get('鸡血').coverage, 'exact');
  assert.equal(probes.get('鸭血').strictNameMatch, false);
  assert.equal(probes.get('鸭血').coverage, 'none');
  assert.equal(probes.get('鸡肉').strictNameMatch, false);
  assert.equal(probes.get('鸡肉').coverage, 'none');
  assert.equal(item.recommendation, 'new-independent-canonical-鸡血');
  assert.equal(item.safeToUnlockNow, false);
});

test('review explicitly preserves the eight remaining blockers', () => {
  assert.deepEqual(review.scope.excludedEntryIds, [
    'dz1979-p201',
    'dz1979-p203',
    'dz1979-p207',
    'dz1979-p222',
    'dz1979-p224',
    'dz1979-p226',
  ]);
  for (const id of ['dz1979-p137', 'dz1979-p161']) {
    assert.equal(byId.get(id).safeToUnlockAfterReview, true, id);
    assert.equal(byId.get(id).safeToUnlockNow, false, id);
  }
});
