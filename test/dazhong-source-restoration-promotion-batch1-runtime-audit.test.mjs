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
  const covered = new Set([
    ...audit.coreCompatibility.map((entry) => entry.productionId),
    ...audit.nonCoreObservations.map((entry) => entry.productionId),
  ]);
  assert.deepEqual([...covered].sort(), EXPECTED_IDS.slice().sort());
  const ledgerIds = new Set(
    (ledger.batches ?? []).flatMap((batch) => (
      (batch.entries ?? []).map((entry) => entry.productionId)
    )),
  );
  assert.deepEqual(covered, ledgerIds);
});

test('every core ingredient has exactly one compatibility result', () => {
  assert.equal(audit.coreCompatibility.length, 7);
  assert.equal(audit.nonCoreObservations.length, 12);
  assert.equal(audit.coreCompatibility.length + audit.nonCoreObservations.length, 19);
  for (const entry of audit.coreCompatibility) {
    assert.ok(VALID_COMPATIBILITY.has(entry.compatibility), `${entry.productionId}:${entry.item}`);
    assert.ok(entry.item, entry.productionId);
    assert.ok(entry.qty !== null && entry.unit !== null, `${entry.productionId}:${entry.item}`);
    assert.ok(entry.reasons.length > 0, `${entry.productionId}:${entry.item}`);
    assert.equal(entry.normalizedQuantity.finite, true, `${entry.productionId}:${entry.item}`);
    assert.equal(entry.role, 'core', `${entry.productionId}:${entry.item}`);
  }
});

test('audited items match the production curated ingredient maps exactly', () => {
  const allEntries = [...audit.coreCompatibility, ...audit.nonCoreObservations];
  for (const entry of allEntries) {
    const production = curated.recipe_ingredients[entry.productionId]
      .find((ingredient) => ingredient.item === entry.item);
    assert.deepEqual(production, { item: entry.item, qty: entry.qty, unit: entry.unit }, `${entry.productionId}:${entry.item}`);
  }
});

test('no unresolved-name-match remains after the 仔母鸡 alias fix', () => {
  assert.equal(audit.summary.coreCompatibilityCounts['unresolved-name-match'], 0);
  assert.deepEqual(audit.summary.unresolvedDetails, []);
  const hen = audit.coreCompatibility.find((entry) => entry.item === '仔母鸡');
  assert.ok(hen, 'missing 仔母鸡 audit entry');
  assert.equal(hen.compatibility, 'expected-unit-confirmation');
  assert.equal(hen.canonical, '鸡肉');
  assert.equal(hen.ingredientFamilyKey, 'chicken');
  const chicken = hen.probes.find((probe) => probe.probeName === '鸡肉');
  assert.ok(chicken && chicken.strictNameMatch, '仔母鸡 vs 鸡肉 must strictly match');
  const youngRooster = hen.probes.find((probe) => probe.probeName === '仔鸡');
  assert.ok(youngRooster && youngRooster.strictNameMatch, '仔母鸡 vs 仔鸡 must strictly match');
});

test('unit mismatch is never disguised as exact-compatible', () => {
  const tofu = audit.coreCompatibility.find((entry) => entry.item === '豆腐');
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
    audit.coreCompatibility.filter((entry) => (
      entry.compatibility === 'expected-unit-confirmation'
      && entry.unit === 'g'
    )).length,
    0,
  );
});

test('summary counts are internally consistent and core-only', () => {
  const { summary } = audit;
  assert.equal(summary.auditedIngredientCount, 19);
  assert.equal(summary.coreIngredientCount, 7);
  assert.equal(summary.nonCoreIngredientCount, 12);
  const { coreCompatibilityCounts } = summary;
  assert.equal(coreCompatibilityCounts['exact-compatible'], 5);
  assert.equal(coreCompatibilityCounts['expected-unit-confirmation'], 2);
  assert.equal(coreCompatibilityCounts['unresolved-name-match'], 0);
  assert.equal(
    Object.values(coreCompatibilityCounts).reduce((sum, n) => sum + n, 0),
    audit.coreCompatibility.length,
  );
  assert.equal(
    audit.coreCompatibility.filter((e) => e.compatibility === 'exact-compatible').length,
    coreCompatibilityCounts['exact-compatible'],
  );
  assert.equal(summary.affectedRecipes.length, 2);
  assert.deepEqual(summary.affectedRecipes.sort(), ['dz1979-p143', 'dz1979-p180']);
});

test('quantity provenance is recorded and unmodified for every audited ingredient', () => {
  const allEntries = [...audit.coreCompatibility, ...audit.nonCoreObservations];
  for (const entry of allEntries) {
    assert.ok(entry.sourceRawQuantityText, `${entry.productionId}:${entry.item} missing raw qty`);
    assert.ok(entry.quantityProvenanceNote, `${entry.productionId}:${entry.item} missing provenance note`);
    assert.match(entry.quantityProvenanceNote, /未经人工改值/, `${entry.productionId}:${entry.item}`);
    assert.equal(entry.qty, String(entry.normalizedQuantitySource.qty), `${entry.productionId}:${entry.item}`);
  }
  const salt = audit.nonCoreObservations.find((entry) => entry.item === '盐' && entry.qty === '40');
  assert.ok(salt, 'missing 盐40g entry');
  assert.equal(salt.sourceRawQuantityText, '八钱');
  assert.equal(salt.normalizedQuantitySource.qty, 40);
});

test('every exact-compatible core entry has real coverage=exact evidence', () => {
  const exact = audit.coreCompatibility.filter((entry) => entry.compatibility === 'exact-compatible');
  assert.equal(exact.length, 5);
  for (const entry of exact) {
    const evidence = entry.probes.filter((probe) => probe.coverageWithProductionUnit === 'exact');
    assert.ok(evidence.length > 0, `${entry.productionId}:${entry.item} lacks exact coverage evidence`);
    assert.ok(evidence.some((probe) => probe.strictNameMatch), `${entry.productionId}:${entry.item} evidence not strict`);
  }
});

test('no coverage=none entry is ever counted exact-compatible', () => {
  for (const entry of audit.coreCompatibility) {
    if (entry.compatibility !== 'exact-compatible') continue;
    assert.ok(
      entry.probes.some((probe) => probe.coverageWithProductionUnit === 'exact'),
      `${entry.productionId}:${entry.item} exact without real coverage`,
    );
    assert.ok(
      !(entry.probes.length === 0),
      `${entry.productionId}:${entry.item} no probes`,
    );
  }
});

test('non-core observations never enter the three-way classification', () => {
  for (const entry of audit.nonCoreObservations) {
    assert.equal(entry.compatibility, undefined, `${entry.productionId}:${entry.item}`);
    assert.ok(entry.role !== 'core', `${entry.productionId}:${entry.item}`);
    assert.ok(entry.sourceRawQuantityText, `${entry.productionId}:${entry.item}`);
  }
  assert.equal(audit.summary.coreCompatibilityCounts['exact-compatible'], 5);
  assert.equal(audit.summary.coreCompatibilityCounts['expected-unit-confirmation'], 2);
  assert.equal(audit.summary.coreCompatibilityCounts['unresolved-name-match'], 0);
});

test('audit artifact asserts no production writes', () => {
  assert.equal(audit.verificationProblems.length, 0);
  assert.equal(curated.recipes.length, 131);
  assert.equal(curated.recipes.filter((r) => r.id.startsWith('dz1979-')).length, 5);
});
