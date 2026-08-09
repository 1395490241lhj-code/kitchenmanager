import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
import { classifyRecipeIngredient } from '../src/utils/recipe-sanitizer.js';

const repoRoot = new URL('..', import.meta.url).pathname;
const readJson = (file) => JSON.parse(fs.readFileSync(new URL('../' + file, import.meta.url), 'utf8'));
const review = readJson('data/source-restoration/dazhong-chuancai-1979-final-quantity-blocker-review.v1.json');
const recipes = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');
const byId = new Map(review.items.map((item) => [item.entryId, item]));
const recipeById = new Map(recipes.recipes.map((recipe) => [recipe.entryId, recipe]));

test('review is baseline-pinned, complete, read-only, and safe only for non-exact entries', () => {
  assert.equal(review.baseline.commit, '24c6d4a4a7f4bbcff3feba63e833007bc91602a3');
  assert.deepEqual(review.scope.reviewedEntryIds, ['dz1979-p201', 'dz1979-p203', 'dz1979-p207', 'dz1979-p222', 'dz1979-p224', 'dz1979-p226']);
  assert.equal(review.safeToAllow, true);
  assert.deepEqual(review.verificationProblems, []);
  assert.deepEqual(review.writeTargets, [
    'data/source-restoration/dazhong-chuancai-1979-final-quantity-blocker-review.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-final-quantity-blocker-review.v1.md',
  ]);
  assert.match(review.lunaWorkerEvidence.role, /auxiliary/);
  assert.equal(review.lunaWorkerEvidence.authoritativeDecision, 'main-agent-independent-scan-and-code-review');
});

test('three non-exact scan readings are authentic seasoning and approve only null/null', () => {
  for (const id of ['dz1979-p201', 'dz1979-p203', 'dz1979-p207']) {
    const item = byId.get(id);
    const canonical = recipeById.get(id).ingredients.find((ingredient) => ingredient.rawItemText === '花椒');
    assert.equal(item.sourceEvidence.visuallyConfirmed, true, id);
    assert.equal(item.sourceEvidence.matchesCanonical, true, id);
    assert.equal(item.sourceEvidence.scanQuote, '花椒 十余粒', id);
    assert.equal(canonical.rawQuantityText, '十余粒', id);
    assert.deepEqual(canonical.normalizedQuantity, { kind: 'approximate-count', qty: null, unit: '粒', appliesTo: 'item', qualifier: '十余' }, id);
    assert.equal(classifyRecipeIngredient('花椒').role, 'seasoning');
    assert.equal(item.runtimeRole.role, 'seasoning', id);
    assert.deepEqual(item.productionProjection, { item: '花椒', qty: null, unit: null }, id);
    assert.equal(item.safeToUnlock, true, id);
    assert.equal(item.schemaExtensionNeeded, false, id);
  }
  assert.deepEqual(review.reviewedNonExactNullAllowlist, {
    'dz1979-p201': ['花椒'],
    'dz1979-p203': ['花椒'],
    'dz1979-p207': ['花椒'],
  });
});

test('consumed-dual source pairs remain distinct and all three stay blocked', () => {
  const expected = {
    'dz1979-p222': [['菜油', 500, 100]],
    'dz1979-p224': [['菜油', 500, 100]],
    'dz1979-p226': [['菜油', 500, 100], ['干豆粉', 500, 200]],
  };
  for (const [id, pairs] of Object.entries(expected)) {
    const item = byId.get(id);
    assert.equal(item.safeToUnlock, false, id);
    assert.equal(item.schemaExtensionNeeded, true, id);
    assert.equal(item.recommendation, 'continue-blocked-until-dual-quantity-contract', id);
    assert.deepEqual(item.quantityStructure.map((pair) => [pair.item, pair.input.qty, pair.consumed.qty]), pairs, id);
    assert.equal(item.options.A.proposal, 'store-input-qty');
    assert.equal(item.options.B.proposal, 'store-consumed-qty');
    assert.equal(item.options.C.proposal, 'store-null-with-source-provenance');
    assert.equal(item.options.D.proposal, 'extend-production-schema');
    assert.equal(item.options.E.proposal, 'continue-blocked');
  }
  assert.equal(classifyRecipeIngredient('干豆粉').role, 'core');
});

test('frozen source inputs remain byte-identical to the review baseline', () => {
  const protectedPaths = [
    'data/sichuan-recipes.json',
    'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-crosswalk-dry-run.v1.json',
    'data/source-restoration/dazhong-chuancai-1979-name-matches.v1.json',
  ];
  for (const file of protectedPaths) {
    const baseline = execFileSync('git', ['show', review.baseline.commit + ':' + file], { cwd: repoRoot, maxBuffer: 32 * 1024 * 1024 });
    assert.deepEqual(fs.readFileSync(new URL('../' + file, import.meta.url)), baseline, file);
  }
  assert.deepEqual(review.productionInvariants, {
    curatedCount: 159,
    fullCount: 264,
    promotedCount: 33,
    remainingCount: 6,
    applicationReady: false,
    reviewedIdsAbsentFromCurated: true,
    reviewedIdsAbsentFromFull: true,
    reviewedIdsAbsentFromLedger: true,
  });
});
