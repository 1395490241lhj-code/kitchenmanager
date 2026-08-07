import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8'),
);

const crosswalk = readJson(
  'data/source-restoration/dazhong-chuancai-1979-crosswalk-dry-run.v1.json',
);
const catalog = readJson(
  'data/source-restoration/dazhong-chuancai-1979-catalog.v1.json',
);
const recipes = readJson(
  'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
);
const nameMatches = readJson(
  'data/source-restoration/dazhong-chuancai-1979-name-matches.v1.json',
);
const probableReview = readJson(
  'data/source-restoration/dazhong-chuancai-1979-crosswalk-probable-review.v1.json',
);
const applyAudit = readJson(
  'data/source-restoration/dazhong-chuancai-1979-apply-review-resolutions-audit.v1.json',
);
const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');

const curatedIds = new Set(curated.recipes.map((r) => r.id));
const fullIds = new Set(full.recipes.map((r) => r.id));
const libraryIdSets = { curated: curatedIds, full: fullIds };

const VALID_CLASSIFICATIONS = new Set([
  'exact-name',
  'confirmed-alias',
  'probable-match-needs-review',
  'book-only',
]);

const VALID_SOURCE_QUALITIES = new Set([
  'ready-for-later-promotion-review',
  'needs-source-review',
  'alternate-source-required',
]);

const catalogEntryIds = new Set(catalog.entries.map((e) => e.entryId));
const catalogBookNameByEntryId = new Map(
  catalog.entries.map((e) => [e.entryId, e.bookName]),
);
const recipeByEntryId = new Map(recipes.recipes.map((r) => [r.entryId, r]));
const nameMatchByEntryId = new Map(
  nameMatches.bookMatches.map((e) => [e.entryId, e]),
);

const NAME_MATCH_TO_CROSSWALK = {
  exact_name: 'exact-name',
  clear_alias: 'confirmed-alias',
  suspected_match: 'probable-match-needs-review',
  book_only: 'book-only',
};

test('crosswalk covers exactly the 147 catalog entryIds with no duplicates', () => {
  const ids = crosswalk.entries.map((e) => e.entryId);
  assert.equal(ids.length, 147);
  assert.equal(new Set(ids).size, 147);
  assert.deepEqual(new Set(ids), catalogEntryIds);
});

test('every entry carries the required crosswalk fields', () => {
  const required = [
    'entryId',
    'bookName',
    'sourceProjectMatchBefore',
    'proposedClassification',
    'projectName',
    'projectIds',
    'candidateProjectName',
    'candidateProjectIds',
    'evidence',
    'sourceQuality',
    'reviewRequired',
    'manyToOne',
    'collision',
  ];
  for (const entry of crosswalk.entries) {
    for (const field of required) {
      assert.ok(
        Object.prototype.hasOwnProperty.call(entry, field),
        `${entry.entryId} missing ${field}`,
      );
    }
  }
});

test('bookName in the crosswalk matches catalog for all 147 entries', () => {
  for (const entry of crosswalk.entries) {
    assert.equal(
      entry.bookName,
      catalogBookNameByEntryId.get(entry.entryId),
      `${entry.entryId} bookName mismatch`,
    );
  }
});

test('classification counts are valid and sum to 147', () => {
  const counts = crosswalk.summary.classificationCounts;
  const total = Object.values(counts).reduce((sum, n) => sum + n, 0);
  assert.equal(total, 147);
  assert.equal(crosswalk.entries.length, 147);
  for (const entry of crosswalk.entries) {
    assert.ok(
      VALID_CLASSIFICATIONS.has(entry.proposedClassification),
      `${entry.entryId} invalid classification: ${entry.proposedClassification}`,
    );
  }
});

test('all confirmed project IDs exist in the current target library', () => {
  for (const entry of crosswalk.entries) {
    for (const { library, id } of entry.projectIds) {
      const idSet = libraryIdSets[library];
      assert.ok(idSet, `${entry.entryId} unknown library ${library}`);
      assert.ok(idSet.has(id), `${entry.entryId} dangling ${library}/${id}`);
    }
  }
});

test('probable candidates never appear in confirmed projectIds', () => {
  for (const entry of crosswalk.entries) {
    if (entry.proposedClassification === 'probable-match-needs-review') {
      assert.equal(entry.projectIds.length, 0, entry.entryId);
      assert.ok(entry.candidateProjectIds.length > 0, entry.entryId);
      assert.equal(entry.reviewRequired, true, entry.entryId);
      assert.equal(entry.projectName, null, entry.entryId);
      assert.ok(entry.candidateProjectName, entry.entryId);
    }
  }
});

test('confirmed classifications bind real project IDs; book-only binds none', () => {
  for (const entry of crosswalk.entries) {
    if (entry.proposedClassification === 'exact-name' || entry.proposedClassification === 'confirmed-alias') {
      assert.ok(entry.projectIds.length > 0, entry.entryId);
      assert.ok(entry.projectName, entry.entryId);
    }
    if (entry.proposedClassification === 'book-only') {
      assert.equal(entry.projectIds.length, 0, entry.entryId);
      assert.equal(entry.projectName, null, entry.entryId);
    }
  }
});

test('all B-class alternate-source-required entries are marked in the crosswalk', () => {
  const expected = applyAudit.unchangedByDesign.alternateSourceRequired;
  assert.equal(expected.length, 12);
  const crosswalkAlt = crosswalk.entries.filter(
    (e) => e.sourceQuality === 'alternate-source-required',
  );
  assert.equal(crosswalkAlt.length, 12);
  const crosswalkAltIds = new Set(crosswalkAlt.map((e) => e.entryId));
  assert.deepEqual(crosswalkAltIds, new Set(expected));
});

