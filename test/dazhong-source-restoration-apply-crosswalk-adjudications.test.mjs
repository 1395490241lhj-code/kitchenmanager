import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8'),
);

const restored = readJson(
  'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
);
const nameMatches = readJson(
  'data/source-restoration/dazhong-chuancai-1979-name-matches.v1.json',
);
const probableReview = readJson(
  'data/source-restoration/dazhong-chuancai-1979-crosswalk-probable-review.v1.json',
);
const applyAudit = readJson(
  'data/source-restoration/dazhong-chuancai-1979-apply-crosswalk-adjudications.v1.json',
);
const crosswalk = readJson(
  'data/source-restoration/dazhong-chuancai-1979-crosswalk-dry-run.v1.json',
);
const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');

const curatedIds = new Set(curated.recipes.map((r) => r.id));
const fullIds = new Set(full.recipes.map((r) => r.id));

const restoredById = new Map(restored.recipes.map((r) => [r.entryId, r]));
const crosswalkById = new Map(crosswalk.entries.map((e) => [e.entryId, e]));
const nameMatchById = new Map(
  nameMatches.bookMatches.map((e) => [e.entryId, e]),
);

const expectedAdjudicated = {
  'dz1979-p141': {
    classification: 'confirmed-alias',
    projectName: '热窝姜汁鸡',
    projectIds: [{ library: 'full', id: 'ex--832d7c5d' }],
    candidateProjectName: null,
    reviewRequired: false,
  },
  'dz1979-p168': {
    classification: 'book-only',
    projectName: null,
    projectIds: [],
    candidateProjectName: null,
    reviewRequired: false,
  },
  'dz1979-p177': {
    classification: 'confirmed-alias',
    projectName: '麻婆豆腐',
    projectIds: [{ library: 'curated', id: 'fam-mapo-tofu' }],
    candidateProjectName: null,
    reviewRequired: false,
  },
  'dz1979-p206': {
    classification: 'book-only',
    projectName: null,
    projectIds: [],
    candidateProjectName: null,
    reviewRequired: false,
  },
};

const EXPECTED_PROBABLE = {
  classification: 'probable-match-needs-review',
  projectName: null,
  projectIds: [],
  candidateProjectName: '干煸鳝鱼',
  reviewRequired: true,
};

test('the four adjudicated canonical projectMatch values are applied exactly', () => {
  for (const [entryId, expected] of Object.entries(expectedAdjudicated)) {
    assert.deepEqual(restoredById.get(entryId).projectMatch, expected, entryId);
  }
});

test('dz1979-p173 remains completely unchanged', () => {
  assert.deepEqual(restoredById.get('dz1979-p173').projectMatch, EXPECTED_PROBABLE);
  assert.equal(restoredById.get('dz1979-p173').projectMatch.reviewRequired, true);
  assert.deepEqual(restoredById.get('dz1979-p173').projectMatch.projectIds, []);
});

test('chunk/worker/assembled layers are consistent for all four adjudicated entries', () => {
  const workerFiles = [
    ['dz1979-p141', 'data/source-restoration/dz1979-b07-worker.json'],
    ['dz1979-p168', 'data/source-restoration/dz1979-b08-worker.json'],
    ['dz1979-p177', 'data/source-restoration/dz1979-b09-worker.json'],
    ['dz1979-p206', 'data/source-restoration/dz1979-b10-worker.json'],
  ];
  const chunkFiles = [
    ['dz1979-p141', 'data/source-restoration/b07-chunks/dz1979-b07-chunk2b.json'],
    ['dz1979-p168', 'data/source-restoration/b08-chunks/dz1979-b08-chunk5.json'],
    ['dz1979-p177', 'data/source-restoration/b09-chunks/dz1979-b09-chunk1.json'],
    ['dz1979-p206', 'data/source-restoration/b10-chunks/dz1979-b10-chunk4.json'],
  ];
  for (const [entryId, workerPath] of workerFiles) {
    const worker = readJson(workerPath);
    const workerRecipe = worker.recipes.find((r) => r.entryId === entryId);
    assert.deepEqual(
      workerRecipe.projectMatch,
      restoredById.get(entryId).projectMatch,
      `${entryId} worker vs assembled mismatch`,
    );
  }
  for (const [entryId, chunkPath] of chunkFiles) {
    const chunk = readJson(chunkPath);
    const chunkRecipe = chunk.recipes.find((r) => r.entryId === entryId);
    assert.deepEqual(
      chunkRecipe.projectMatch,
      restoredById.get(entryId).projectMatch,
      `${entryId} chunk vs assembled mismatch`,
    );
  }
});

test('name-matches keeps the historical 74/5/5/63 name-only baseline untouched', () => {
  const counts = {};
  for (const entry of nameMatches.bookMatches) {
    const id = entry.classification.id;
    counts[id] = (counts[id] ?? 0) + 1;
  }
  assert.deepEqual(counts, {
    exact_name: 74,
    clear_alias: 5,
    suspected_match: 5,
    book_only: 63,
  });
  for (const entryId of Object.keys(expectedAdjudicated)) {
    assert.equal(nameMatchById.get(entryId).classification.id, 'suspected_match', entryId);
  }
});

