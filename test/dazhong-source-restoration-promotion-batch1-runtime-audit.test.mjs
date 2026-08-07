import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8'),
);

const audit = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch1-runtime-audit.v1.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const ledger = readJson('data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json');

const EXPECTED_IDS = ['dz1979-p143', 'dz1979-p180', 'dz1979-p195', 'dz1979-p200', 'dz1979-p204'];
const VALID_COMPATIBILITY = new Set([
  'exact-compatible',
  'expected-unit-confirmation',
  'unresolved-name-match',
]);

test('all five promoted recipes are covered by the audit', () => {
  const covered = new Set(audit.entries.map((entry) => entry.productionId));
  assert.deepEqual([...covered].sort(), EXPECTED_IDS.slice().sort());
  const ledgerIds = new Set(
    (ledger.batches ?? []).flatMap((batch) => (
      (batch.entries ?? []).map((entry) => entry.productionId)
    )),
  );
  assert.deepEqual(covered, ledgerIds);
});

test('every audited ingredient has exactly one compatibility result', () => {
  assert.equal(audit.entries.length, 19);
  for (const entry of audit.entries) {
    assert.ok(VALID_COMPATIBILITY.has(entry.compatibility), `${entry.productionId}:${entry.item}`);
    assert.ok(entry.item, entry.productionId);
    assert.ok(entry.qty !== null && entry.unit !== null, `${entry.productionId}:${entry.item}`);
    assert.ok(entry.reasons.length > 0, `${entry.productionId}:${entry.item}`);
    assert.equal(entry.normalizedQuantity.finite, true, `${entry.productionId}:${entry.item}`);
  }
});

test('audited items match the production curated ingredient maps exactly', () => {
  for (const entry of audit.entries) {
    const production = curated.recipe_ingredients[entry.productionId]
      .find((ingredient) => ingredient.item === entry.item);
    assert.deepEqual(production, { item: entry.item, qty: entry.qty, unit: entry.unit }, `${entry.productionId}:${entry.item}`);
  }
});

test('unresolved-name-match records the concrete failing name pairs', () => {
  const unresolved = audit.entries.filter((entry) => entry.compatibility === 'unresolved-name-match');
  assert.equal(unresolved.length, 1);
  const entry = unresolved[0];
  assert.equal(entry.productionId, 'dz1979-p143');
  assert.equal(entry.item, '仔母鸡');
  const failed = new Set(entry.probes
    .filter((probe) => !probe.strictNameMatch)
    .map((probe) => probe.probeName));
  assert.ok(failed.has('鸡肉'), 'missing 仔母鸡 vs 鸡肉 pair');
  assert.ok(failed.has('仔鸡'), 'missing 仔母鸡 vs 仔鸡 pair');
  const details = audit.summary.unresolvedDetails.find((detail) => detail.item === '仔母鸡');
  assert.ok(details.failedPairs.includes('仔母鸡 vs 鸡肉'));
  assert.ok(details.failedPairs.includes('仔母鸡 vs 仔鸡'));
});

test('unit mismatch is never disguised as exact-compatible', () => {
  const tofu = audit.entries.find((entry) => entry.item === '豆腐');
  assert.ok(tofu, 'missing 豆腐 audit entry');
  assert.equal(tofu.compatibility, 'expected-unit-confirmation');
  assert.equal(tofu.qty, '6');
  assert.equal(tofu.unit, '个');
  // The box-unit probe must surface as unit-mismatch, not exact.
  const boxProbe = tofu.probes.find((probe) => probe.coverageWithDefaultUnit === 'unit-mismatch');
  assert.ok(boxProbe, 'missing unit-mismatch probe for 豆腐');
  assert.equal(boxProbe.strictNameMatch, true);
  // No ingredient with a unit-confirmation outcome may be counted exact.
  assert.equal(
    audit.entries.filter((entry) => (
      entry.compatibility === 'expected-unit-confirmation'
      && entry.unit === 'g'
    )).length,
    0,
  );
});

test('summary counts are internally consistent', () => {
  const { summary } = audit;
  assert.equal(summary.auditedIngredientCount, audit.entries.length);
  assert.equal(summary.exactCompatibleCount, audit.entries.filter((e) => e.compatibility === 'exact-compatible').length);
  assert.equal(summary.expectedUnitConfirmationCount, audit.entries.filter((e) => e.compatibility === 'expected-unit-confirmation').length);
  assert.equal(summary.unresolvedNameMatchCount, audit.entries.filter((e) => e.compatibility === 'unresolved-name-match').length);
  assert.equal(
    summary.exactCompatibleCount + summary.expectedUnitConfirmationCount + summary.unresolvedNameMatchCount,
    audit.entries.length,
  );
  assert.equal(summary.affectedRecipes.length, 2);
  assert.deepEqual(summary.affectedRecipes.sort(), ['dz1979-p143', 'dz1979-p180']);
  assert.equal(summary.coreIngredientCount, 7);
});

test('quantity provenance is recorded and unmodified for every audited ingredient', () => {
  for (const entry of audit.entries) {
    assert.ok(entry.sourceRawQuantityText, `${entry.productionId}:${entry.item} missing raw qty`);
    assert.ok(entry.quantityProvenanceNote, `${entry.productionId}:${entry.item} missing provenance note`);
    assert.match(entry.quantityProvenanceNote, /未经人工改值/, `${entry.productionId}:${entry.item}`);
    assert.equal(entry.qty, String(entry.normalizedQuantitySource.qty), `${entry.productionId}:${entry.item}`);
  }
  const salt = audit.entries.find((entry) => entry.item === '盐' && entry.qty === '40');
  assert.ok(salt, 'missing 盐40g entry');
  assert.equal(salt.sourceRawQuantityText, '八钱');
  assert.equal(salt.normalizedQuantitySource.qty, 40);
});

test('audit artifact asserts no production writes', () => {
  assert.equal(audit.verificationProblems.length, 0);
  assert.equal(curated.recipes.length, 131);
  assert.equal(curated.recipes.filter((r) => r.id.startsWith('dz1979-')).length, 5);
});