test('sourceQuality is a valid independent dimension for all entries', () => {
  for (const entry of crosswalk.entries) {
    assert.ok(
      VALID_SOURCE_QUALITIES.has(entry.sourceQuality),
      `${entry.entryId} invalid sourceQuality: ${entry.sourceQuality}`,
    );
  }
});

test('every entry carries sourceQualityReasons', () => {
  assert.equal(crosswalk.entries.length, 147);
  for (const entry of crosswalk.entries) {
    assert.ok(
      Array.isArray(entry.sourceQualityReasons),
      `${entry.entryId} sourceQualityReasons is not an array`,
    );
  }
});

test('sourceQuality counts sum to 147', () => {
  const counts = crosswalk.summary.sourceQualityCounts;
  const total = Object.values(counts).reduce((sum, n) => sum + n, 0);
  assert.equal(total, 147);
  const actual = {};
  for (const entry of crosswalk.entries) {
    actual[entry.sourceQuality] = (actual[entry.sourceQuality] ?? 0) + 1;
  }
  assert.deepEqual(actual, counts);
});

test('alternate-source-required set stays exactly the 12 B-class entries', () => {
  const expected = new Set(applyAudit.unchangedByDesign.alternateSourceRequired);
  assert.equal(expected.size, 12);
  const alt = crosswalk.entries.filter((e) => e.sourceQuality === 'alternate-source-required');
  assert.equal(alt.length, 12);
  assert.deepEqual(new Set(alt.map((e) => e.entryId)), expected);
  for (const entry of alt) {
    assert.ok(entry.sourceQualityReasons.length > 0, entry.entryId);
  }
});

test('needs-source-review entries each carry at least one source-fidelity reason', () => {
  const needs = crosswalk.entries.filter((e) => e.sourceQuality === 'needs-source-review');
  assert.ok(needs.length > 0);
  for (const entry of needs) {
    assert.ok(entry.sourceQualityReasons.length > 0, entry.entryId);
  }
});

test('ready entries always have an empty sourceQualityReasons array', () => {
  const ready = crosswalk.entries.filter((e) => e.sourceQuality === 'ready-for-later-promotion-review');
  assert.ok(ready.length > 0);
  for (const entry of ready) {
    assert.deepEqual(entry.sourceQualityReasons, [], entry.entryId);
  }
});

test('source-quality reasons never reference crosswalk/mapping fields', () => {
  const taintPattern = /projectMatch|reviewRequired|candidateProject|name-match|crosswalk/i;
  for (const entry of crosswalk.entries) {
    for (const reason of entry.sourceQualityReasons) {
      assert.ok(
        !taintPattern.test(reason),
        `${entry.entryId} mapping-tainted reason: ${reason}`,
      );
    }
  }
});

test('probable-match-needs-review does not by itself cause needs-source-review', () => {
  for (const entry of crosswalk.entries) {
    if (entry.proposedClassification === 'probable-match-needs-review') {
      assert.ok(
        entry.sourceQuality === 'ready-for-later-promotion-review' ||
          (entry.sourceQuality === 'needs-source-review' && entry.sourceQualityReasons.length > 0),
        `${entry.entryId} probable should only be needs with concrete source-fidelity reasons`,
      );
      assert.equal(entry.reviewRequired, true, entry.entryId);
    }
  }
});

test('crosswalk classification is consistent with canonical recipes and name-matches', () => {
  const reviewDecisionById = new Map(
    probableReview.items.map((item) => [item.entryId, item]),
  );
  for (const entry of crosswalk.entries) {
    const recipe = recipeByEntryId.get(entry.entryId);
    const nameMatch = nameMatchByEntryId.get(entry.entryId);
    assert.ok(recipe, `${entry.entryId} missing in recipes`);
    assert.ok(nameMatch, `${entry.entryId} missing in name-matches`);

    assert.equal(
      entry.sourceProjectMatchBefore.classification,
      recipe.projectMatch.classification,
      `${entry.entryId} sourceProjectMatchBefore drift`,
    );
    const nameOnlyClass = NAME_MATCH_TO_CROSSWALK[nameMatch.classification.id];
    if (nameOnlyClass === entry.proposedClassification) continue;
    // Divergence from the name-only baseline is only allowed where the
    // probable-review artifact adjudicated the body evidence at high
    // confidence.
    const adjudication = reviewDecisionById.get(entry.entryId);
    assert.ok(adjudication, `${entry.entryId} unexplained classification drift`);
    if (entry.proposedClassification === 'confirmed-alias') {
      assert.equal(adjudication.decision, 'confirmed-alias', entry.entryId);
      assert.equal(adjudication.confidence, 'high', entry.entryId);
    } else if (entry.proposedClassification === 'book-only') {
      assert.equal(adjudication.decision, 'reject-candidate', entry.entryId);
      assert.equal(adjudication.confidence, 'high', entry.entryId);
    } else {
      assert.fail(`${entry.entryId} unexpected drift target ${entry.proposedClassification}`);
    }
  }
});

test('collision and manyToOne are explicitly recorded and never coexist', () => {
  for (const entry of crosswalk.entries) {
    assert.ok(!(entry.manyToOne && entry.collision), entry.entryId);
  }
  assert.equal(
    crosswalk.entries.filter((e) => e.collision).length,
    crosswalk.summary.collisionCount,
  );
  assert.equal(
    crosswalk.entries.filter((e) => e.manyToOne).length,
    crosswalk.summary.manyToOneCount,
  );
});

test('no consistency problems were recorded during generation', () => {
  assert.deepEqual(crosswalk.consistencyProblems, []);
  assert.equal(crosswalk.summary.consistencyProblemsCount, 0);
});

test('dry-run artifact asserts no production promotion', () => {
  assert.equal(crosswalk.applicationReady, false);
  assert.equal(crosswalk.productionPromotion, false);
});
