#!/usr/bin/env node
// Builds the 《大众川菜》1979 Production Batch 4 dry-run.
//
// Reuses the verified Batch 1 hard gates (frozen readiness audit) and the
// Batch 2 runtime gate: only core ingredients are checked against the
// real inventory/recipe canonicalization pipeline; any unresolved-name-match
// blocks the candidate, expected-unit-confirmation is recorded but allowed.
// No new alias or unit conversion is introduced.
//
// Mechanically selects the 5 safest remaining new-recipe-candidates,
// produces the overlay -> curate -> provenance promotion preview, and
// simulates the real promotion chain against a temp copy (real
// scripts/curate-recipes.js) so the artifact records the exact expected
// production delta. No production file in the workspace is written.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { classifyIngredientCompatibility } from '../../dazhong-runtime-compatibility.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..', '..', '..');

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(path.join(repoRoot, relativePath), 'utf8'),
);

const catalog = readJson('data/source-restoration/dazhong-chuancai-1979-catalog.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');
const recipes = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');
const overlay = readJson('data/recipe-completion-overlay.json');

const recipeByEntryId = new Map(recipes.recipes.map((r) => [r.entryId, r]));
const catalogByEntryId = new Map(catalog.entries.map((e) => [e.entryId, e]));
const readinessByEntryId = new Map(
  readiness.entries.map((e) => [e.entryId, e]),
);

const productionNames = new Set([
  ...curated.recipes.map((r) => r.name),
  ...full.recipes.map((r) => r.name),
]);
const productionIds = new Set([
  ...curated.recipes.map((r) => r.id),
  ...full.recipes.map((r) => r.id),
  ...(overlay.newRecipes ?? []).map((r) => r.id),
]);

const UNIT_WHITELIST = /^(g|ml|个|只|颗|枚|根|条|片|块|瓣|张|把|棵|头|支|份|盒|袋|包|瓶|罐|听)$/;

// -- Batch 1 hard gates (frozen, reused verbatim) ---------------------------

function passesHardGates(entryId) {
  const entry = readinessByEntryId.get(entryId);
  const recipe = recipeByEntryId.get(entryId);
  if (!entry || entry.promotionDisposition !== 'new-recipe-candidate') return false;
  if (entry.sourceQuality !== 'ready-for-later-promotion-review') return false;

  const plan = entry.productionIngredientPlan;
  if (plan.quantityReadiness !== 'exact-comparable') return false;
  if (plan.inventoryIngredients.some((ing) => !ing.inventoryComparable)) return false;
  if (plan.methodOnlyAnalysis.some((item) => item.conversionWarning)) return false;

  if (recipe.contentMissing === true || recipe.contentIncomplete === true) return false;
  if (recipe.uncertainties?.length > 0) return false;

  const confidence = recipe.confidence ?? {};
  if (confidence.recognition !== 'high' || confidence.conversion !== 'high') return false;
  if (recipe.methodSummary?.confidence !== 'high') return false;
  if (recipe.titleVisualCheck?.confidence !== 'high') return false;
  if (recipe.ingredients?.some((ing) => (
    ing.confidence?.recognition !== 'high' || ing.confidence?.conversion !== 'high'
  ))) return false;

  for (const ing of recipe.ingredients ?? []) {
    const quantity = ing.normalizedQuantity ?? {};
    const kind = quantity.kind;
    if (!['exact-mass', 'exact-count'].includes(kind)) return false;
    if (ing.memberQuantityMode) return false;
    if ('consumedQty' in quantity || 'consumedReferenceQty' in quantity) return false;
    if ('consumedQualifier' in quantity || 'consumedUnit' in quantity) return false;
  }

  if (productionNames.has(entry.bookName)) return false;
  return true;
}

// -- Batch 4 runtime gate (core ingredients only, reused Batch 2 logic) ------

