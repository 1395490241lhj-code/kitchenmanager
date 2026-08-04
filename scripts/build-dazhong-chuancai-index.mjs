import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, '..');

const paths = {
  catalog: path.join(repoRoot, 'data/source-restoration/dazhong-chuancai-1979-catalog.v1.json'),
  curated: path.join(repoRoot, 'data/sichuan-recipes.curated.json'),
  full: path.join(repoRoot, 'data/sichuan-recipes.json'),
  matches: path.join(repoRoot, 'data/source-restoration/dazhong-chuancai-1979-name-matches.v1.json'),
  batchPlan: path.join(repoRoot, 'data/source-restoration/dazhong-chuancai-1979-batch-plan.v1.json'),
};

const classificationDefinitions = [
  { id: 'exact_name', label: '精确同名', reviewRequired: false },
  { id: 'clear_alias', label: '明确异名', reviewRequired: false },
  { id: 'suspected_match', label: '疑似匹配待人工确认', reviewRequired: true },
  { id: 'book_only', label: '仅书中存在', reviewRequired: false },
  { id: 'project_only', label: '仅项目中存在', reviewRequired: false },
];

const clearAliases = new Map([
  ['锅粑肉片', {
    projectName: '锅巴肉片',
    basis: '目录“粑”与项目“巴”为该菜名的明确字形/写法差异，其余文字完全一致。',
  }],
  ['蘑芋烧鸭', {
    projectName: '魔芋烧鸭',
    basis: '“蘑芋/魔芋”指向同一食材，烹调法与主料完全一致。',
  }],
  ['干煸四季豆', {
    projectName: '干煸豆角',
    basis: '“四季豆/豆角”为明确同义食材称呼，烹调法一致。',
  }],
  ['炒土豆丝', {
    projectName: '土豆丝',
    basis: '项目名仅省略目录中的烹调动词“炒”，核心菜名唯一。',
  }],
  ['青椒拌皮蛋', {
    projectName: '青椒皮蛋',
    basis: '项目名仅省略目录中的“拌”，原料组合完整一致。',
  }],
]);

const suspectedMatches = new Map([
  ['热味姜汁鸡', {
    projectName: '热窝姜汁鸡',
    basis: '两个名称仅一字不同且项目候选唯一，但“味/窝”不是可直接等同的字形规范化。',
  }],
  ['豆腐鱼', {
    projectName: '豆腐鲫鱼',
    basis: '项目名增加了鱼种“鲫”，需要正文主料确认。',
  }],
  ['干煸鳝鱼丝', {
    projectName: '干煸鳝鱼',
    basis: '项目名省略形态词“丝”，需要正文刀工与成品确认。',
  }],
  ['麻辣豆腐', {
    projectName: '麻婆豆腐',
    basis: '菜式高度相关但名称语义并不等值，需要正文调味和做法确认。',
  }],
  ['烧拌莴笋', {
    projectName: '烧拌鲜笋',
    basis: '烹调法相同但“莴笋/鲜笋”可能指不同原料，需要正文确认。',
  }],
]);

const inputBuffers = Object.fromEntries(
  await Promise.all(
    Object.entries({ catalog: paths.catalog, curated: paths.curated, full: paths.full })
      .map(async ([key, inputPath]) => [key, await readFile(inputPath)]),
  ),
);

const parseJson = (buffer, label) => {
  try {
    return JSON.parse(buffer.toString('utf8'));
  } catch (error) {
    throw new Error(`Unable to parse ${label}: ${error.message}`);
  }
};

const sha256 = (buffer) => createHash('sha256').update(buffer).digest('hex');
const catalog = parseJson(inputBuffers.catalog, paths.catalog);
const curated = parseJson(inputBuffers.curated, paths.curated);
const full = parseJson(inputBuffers.full, paths.full);

if (catalog.applicationReady !== false || catalog.scope?.catalogOnly !== true) {
  throw new Error('Catalog must remain catalog-only intermediate data with applicationReady=false.');
}
if (!Array.isArray(catalog.entries) || catalog.entries.length === 0) {
  throw new Error('Catalog entries are missing.');
}

const libraries = [
  { id: 'curated', path: 'data/sichuan-recipes.curated.json', data: curated },
  { id: 'full', path: 'data/sichuan-recipes.json', data: full },
];

const projectByName = new Map();
for (const library of libraries) {
  for (const recipe of library.data.recipes ?? []) {
    if (!projectByName.has(recipe.name)) {
      projectByName.set(recipe.name, { projectName: recipe.name, presence: [], ids: {} });
    }
    const projectEntry = projectByName.get(recipe.name);
    projectEntry.presence.push(library.id);
    projectEntry.ids[library.id] = recipe.id;
  }
}

