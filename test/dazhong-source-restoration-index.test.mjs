import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';

const files = {
  catalog: new URL('../data/source-restoration/dazhong-chuancai-1979-catalog.v1.json', import.meta.url),
  matches: new URL('../data/source-restoration/dazhong-chuancai-1979-name-matches.v1.json', import.meta.url),
  batchPlan: new URL('../data/source-restoration/dazhong-chuancai-1979-batch-plan.v1.json', import.meta.url),
  curated: new URL('../data/sichuan-recipes.curated.json', import.meta.url),
  full: new URL('../data/sichuan-recipes.json', import.meta.url),
};

const buffers = Object.fromEntries(
  Object.entries(files).map(([key, file]) => [key, fs.readFileSync(file)]),
);
const json = Object.fromEntries(
  Object.entries(buffers).map(([key, buffer]) => [key, JSON.parse(buffer.toString('utf8'))]),
);
const sha256 = (buffer) => createHash('sha256').update(buffer).digest('hex');

const catalogByPage = new Map(json.catalog.entries.map((entry) => [entry.bookPage, entry]));
const matchByEntryId = new Map(json.matches.bookMatches.map((entry) => [entry.entryId, entry]));

test('catalog index is complete, visually reviewed intermediate data', () => {
  assert.equal(json.catalog.applicationReady, false);
  assert.equal(json.catalog.scope.catalogOnly, true);
  assert.equal(json.catalog.scope.recipeBodyExtracted, false);
  assert.equal(json.catalog.scope.productionRecipeGenerated, false);
  assert.equal(json.catalog.scope.productionSchemaExpanded, false);
  assert.equal(json.catalog.scope.cacheStampUpdated, false);
  assert.equal(json.catalog.scope.uiChanged, false);
  assert.equal(json.catalog.reviewProcess.primaryReview.ocrAuthority, false);
  assert.equal(json.catalog.reviewProcess.primaryReview.renderDpi, 800);

  assert.equal(json.catalog.entries.length, 147);
  assert.equal(new Set(json.catalog.entries.map((entry) => entry.entryId)).size, 147);
  assert.equal(new Set(json.catalog.entries.map((entry) => entry.bookName)).size, 147);
  assert.equal(new Set(json.catalog.entries.map((entry) => entry.bookPage)).size, 147);

  const expectedCategoryCounts = { 肉食类: 76, 禽蛋鱼类: 27, 蔬菜类: 44 };
  const actualCategoryCounts = Object.fromEntries(
    json.catalog.summary.categoryCounts.map(({ category, count }) => [category, count]),
  );
  assert.deepEqual(actualCategoryCounts, expectedCategoryCounts);

  let previousBookPage = 0;
  for (const entry of json.catalog.entries) {
    assert.ok(entry.bookPage > previousBookPage);
    previousBookPage = entry.bookPage;
    assert.equal(entry.pdfPage, entry.bookPage + 13);
    assert.ok(entry.catalogPdfPage >= 6 && entry.catalogPdfPage <= 12);
    assert.ok(['high', 'medium', 'low'].includes(entry.recognitionConfidence));
  }

  assert.deepEqual(
    json.catalog.entries
      .filter((entry) => entry.recognitionConfidence === 'medium')
      .map((entry) => entry.entryId),
    ['dz1979-p086', 'dz1979-p107', 'dz1979-p123'],
  );
  assert.equal(json.catalog.entries.some((entry) => entry.recognitionConfidence === 'low'), false);
});