function auditRuntimeCompatibility(entryId) {
  const entry = readinessByEntryId.get(entryId);
  const coreResults = [];
  const nonCoreObservations = [];
  for (const ing of entry.productionIngredientPlan.inventoryIngredients) {
    const result = classifyIngredientCompatibility(ing.productionItem, ing.qty, ing.unit);
    const record = {
      entryId,
      item: ing.productionItem,
      qty: ing.qty,
      unit: ing.unit,
      role: result.role,
      canonical: result.canonical,
      ingredientFamilyKey: result.familyKey,
      guessKitchenUnit: result.guessKitchenUnit,
      normalizedQuantity: result.normalizedQuantity,
    };
    if (result.role === 'core') {
      coreResults.push({
        ...record,
        compatibility: result.compatibility,
        reasons: result.reasons,
        identityMatch: result.identityMatch,
        probes: result.probes,
      });
    } else {
      nonCoreObservations.push({ ...record, observation: result.observation });
    }
  }
  const unresolved = coreResults.filter((r) => r.compatibility === 'unresolved-name-match');
  const unitConfirmation = coreResults.filter((r) => r.compatibility === 'expected-unit-confirmation');
  return {
    entryId,
    coreResults,
    nonCoreObservations,
    unresolvedItems: unresolved.map((r) => r.item),
    unitConfirmationItems: unitConfirmation.map((r) => `${r.item}(${r.unit})`),
    blocked: unresolved.length > 0,
  };
}

// -- Candidate funnel --------------------------------------------------------

const remainingCandidates = readiness.entries.filter((e) => (
  e.promotionDisposition === 'new-recipe-candidate' && e.promotionState === 'not-promoted'
));

const gateExclusions = {
  hardGate: {},
  runtimeNameGate: [],
};
const noteExclusion = (entryId, reason) => {
  (gateExclusions.hardGate[reason] ??= []).push(entryId);
};

const hardGateSurvivors = [];
for (const entry of remainingCandidates) {
  const id = entry.entryId;
  if (!passesHardGates(id)) {
    const recipe = recipeByEntryId.get(id);
    const plan = entry.productionIngredientPlan;
    if (plan.methodOnlyAnalysis.some((item) => item.conversionWarning)) noteExclusion(id, 'methodOnlyConversionWarning');
    if (plan.quantityReadiness !== 'exact-comparable' || plan.inventoryIngredients.some((ing) => !ing.inventoryComparable)) noteExclusion(id, 'nonExactQuantity');
    if (recipe.ingredients?.some((ing) => ('consumedQty' in (ing.normalizedQuantity ?? {})) || ('consumedReferenceQty' in (ing.normalizedQuantity ?? {})))) noteExclusion(id, 'consumedDualQuantity');
    if (recipe.ingredients?.some((ing) => ing.memberQuantityMode === 'same-for-each')) noteExclusion(id, 'sameForEachCombinedQuantity');
    if (recipe.ingredients?.some((ing) => ing.memberQuantityMode === 'unallocated-group-total')) noteExclusion(id, 'unallocatedGroupTotal');
    continue;
  }
  hardGateSurvivors.push(id);
}

const runtimeAudits = new Map(
  hardGateSurvivors.map((id) => [id, auditRuntimeCompatibility(id)]),
);
for (const [id, audit] of runtimeAudits) {
  if (audit.blocked) gateExclusions.runtimeNameGate.push(id);
}

const eligible = hardGateSurvivors.filter((id) => !runtimeAudits.get(id).blocked);

// -- Mechanical ranking ------------------------------------------------------

function rankKey(entryId) {
  const audit = runtimeAudits.get(entryId);
  const recipe = recipeByEntryId.get(entryId);
  const specialStructures = recipe.ingredients
    .filter((ing) => ing.memberQuantityMode).length;
  return [
    audit.unitConfirmationItems.length,
    specialStructures,
    recipe.ingredients.length,
    recipe.methodSummary?.steps?.length ?? 0,
    entryId,
  ];
}

const ranked = [...eligible].sort((a, b) => {
  const ka = rankKey(a);
  const kb = rankKey(b);
  for (let i = 0; i < ka.length; i += 1) {
    if (ka[i] < kb[i]) return -1;
    if (ka[i] > kb[i]) return 1;
  }
  return 0;
});

const selected = ranked.slice(0, 5);

// -- Dry-run items -----------------------------------------------------------

function productionMethod(entryId) {
  const recipe = recipeByEntryId.get(entryId);
  return (recipe.methodSummary?.steps ?? [])
    .map((step) => `${step.order}. ${step.summary}`)
    .join('\n');
}

function productionIngredients(entryId) {
  const entry = readinessByEntryId.get(entryId);
  return entry.productionIngredientPlan.inventoryIngredients.map((ing) => ({
    item: ing.productionItem,
    qty: ing.qty,
    unit: ing.unit,
  }));
}