const getDefinition = (id) => classificationDefinitions.find((definition) => definition.id === id);
const consumedProjectNames = new Set();

const bookMatches = catalog.entries.map((entry) => {
  let classificationId;
  let projectName = null;
  let basis;

  if (projectByName.has(entry.bookName)) {
    classificationId = 'exact_name';
    projectName = entry.bookName;
    basis = '书名与项目菜名逐字相同。';
  } else if (clearAliases.has(entry.bookName)) {
    classificationId = 'clear_alias';
    ({ projectName, basis } = clearAliases.get(entry.bookName));
  } else if (suspectedMatches.has(entry.bookName)) {
    classificationId = 'suspected_match';
    ({ projectName, basis } = suspectedMatches.get(entry.bookName));
  } else {
    classificationId = 'book_only';
    basis = 'Curated/Full 名称并集中未找到可确认的同名或异名记录。';
  }

  const definition = getDefinition(classificationId);
  const projectEntry = projectName ? projectByName.get(projectName) : null;
  if (projectName && !projectEntry) {
    throw new Error(`Configured project match does not exist: ${entry.bookName} -> ${projectName}`);
  }
  if (projectName) {
    if (consumedProjectNames.has(projectName)) {
      throw new Error(`Project name is matched more than once: ${projectName}`);
    }
    consumedProjectNames.add(projectName);
  }

  return {
    entryId: entry.entryId,
    bookName: entry.bookName,
    category: entry.category,
    catalogPdfPage: entry.catalogPdfPage,
    bookPage: entry.bookPage,
    pdfPage: entry.pdfPage,
    recognitionConfidence: entry.recognitionConfidence,
    classification: {
      id: definition.id,
      label: definition.label,
      reviewRequired: definition.reviewRequired,
    },
    projectName,
    projectPresence: projectEntry?.presence ?? [],
    projectIds: projectEntry?.ids ?? {},
    basis,
  };
});

const projectOnlyEntries = [...projectByName.values()]
  .filter((entry) => !consumedProjectNames.has(entry.projectName))
  .sort((a, b) => a.projectName.localeCompare(b.projectName, 'zh-Hans-CN'))
  .map((entry) => ({
    projectName: entry.projectName,
    classification: {
      id: 'project_only',
      label: '仅项目中存在',
      reviewRequired: false,
    },
    projectPresence: entry.presence,
    projectIds: entry.ids,
  }));

const countBy = (items, selector) => Object.entries(
  items.reduce((counts, item) => {
    const key = selector(item);
    counts[key] = (counts[key] ?? 0) + 1;
    return counts;
  }, {}),
).map(([id, count]) => ({
  id,
  label: getDefinition(id)?.label ?? id,
  count,
}));

const inputMetadata = {
  catalog: {
    path: 'data/source-restoration/dazhong-chuancai-1979-catalog.v1.json',
    sha256: sha256(inputBuffers.catalog),
    entryCount: catalog.entries.length,
  },
  curated: {
    path: 'data/sichuan-recipes.curated.json',
    sha256: sha256(inputBuffers.curated),
    recipeCount: curated.recipes?.length ?? 0,
  },
  full: {
    path: 'data/sichuan-recipes.json',
    sha256: sha256(inputBuffers.full),
    recipeCount: full.recipes?.length ?? 0,
  },
};

const matches = {
  schema: 'kitchenmanager.source-restoration.name-matches.v1',
  createdAt: '2026-08-04',
  status: 'catalog-name-matching-reviewed-intermediate-only',
  applicationReady: false,
  purpose: 'Compare the catalog-only book index with the current Curated and Full recipe-name snapshots without changing either production dataset.',
  scope: {
    sourceCatalogOnly: true,
    recipeBodyCompared: false,
    productionRecipeGenerated: false,
    productionSchemaExpanded: false,
    sourceDatasetsModified: false,
  },
  inputs: inputMetadata,
  classificationDefinitions,
  summary: {
    bookEntryCount: bookMatches.length,
    projectUnionNameCount: projectByName.size,
    curatedNameCount: new Set((curated.recipes ?? []).map((recipe) => recipe.name)).size,
    fullNameCount: new Set((full.recipes ?? []).map((recipe) => recipe.name)).size,
    bookClassificationCounts: countBy(bookMatches, (entry) => entry.classification.id),
    projectOnlyCount: projectOnlyEntries.length,
  },
  reviewQueue: bookMatches
    .filter((entry) => entry.classification.reviewRequired)
    .map((entry) => ({
      entryId: entry.entryId,
      bookName: entry.bookName,
      projectName: entry.projectName,
      basis: entry.basis,
    })),
  bookMatches,
  projectOnlyEntries,
};

