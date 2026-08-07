import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

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
    'ingredientPreview',
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
    assert.ok(entry.ingredientPreview.length > 0, entry.entryId);
  }
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