const items = selected.map((entryId) => {
  const entry = readinessByEntryId.get(entryId);
  const recipe = recipeByEntryId.get(entryId);
  const catalogEntry = catalogByEntryId.get(entryId);
  const audit = runtimeAudits.get(entryId);
  const productionId = `dz1979-p${catalogEntry.bookPage}`;
  const tags = ['川菜', catalogEntry.category];
  const method = productionMethod(entryId);
  const ingredients = productionIngredients(entryId);

  const transformNotes = [
    `method 仅由 canonical methodSummary.steps 拼接（${recipe.methodSummary.steps.length} 步），未补写书中没有的信息。`,
    'ingredients 直接复用 readiness 已审核 productionIngredientPlan，qty/unit 未重新推算。',
  ];
  for (const moi of recipe.methodOnlyIngredients ?? []) {
    const analysis = entry.productionIngredientPlan.methodOnlyAnalysis
      .find((item) => item.sourceRawItemText === moi.rawItemText);
    transformNotes.push(
      `methodOnly「${moi.rawItemText}」→ ${analysis?.classification ?? 'n/a'}${analysis?.conversionWarning ? `（warning: ${analysis.conversionWarning}）` : ''}`,
    );
  }

  const specialStructures = recipe.ingredients.filter((ing) => ing.memberQuantityMode).length;

  // Per-item quantity review preview: every qty/unit ingredient traced back
  // to the audited productionIngredientPlan / canonical raw quantity, never
  // recomputed here.
  const canonicalIngredientByItem = new Map(
    (recipe.ingredients ?? []).map((ingredient) => [
      ingredient.rawItemText,
      ingredient,
    ]),
  );
  const itemQuantityReviewPreview = ingredients
    .filter((ing) => ing.qty !== null && ing.unit !== null)
    .map((ing) => {
      const canonicalIngredient = canonicalIngredientByItem.get(ing.item);
      if (!canonicalIngredient) {
        throw new Error(`no canonical ingredient for ${entryId}:${ing.item}`);
      }
      const normalizedQuantity = canonicalIngredient.normalizedQuantity ?? {};
      return {
        item: ing.item,
        qty: ing.qty,
        unit: ing.unit,
        evidenceType: 'source-restoration',
        sourceRawQuantityText: canonicalIngredient.rawQuantityText,
        normalizedQuantity: {
          kind: normalizedQuantity.kind,
          qty: normalizedQuantity.qty,
          unit: normalizedQuantity.unit,
        },
        reviewStatus: 'approved',
      };
    });

  return {
    entryId,
    productionId,
    name: entry.bookName,
    category: catalogEntry.category,
    tags,
    selectionMetrics: {
      expectedUnitConfirmationCount: audit.unitConfirmationItems.length,
      specialStructureCount: specialStructures,
      ingredientCount: recipe.ingredients.length,
      methodStepCount: recipe.methodSummary?.steps?.length ?? 0,
      entryId,
      rankPosition: selected.indexOf(entryId) + 1,
    },
    proposedOverlayRecipe: { id: productionId, name: entry.bookName, tags, method },
    proposedOverlayIngredients: { [productionId]: ingredients },
    proposedCuratedRecipe: { id: productionId, name: entry.bookName, tags, method },
    proposedCuratedIngredients: { [productionId]: ingredients },
    provenanceRecord: {
      entryId,
      bookName: entry.bookName,
      bookPage: catalogEntry.bookPage,
      pdfPage: catalogEntry.pdfPage,
      category: catalogEntry.category,
      sourceQuality: entry.sourceQuality,
      classification: entry.classification,
      characteristicsSummary: recipe.characteristicsSummary,
      uncertainties: recipe.uncertainties,
      confirmedReadings: recipe.confirmedReadings,
      sourceFile: 'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
    },
    sourceToProductionTransformNotes: transformNotes,
    quantityReviewPreview: {
      recordCount: itemQuantityReviewPreview.length,
      records: itemQuantityReviewPreview,
    },
    coreRuntimeCompatibility: {
      coreIngredientResults: audit.coreResults.map((r) => ({
        item: r.item,
        qty: r.qty,
        unit: r.unit,
        role: r.role,
        canonical: r.canonical,
        ingredientFamilyKey: r.ingredientFamilyKey,
        guessKitchenUnit: r.guessKitchenUnit,
        compatibility: r.compatibility,
        reasons: r.reasons,
        normalizedQuantity: r.normalizedQuantity,
      })),
      nonCoreObservations: audit.nonCoreObservations,
      counts: {
        core: audit.coreResults.length,
        'exact-compatible': audit.coreResults.filter((r) => r.compatibility === 'exact-compatible').length,
        'expected-unit-confirmation': audit.coreResults.filter((r) => r.compatibility === 'expected-unit-confirmation').length,
        'unresolved-name-match': audit.coreResults.filter((r) => r.compatibility === 'unresolved-name-match').length,
      },
      unitConfirmationDetails: audit.coreResults
        .filter((r) => r.compatibility === 'expected-unit-confirmation')
        .map((r) => ({
          item: r.item,
          qty: r.qty,
          unit: r.unit,
          guessKitchenUnit: r.guessKitchenUnit,
          reasons: r.reasons,
        })),
      gatePassed: !audit.blocked,
    },
  };
});