test('all canonical/name-matches baseline differences are explained by probable-review', () => {
  const reviewDecisionById = new Map(
    probableReview.items.map((item) => [item.entryId, item]),
  );
  const classMap = {
    exact_name: 'exact-name',
    clear_alias: 'confirmed-alias',
    suspected_match: 'probable-match-needs-review',
    book_only: 'book-only',
  };
  const explained = new Set();
  for (const entry of restored.recipes) {
    const nmClass = classMap[nameMatchById.get(entry.entryId).classification.id];
    if (nmClass === entry.projectMatch.classification) continue;
    const review = reviewDecisionById.get(entry.entryId);
    assert.ok(review, `${entry.entryId} unexplained classification drift`);
    if (entry.projectMatch.classification === 'confirmed-alias') {
      assert.equal(review.decision, 'confirmed-alias', entry.entryId);
      assert.equal(review.confidence, 'high', entry.entryId);
    } else if (entry.projectMatch.classification === 'book-only') {
      assert.equal(review.decision, 'reject-candidate', entry.entryId);
      assert.equal(review.confidence, 'high', entry.entryId);
    } else {
      assert.fail(`${entry.entryId} unexpected drift target ${entry.projectMatch.classification}`);
    }
    explained.add(entry.entryId);
  }
  assert.deepEqual(explained, new Set(Object.keys(expectedAdjudicated)));
});

test('no other unexplained classification drift exists', () => {
  const classMap = {
    exact_name: 'exact-name',
    clear_alias: 'confirmed-alias',
    suspected_match: 'probable-match-needs-review',
    book_only: 'book-only',
  };
  const expectedDrift = new Set(Object.keys(expectedAdjudicated));
  const drifted = restored.recipes.filter((recipe) => {
    const nmClass = classMap[nameMatchById.get(recipe.entryId).classification.id];
    return nmClass !== recipe.projectMatch.classification;
  }).map((recipe) => recipe.entryId);
  assert.deepEqual(new Set(drifted), expectedDrift);
});

test('crosswalk statistics are 74/7/1/65 with 81 confirmed mappings', () => {
  const counts = crosswalk.summary.classificationCounts;
  assert.deepEqual(counts, {
    'exact-name': 74,
    'confirmed-alias': 7,
    'probable-match-needs-review': 1,
    'book-only': 65,
  });
  assert.equal(crosswalk.summary.confirmedProjectMappingTotal, 81);
});

test('crosswalk sourceQuality remains 90/45/12', () => {
  assert.deepEqual(crosswalk.summary.sourceQualityCounts, {
    'ready-for-later-promotion-review': 90,
    'needs-source-review': 45,
    'alternate-source-required': 12,
  });
});

test('p168/p206 candidates are cleared from canonical and crosswalk', () => {
  for (const entryId of ['dz1979-p168', 'dz1979-p206']) {
    const canonical = restoredById.get(entryId).projectMatch;
    assert.equal(canonical.candidateProjectName, null, entryId);
    assert.deepEqual(canonical.projectIds, [], entryId);
    const walk = crosswalkById.get(entryId);
    assert.equal(walk.proposedClassification, 'book-only', entryId);
    assert.deepEqual(walk.candidateProjectIds, [], entryId);
    assert.equal(walk.candidateProjectName, null, entryId);
  }
});

test('p141/p177 bindings point to real project IDs', () => {
  assert.ok(fullIds.has('ex--832d7c5d'));
  assert.ok(curatedIds.has('fam-mapo-tofu'));
  for (const [entryId, { projectIds }] of Object.entries(expectedAdjudicated)) {
    if (projectIds.length === 0) continue;
    for (const { library, id } of projectIds) {
      const idSet = library === 'curated' ? curatedIds : fullIds;
      assert.ok(idSet.has(id), `${entryId} dangling ${library}/${id}`);
    }
    assert.deepEqual(restoredById.get(entryId).projectMatch.projectIds, projectIds, entryId);
    assert.equal(crosswalkById.get(entryId).proposedClassification, 'confirmed-alias', entryId);
  }
});

test('p173 still has no confirmed projectIds and reviewRequired=true in crosswalk', () => {
  const walk = crosswalkById.get('dz1979-p173');
  assert.equal(walk.proposedClassification, 'probable-match-needs-review');
  assert.equal(walk.reviewRequired, true);
  assert.deepEqual(walk.projectIds, []);
  assert.deepEqual(walk.candidateProjectIds.length > 0, true);
  assert.equal(walk.candidateProjectName, '干煸鳝鱼');
});

test('applicationReady stays false everywhere', () => {
  assert.equal(restored.applicationReady, false);
  assert.equal(crosswalk.applicationReady, false);
  assert.equal(applyAudit.applicationReady, false);
  assert.equal(nameMatches.applicationReady, false);
});