test('primary visual corrections preserve catalog wording rather than project wording', () => {
  const expected = new Map([
    [79, '锅粑肉片'],
    [135, '盐水仔鸡'],
    [141, '热味姜汁鸡'],
    [145, '蘑芋烧鸭'],
    [153, '绍子蒸蛋'],
    [155, '芹黄炒什件'],
    [170, '葱酥鱼'],
    [188, '姜汁蕹菜'],
    [189, '醋渍胡豆'],
    [196, '醋熘白菜'],
    [201, '炝黄瓜'],
    [203, '炝绿豆芽'],
    [206, '烧拌莴笋'],
    [207, '炝莲花白'],
    [219, '过浆豆花'],
    [226, '蛋酥花仁'],
  ]);

  for (const [bookPage, bookName] of expected) {
    assert.equal(catalogByPage.get(bookPage)?.bookName, bookName);
  }

  const rejectedReadings = [
    '锅巴肉片',
    '盐水仔鸭',
    '热窝姜汁鸡',
    '魔芋烧鸭',
    '臊子蒸蛋',
    '葱酥鲫鱼',
    '腌豇胡豆',
    '烩黄瓜',
    '烧绿豆芽',
    '烩莲花白',
    '过米豆花',
    '蛋酥花生',
  ];
  const bookNames = new Set(json.catalog.entries.map((entry) => entry.bookName));
  for (const reading of rejectedReadings) {
    assert.equal(bookNames.has(reading), false, `rejected catalog reading leaked: ${reading}`);
  }
});

test('Curated and Full name matching partitions both sides without guessing', () => {
  assert.equal(json.matches.applicationReady, false);
  assert.equal(json.matches.scope.recipeBodyCompared, false);
  assert.equal(json.matches.scope.productionRecipeGenerated, false);
  assert.equal(json.matches.scope.productionSchemaExpanded, false);
  assert.equal(json.matches.scope.sourceDatasetsModified, false);

  assert.equal(json.matches.inputs.catalog.sha256, sha256(buffers.catalog));
  assert.equal(json.matches.inputs.full.sha256, sha256(buffers.full));
  // The curated file is allowed to drift from the name-matches baseline only
  // through the recorded production promotion batches. The recorded sha
  // describes the historical pre-promotion curated; today's curated must be
  // exactly the recorded baseline count plus the five promoted entries.
  const promotions = JSON.parse(
    fs.readFileSync(new URL('../data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json', import.meta.url), 'utf8'),
  );
  const promotedIds = new Set(
    (promotions.batches ?? []).flatMap((batch) => (
      (batch.entries ?? []).map((entry) => entry.productionId)
    )),
  );
  assert.equal(json.matches.inputs.curated.recipeCount, 126);
  assert.equal(json.curated.recipes.length, 126 + promotedIds.size);
  const curatedPromoted = json.curated.recipes
    .filter((recipe) => recipe.id.startsWith('dz1979-'))
    .map((recipe) => recipe.id)
    .sort();
  assert.deepEqual(curatedPromoted, [...promotedIds].sort());
  assert.equal(json.curated.recipes.filter((recipe) => promotedIds.has(recipe.id)).length, promotedIds.size);

  assert.equal(json.matches.bookMatches.length, 147);
  assert.equal(new Set(json.matches.bookMatches.map((entry) => entry.entryId)).size, 147);
  assert.equal(json.matches.projectOnlyEntries.length, 246);

  const counts = Object.fromEntries(
    json.matches.summary.bookClassificationCounts.map(({ id, count }) => [id, count]),
  );
  assert.deepEqual(counts, {
    exact_name: 74,
    clear_alias: 5,
    book_only: 63,
    suspected_match: 5,
  });

  const expectedClearAliases = {
    锅粑肉片: '锅巴肉片',
    蘑芋烧鸭: '魔芋烧鸭',
    干煸四季豆: '干煸豆角',
    炒土豆丝: '土豆丝',
    青椒拌皮蛋: '青椒皮蛋',
  };
  const expectedSuspectedMatches = {
    热味姜汁鸡: '热窝姜汁鸡',
    豆腐鱼: '豆腐鲫鱼',
    干煸鳝鱼丝: '干煸鳝鱼',
    麻辣豆腐: '麻婆豆腐',
    烧拌莴笋: '烧拌鲜笋',
  };

  for (const match of json.matches.bookMatches) {
    assert.equal(match.bookName, json.catalog.entries.find((entry) => entry.entryId === match.entryId)?.bookName);
    if (match.classification.id === 'exact_name') {
      assert.equal(match.projectName, match.bookName);
      assert.equal(match.classification.reviewRequired, false);
    } else if (match.classification.id === 'clear_alias') {
      assert.equal(match.projectName, expectedClearAliases[match.bookName]);
      assert.equal(match.classification.reviewRequired, false);
    } else if (match.classification.id === 'suspected_match') {
      assert.equal(match.projectName, expectedSuspectedMatches[match.bookName]);
      assert.equal(match.classification.reviewRequired, true);
    } else {
      assert.equal(match.classification.id, 'book_only');
      assert.equal(match.projectName, null);
      assert.deepEqual(match.projectPresence, []);
    }
    if (match.projectName) {
      assert.ok(match.projectPresence.length > 0);
    }
  }

  assert.deepEqual(
    Object.fromEntries(
      json.matches.reviewQueue.map((entry) => [entry.bookName, entry.projectName]),
    ),
    expectedSuspectedMatches,
  );

  const projectUnion = new Set(
    [...json.curated.recipes, ...json.full.recipes].map((recipe) => recipe.name),
  );
  const matchedProjectNames = new Set(
    json.matches.bookMatches.filter((entry) => entry.projectName).map((entry) => entry.projectName),
  );
  const projectOnlyNames = new Set(
    json.matches.projectOnlyEntries.map((entry) => entry.projectName),
  );
  const promotedProductionNames = new Set(
    (promotions.batches ?? []).flatMap((batch) => (
      (batch.entries ?? []).map((entry) => entry.name)
    )),
  );
  // The historical name-matches partition predates the promotion; promoted
  // production names are an explicit third partition accounted separately.
  assert.equal(projectUnion.size, 330 + promotedProductionNames.size);
  assert.equal(matchedProjectNames.size, 84);
  assert.equal(projectOnlyNames.size, 246);
  const accounted = new Set([
    ...matchedProjectNames,
    ...projectOnlyNames,
    ...promotedProductionNames,
  ]);
  assert.equal(accounted.size, projectUnion.size);
  for (const name of projectUnion) {
    assert.ok(accounted.has(name));
  }
});