// -- Quantity review preview --------------------------------------------------

const quantityReviewRecords = [];
for (const item of items) {
  const sourceRecipe = recipeByEntryId.get(item.entryId);
  const planIngredients = item.proposedOverlayIngredients[item.productionId];
  const canonicalIngredientByItem = new Map(
    (sourceRecipe.ingredients ?? []).map((ingredient) => [
      ingredient.rawItemText,
      ingredient,
    ]),
  );
  for (const productionIngredient of planIngredients) {
    if (productionIngredient.qty === null || productionIngredient.unit === null) continue;
    const canonicalIngredient = canonicalIngredientByItem.get(productionIngredient.item);
    if (!canonicalIngredient) {
      throw new Error(`no canonical ingredient for ${item.entryId}:${productionIngredient.item}`);
    }
    const normalizedQuantity = canonicalIngredient.normalizedQuantity ?? {};
    quantityReviewRecords.push({
      entryId: item.entryId,
      productionId: item.productionId,
      recipeName: item.name,
      item: productionIngredient.item,
      qty: productionIngredient.qty,
      unit: productionIngredient.unit,
      evidenceType: 'source-restoration',
      canonicalSourceFile: 'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
      sourceRawQuantityText: canonicalIngredient.rawQuantityText,
      normalizedQuantity: {
        kind: normalizedQuantity.kind,
        qty: normalizedQuantity.qty,
        unit: normalizedQuantity.unit,
      },
      dryRunArtifact: 'data/source-restoration/dazhong-chuancai-1979-promotion-batch4-dry-run.v1.json',
      reviewStatus: 'approved',
    });
  }
}

// -- Temp-directory real promotion chain simulation ---------------------------