const matchesBuffer = Buffer.from(`${JSON.stringify(matches, null, 2)}\n`);
await writeFile(paths.matches, matchesBuffer);

const splitBalanced = (items, minimum, maximum) => {
  const batchCount = Math.ceil(items.length / maximum);
  const baseSize = Math.floor(items.length / batchCount);
  const remainder = items.length % batchCount;
  if (baseSize < minimum) {
    throw new Error(`Cannot split ${items.length} entries into ${minimum}-${maximum} item batches.`);
  }
  const result = [];
  let cursor = 0;
  for (let index = 0; index < batchCount; index += 1) {
    const size = baseSize + (index < remainder ? 1 : 0);
    result.push(items.slice(cursor, cursor + size));
    cursor += size;
  }
  return result;
};

const matchByEntryId = new Map(bookMatches.map((entry) => [entry.entryId, entry]));
const categoryOrder = ['肉食类', '禽蛋鱼类', '蔬菜类'];
const groupedBatches = categoryOrder.flatMap((category) => {
  const entries = catalog.entries.filter((entry) => entry.category === category);
  return splitBalanced(entries, 10, 15).map((batchEntries) => ({ category, batchEntries }));
});

const batches = groupedBatches.map(({ category, batchEntries }, index) => {
  const matchesForBatch = batchEntries.map((entry) => matchByEntryId.get(entry.entryId));
  const uncertainEntryIds = batchEntries
    .filter((entry) => entry.recognitionConfidence !== 'high')
    .map((entry) => entry.entryId);
  const suspectedMatchEntryIds = matchesForBatch
    .filter((entry) => entry.classification.id === 'suspected_match')
    .map((entry) => entry.entryId);
  return {
    batchId: `dz1979-b${String(index + 1).padStart(2, '0')}`,
    status: 'planned-not-started',
    applicationReady: false,
    category,
    entryCount: batchEntries.length,
    bookPageRange: {
      first: batchEntries[0].bookPage,
      last: batchEntries.at(-1).bookPage,
    },
    pdfPageRange: {
      first: batchEntries[0].pdfPage,
      last: batchEntries.at(-1).pdfPage,
    },
    entryIds: batchEntries.map((entry) => entry.entryId),
    bookNames: batchEntries.map((entry) => entry.bookName),
    recognitionConfidenceCounts: Object.fromEntries(
      countBy(batchEntries, (entry) => entry.recognitionConfidence).map(({ id, count }) => [id, count]),
    ),
    matchClassificationCounts: Object.fromEntries(
      countBy(matchesForBatch, (entry) => entry.classification.id).map(({ id, count }) => [id, count]),
    ),
    preExtractionReview: {
      required: uncertainEntryIds.length > 0 || suspectedMatchEntryIds.length > 0,
      uncertainEntryIds,
      suspectedMatchEntryIds,
    },
  };
});

const batchPlan = {
  schema: 'kitchenmanager.source-restoration.batch-plan.v1',
  createdAt: '2026-08-04',
  status: 'planned-not-started',
  applicationReady: false,
  purpose: 'Plan later recipe-body extraction in 10–15 dish batches after the catalog index; no recipe body is extracted in this artifact.',
  constraints: {
    minimumRecipesPerBatch: 10,
    maximumRecipesPerBatch: 15,
    preserveCatalogOrder: true,
    keepCategoryBoundaries: true,
    recipeBodyExtractionStarted: false,
    productionRecipeGenerated: false,
  },
  inputs: {
    catalog: inputMetadata.catalog,
    nameMatches: {
      path: 'data/source-restoration/dazhong-chuancai-1979-name-matches.v1.json',
      sha256: sha256(matchesBuffer),
    },
  },
  summary: {
    totalCatalogEntries: catalog.entries.length,
    totalBatches: batches.length,
    batchSizes: batches.map((batch) => batch.entryCount),
    categoryBatchCounts: categoryOrder.map((category) => ({
      category,
      count: batches.filter((batch) => batch.category === category).length,
    })),
  },
  batches,
};

await writeFile(paths.batchPlan, `${JSON.stringify(batchPlan, null, 2)}\n`);

process.stdout.write(
  `Wrote ${path.relative(repoRoot, paths.matches)} (${bookMatches.length} book matches, ${projectOnlyEntries.length} project-only)\n` +
  `Wrote ${path.relative(repoRoot, paths.batchPlan)} (${batches.length} batches)\n`,
);