test('batch plan covers the catalog once in 10–15 item catalog-order batches', () => {
  assert.equal(json.batchPlan.applicationReady, false);
  assert.ok([
    'planned-not-started',
    'in-progress',
    'completed-primary-reviewed',
  ].includes(json.batchPlan.status));
  assert.equal(
    json.batchPlan.constraints.recipeBodyExtractionStarted,
    json.batchPlan.summary.processedRecipeCount > 0,
  );
  assert.equal(json.batchPlan.constraints.productionRecipeGenerated, false);
  assert.equal(json.batchPlan.inputs.catalog.sha256, sha256(buffers.catalog));
  assert.equal(json.batchPlan.inputs.nameMatches.sha256, sha256(buffers.matches));
  assert.equal(json.batchPlan.batches.length, 11);
  assert.deepEqual(json.batchPlan.summary.batchSizes, [13, 13, 13, 13, 12, 12, 14, 13, 15, 15, 14]);

  const flattenedEntryIds = [];
  for (const batch of json.batchPlan.batches) {
    assert.equal(batch.applicationReady, false);
    assert.ok([
      'planned-not-started',
      'completed-primary-reviewed',
      'completed-external-reviewed',
    ].includes(batch.status));
    if (batch.status !== 'planned-not-started') {
      assert.equal(batch.processedEntryCount, batch.entryCount);
      assert.equal(batch.processing.workerVisualReview, true);
      assert.ok(
        batch.processing.primaryVisualReview === true
          || batch.processing.externalVisualReview?.completed === true,
      );
      assert.equal(batch.processing.ocrUsedAsAuthority, false);
    }
    assert.ok(batch.entryCount >= 10 && batch.entryCount <= 15);
    assert.equal(batch.entryCount, batch.entryIds.length);
    assert.equal(batch.entryCount, batch.bookNames.length);
    for (const entryId of batch.entryIds) {
      const entry = json.catalog.entries.find((candidate) => candidate.entryId === entryId);
      assert.ok(entry, `unknown batch entry: ${entryId}`);
      assert.equal(entry.category, batch.category);
      assert.equal(matchByEntryId.has(entryId), true);
    }
    flattenedEntryIds.push(...batch.entryIds);
  }

  assert.deepEqual(flattenedEntryIds, json.catalog.entries.map((entry) => entry.entryId));
  assert.equal(new Set(flattenedEntryIds).size, 147);
});