function simulatePromotionChain() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dz1979-batch4-'));
  try {
    fs.mkdirSync(path.join(tmp, 'scripts'));
    fs.mkdirSync(path.join(tmp, 'data'));
    fs.copyFileSync(
      path.join(repoRoot, 'scripts', 'curate-recipes.js'),
      path.join(tmp, 'scripts', 'curate-recipes.js'),
    );
    fs.copyFileSync(
      path.join(repoRoot, 'data', 'sichuan-recipes.json'),
      path.join(tmp, 'data', 'sichuan-recipes.json'),
    );
    fs.copyFileSync(
      path.join(repoRoot, 'data', 'recipe-completion-overlay.json'),
      path.join(tmp, 'data', 'recipe-completion-overlay.json'),
    );
    const tmpOverlayPath = path.join(tmp, 'data', 'recipe-completion-overlay.json');
    const tmpOverlay = JSON.parse(fs.readFileSync(tmpOverlayPath, 'utf8'));
    tmpOverlay.newRecipes = [
      ...(tmpOverlay.newRecipes ?? []),
      ...items.map((item) => item.proposedOverlayRecipe),
    ];
    tmpOverlay.newRecipeIngredients = {
      ...(tmpOverlay.newRecipeIngredients ?? {}),
      ...Object.fromEntries(items.map((item) => [
        item.productionId,
        item.proposedOverlayIngredients[item.productionId],
      ])),
    };
    fs.writeFileSync(tmpOverlayPath, `${JSON.stringify(tmpOverlay, null, 2)}\n`);

    execFileSync('node', [path.join(tmp, 'scripts', 'curate-recipes.js')], {
      cwd: tmp,
      stdio: 'pipe',
    });
    const tmpCurated = JSON.parse(
      fs.readFileSync(path.join(tmp, 'data', 'sichuan-recipes.curated.json'), 'utf8'),
    );
    const tmpRemoved = JSON.parse(
      fs.readFileSync(path.join(tmp, 'data', 'recipe-curation-removed.json'), 'utf8'),
    );
    const tmpNeeding = JSON.parse(
      fs.readFileSync(path.join(tmp, 'data', 'recipes-needing-completion.json'), 'utf8'),
    );
    const tmpSummary = fs.readFileSync(
      path.join(tmp, 'data', 'recipe-curation-summary.md'),
      'utf8',
    );
    return { tmpCurated, tmpRemoved, tmpNeeding, tmpSummary };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

const headCuratedById = new Map(curated.recipes.map((r) => [r.id, r]));
const { tmpCurated, tmpRemoved, tmpNeeding, tmpSummary } = simulatePromotionChain();

const tmpCuratedById = new Map(tmpCurated.recipes.map((r) => [r.id, r]));
const existingIds = [...headCuratedById.keys()];
const newIds = [...tmpCuratedById.keys()].filter((id) => !headCuratedById.has(id)).sort();
const existingDeleted = existingIds.filter((id) => !tmpCuratedById.has(id));
const existingModified = existingIds.filter((id) => (
  JSON.stringify(headCuratedById.get(id)) !== JSON.stringify(tmpCuratedById.get(id))
));
const existingIngredientModified = existingIds.filter((id) => (
  JSON.stringify(curated.recipe_ingredients[id])
  !== JSON.stringify(tmpCurated.recipe_ingredients[id])
));
const removedDiffers = JSON.stringify(tmpRemoved)
  !== JSON.stringify(readJson('data/recipe-curation-removed.json'));
const needingDiffers = JSON.stringify(tmpNeeding)
  !== JSON.stringify(readJson('data/recipes-needing-completion.json'));
const summaryDiffers = tmpSummary
  !== fs.readFileSync(path.join(repoRoot, 'data', 'recipe-curation-summary.md'), 'utf8');

const simulation = {
  tempCurateResult: {
    headCuratedCount: curated.recipes.length,
    simulatedCuratedCount: tmpCurated.recipes.length,
    newRecipeIds: newIds,
    newRecipeCount: newIds.length,
    existingDeleted: existingDeleted.length,
    existingRecipeObjectModified: existingModified.length,
    existingIngredientMapModified: existingIngredientModified.length,
    newRecipesHaveMethod: newIds.every((id) => !!tmpCuratedById.get(id).method),
    newRecipesHaveTags: newIds.every((id) => !!tmpCuratedById.get(id).tags),
    newIngredientMapsComplete: newIds.every((id) => (
      Array.isArray(tmpCurated.recipe_ingredients[id])
      && tmpCurated.recipe_ingredients[id].length >= 2
    )),
    strictCurrentPlusFive: (
      tmpCurated.recipes.length === curated.recipes.length + 5
      && newIds.length === 5
      && existingDeleted.length === 0
      && existingModified.length === 0
      && existingIngredientModified.length === 0
    ),
  },
  auxiliaryGeneratedFiles: {
    recipeCurationRemoved: {
      changes: removedDiffers ? 'UNEXPECTED semantic change' : 'unchanged',
      note: 'Batch 4 的 5 道均有 method，curate 直接保留，不进入 removed；既有 removed 决定不变。',
    },
    recipesNeedingCompletion: {
      changes: needingDiffers ? 'UNEXPECTED semantic change' : 'unchanged',
      note: 'Batch 4 不改变任何既有 needing 决定。',
    },
    recipeCurationSummaryMd: {
      changes: summaryDiffers ? 'expected count changes from the 5 additions' : 'unchanged',
      expectedLineChanges: [
        '原始菜谱（有效集）: 337 -> 342',
        'overlay 新增/补全净增: 73 -> 78',
        'curated 保留: 141 -> 146',
        '从有效集保留（有做法）: 120 -> 125',
        '从 overlay 补全 method: 120 -> 125',
        '从 overlay 补全 ingredients: 83 -> 88',
      ],
    },
  },
};

// -- PWA cache / version visibility analysis (read-only) ----------------------

const pwaVisibilityAudit = {
  overlayFetch: {
    url: './data/recipe-completion-overlay.json',
    cacheMode: "fetch(..., { cache: 'no-store' })",
    note: 'src/recipe-completion.js 每次页面加载直接取最新 overlay。',
  },
  basePackFetch: {
    url: 'data/sichuan-recipes.{curated,full}.json?v=<releaseVersion>',
    cacheMode: "fetch(..., { cache: 'no-store' })",
    note: 'app.js loadBasePack 按当前 ?v= 版本取基包，无 HTTP 缓存。',
  },
  serviceWorker: {
    strategy: 'data/*.json 命中 sw.v18.js isDataJson -> networkFirst（在线总是取最新，离线回退缓存）',
    cacheBumpRequired: false,
    note: '数据内容变更不要求同步更新 cache-bust/version/service-worker 版本；只有 JS/CSS/SW 资产改动才需要发布版本更新。',
  },
  conclusion: '真实 promotion 后，在线用户经 networkFirst 立即获得新 overlay 与 curated JSON，无需同步更新 cache-bust/version/SW 相关版本。',
};

// -- iOS decode compatibility (static field-shape check) -----------------------

const iosDecodeAudit = {
  recipeShape: 'recipes[]: { id: string, name: string, method?: string, tags?: string[] }',
  ingredientShape: 'recipe_ingredients[id]: [{ item: string, qty?: string, unit?: string }]',
  batch4Compatible: items.every((item) => (
    typeof item.proposedCuratedRecipe.id === 'string'
    && typeof item.proposedCuratedRecipe.name === 'string'
    && typeof item.proposedCuratedRecipe.method === 'string'
    && Array.isArray(item.proposedCuratedRecipe.tags)
    && item.proposedCuratedIngredients[item.productionId].every((ing) => (
      typeof ing.item === 'string'
      && (ing.qty === null || typeof ing.qty === 'string')
      && (ing.unit === null || typeof ing.unit === 'string')
    ))
  )),
  note: 'RecipeService.RemoteRecipe/RemoteIngredient 可直接解码上述结构。',
};

// -- Output ---------------------------------------------------------------------

const problems = [];
if (selected.length !== 5) problems.push(`batch-size-not-5:${selected.length}`);
const selectedNames = items.map((item) => item.name);
if (new Set(selectedNames).size !== 5) problems.push('duplicate-selected-names');
if (items.some((item) => productionIds.has(item.productionId))) {
  problems.push('production-id-conflict');
}
if (items.some((item) => productionNames.has(item.name))) {
  problems.push('production-name-conflict');
}
if (!simulation.tempCurateResult.strictCurrentPlusFive) {
  problems.push('temp-curate-not-strict-current-plus-five');
}
if (existingDeleted.length > 0 || existingModified.length > 0 || existingIngredientModified.length > 0) {
  problems.push('existing-production-drift');
}
if (removedDiffers || needingDiffers) {
  problems.push('auxiliary-semantic-change');
}
if (items.some((item) => !item.coreRuntimeCompatibility.gatePassed)) {
  problems.push('selected-item-failed-runtime-gate');
}
if (items.some((item) => item.coreRuntimeCompatibility.counts['unresolved-name-match'] > 0)) {
  problems.push('selected-item-has-unresolved-name-match');
}
if (items.some((item) => item.coreRuntimeCompatibility.coreIngredientResults
  .some((r) => r.normalizedQuantity.finite === false))) {
  problems.push('non-finite-normalized-quantity');
}
for (const record of quantityReviewRecords) {
  if (!UNIT_WHITELIST.test(record.unit)) problems.push(`unit-not-whitelisted:${record.productionId}:${record.item}:${record.unit}`);
  if (!['exact-mass', 'exact-count'].includes(record.normalizedQuantity.kind)) problems.push(`non-exact-kind:${record.productionId}:${record.item}`);
}

const output = {
  schema: 'kitchenmanager.source-restoration.promotion-batch4-dry-run.v1',
  generatedAt: new Date().toISOString().slice(0, 10),
  baseline: {
    main: 'fc73285763feb5039658f88dad48d31a6d80ba38',
    applicationReady: false,
    batch1Promoted: true,
    batch2Promoted: true,
    batch3Promoted: true,
    batch1Ledger: 'data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json',
  },
  purpose: '《大众川菜》1979 Production Batch 4 dry-run：复用 Batch 1 已验证硬性 gate 与 Batch 2 已验证 runtime gate（仅 core ingredients，unresolved-name-match 阻塞、expected-unit-confirmation 记录不阻塞，禁止新增 alias/单位换算），机械选出 5 道剩余 new-recipe-candidate，给出 overlay -> curate -> provenance 的可复现 promotion 链预览，并在临时目录用真实 curate-recipes.js 模拟完整链路。不写任何 workspace production 文件，不做真实 promotion。',
  selection: {
    hardGateCriteria: [
      'promotionState=not-promoted',
      'promotionDisposition=new-recipe-candidate',
      'sourceQuality=ready-for-later-promotion-review',
      'productionQuantityReadiness=exact-comparable',
      '所有 production ingredients inventoryComparable=true',
      '无 methodOnly conversionWarning',
      '无 unallocated-group-total / same-for-each 组合数量',
      '无 range/approximate/qualitative/unresolved（非精确数量）',
      '无 consumedQty/consumedReferenceQty/consumedQualifier/consumedUnit',
      'canonical uncertainties=[]、contentMissing/contentIncomplete=false',
      'recognition/conversion/methodSummary/titleVisualCheck/ingredient confidence 均 high',
      'production ID/name 无冲突',
    ],
    runtimeGateRules: [
      '只检查 candidate 的 core ingredients（classifyRecipeIngredient role=core）。',
      '任何 core unresolved-name-match => 阻塞。',
      'core expected-unit-confirmation => 允许，但逐项记录。',
      'non-core（seasoning/non-stock）不参与 name gate。',
      '禁止新增 alias 或 unit 换算：只使用现有 src/ingredients.js / src/inventory.js canonicalization。',
    ],
    order: 'expected-unit-confirmation 数量少 -> ingredient 特殊结构少 -> ingredient 数量少 -> method 步骤少 -> entryId 升序',
    funnel: {
      remainingNotPromotedCandidates: remainingCandidates.length,
      afterHardGates: hardGateSurvivors.length,
      blockedByRuntimeNameGate: gateExclusions.runtimeNameGate.length,
      eligible: eligible.length,
      selected: selected.length,
    },
    hardGateExclusions: gateExclusions.hardGate,
    runtimeNameGateBlocked: gateExclusions.runtimeNameGate.map((id) => ({
      entryId: id,
      bookName: readinessByEntryId.get(id).bookName,
      unresolvedItems: runtimeAudits.get(id).unresolvedItems,
    })),
    eligiblePoolCount: eligible.length,
    rankedEntryIds: ranked,
    selectedEntryIds: selected,
    note: '机械筛选，未硬编码结果；Batch 1/2 已 promotion 的 10 道不在候选池（promotionState=promoted）。',
  },
  items,
  quantityReviewPreview: {
    purpose: 'Batch 4 promotion 将引入的 curated qty/unit 的 source-restoration-reviewed 登记预览（与 Batch 1/2/3 quantity-review 同构）。真实 promotion 时另行生成正式 quantity-review artifact；本预览仅为 dry-run 证据。',
    recordCount: quantityReviewRecords.length,
    records: quantityReviewRecords,
  },
  promotionChain: [
    '1. recipe-completion-overlay.json：newRecipes + newRecipeIngredients 追加 5 道（recipeIngredientOverrides 保持不变）',
    '2. 重跑 scripts/curate-recipes.js：物化到 data/sichuan-recipes.curated.json',
    '3. provenance 独立侧文件承载书页/置信/特点等 source 信息',
    '4. 不修改 data/sichuan-recipes.json（Full 库）',
  ],
  simulation,
  pwaVisibilityAudit,
  iosDecodeAudit,
  verificationProblems: problems,
};

const outPath = path.join(
  repoRoot,
  'data/source-restoration/dazhong-chuancai-1979-promotion-batch4-dry-run.v1.json',
);
fs.writeFileSync(outPath, `${JSON.stringify(output, null, 2)}\n`);

console.log(`Wrote ${outPath}`);
console.log(`funnel: ${remainingCandidates.length} -> hard ${hardGateSurvivors.length} -> runtime-blocked ${gateExclusions.runtimeNameGate.length} -> eligible ${eligible.length} -> selected ${selected.length}`);
console.log(`selected: ${selected.join(', ')}`);
console.log(`runtime-blocked: ${gateExclusions.runtimeNameGate.join(', ')}`);
console.log(`simulation.strictCurrentPlusFive: ${simulation.tempCurateResult.strictCurrentPlusFive}`);
console.log(`verificationProblems: ${problems.length}`);
if (problems.length > 0) {
  console.log(problems);
  process.exitCode = 1;
}
