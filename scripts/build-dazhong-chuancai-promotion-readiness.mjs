#!/usr/bin/env node
// Builds the 《大众川菜》1979 production promotion readiness manifest.
//
// READ-ONLY with respect to canonical source-restoration data, crosswalk,
// and all production recipe data. Produces one new artifact:
//   data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json
//
// No production patch is generated, no production data is modified, and
// applicationReady stays false.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(path.join(repoRoot, relativePath), 'utf8'),
);

const catalog = readJson('data/source-restoration/dazhong-chuancai-1979-catalog.v1.json');
const crosswalk = readJson('data/source-restoration/dazhong-chuancai-1979-crosswalk-dry-run.v1.json');
const recipes = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');
const promotions = readJson('data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json');

const recipeByEntryId = new Map(recipes.recipes.map((r) => [r.entryId, r]));
const promotedEntryIds = new Set(
  (promotions.batches ?? []).flatMap((batch) => (
    (batch.entries ?? []).map((entry) => entry.entryId)
  )),
);

// -- Production chain audit (read-only facts, current repo state) ----------

const productionChainAudit = {
  recipeEntitySchema: {
    files: [
      'data/sichuan-recipes.curated.json',
      'data/sichuan-recipes.json',
    ],
    fields: 'id, name, tags, method(仅curated库在recipe对象内；full库无method字段)',
  },
  ingredientStorage: {
    location: '同文件顶层 recipe_ingredients[id]',
    shape: '[{ "item": string, "qty": string|null, "unit": string|null }]',
    note: 'qty/unit 为字符串（如“一斤”或 null），不支持 source-restoration 的 normalized 数值量纲。',
  },
  methodStorage: [
    'curated库 recipe.method 字段（curate-recipes.js 物化）',
    'data/recipe-methods.js window.RECIPE_METHODS（按菜名，PWA 静态合并）',
    'data/recipe-completion-overlay.json recipes{id:{method}} 与 newRecipes（PWA applyCompletionOverlay）',
  ],
  overlayChain: 'data/recipe-completion-overlay.json：recipes{id:{method}}、recipe_ingredients、newRecipes[{id,name,tags,method}]、newRecipeIngredients',
  pwaConsumer: 'app.js loadBasePack -> src/recipe-library.js mergeRecipeSources/applyCompletionOverlay/mergeRecipeMethods -> 用户 overlay',
  iosConsumer: 'ios RecipeService.fetchRecipes 拉取 data/sichuan-recipes.{curated,full}.json，解码 recipes(id,name,method?,tags) + recipe_ingredients，不应用 completion overlay',
  idConventions: {
    full: 'ex--<8-hex>',
    curatedFamily: 'fam-<slug>',
    completionNew: 'comp-<8-hex>',
    static: 'static-<digits>',
    hoc: 'hoc-<digits>',
  },
  schemaExtensionNeeded: false,
  schemaGapSummary: [
    '基本菜谱 {id,name,tags,method} 与 recipe_ingredients 可直接容纳 new-recipe-candidate，无需扩展 production schema。',
    'source 的 characteristicsSummary、uncertainties、confirmedReadings、confidence、sourceQuality 无 production 字段。',
    'source 的 normalized 数值数量无法直接写入 production（qty/unit 仅字符串），需用 rawQuantityText 原始文本形式。',
    'provenance（entryId/bookPage/pdfPage/来源书页）无 production 字段，需独立 provenance 侧文件承载。',
  ],
  minimalPromotionBatchSuggestion: '建议每批 5-8 道 new-recipe-candidate，逐批人工复核后落地，先经 overlay 链再物化 curated JSON。',
};

// -- ID compatibility audit (read-only runtime code inspection) ------------

const idCompatibilityAudit = {
  proposedIdPattern: 'dz1979-p<bookPage>',
  collisionWithProductionIds: false,
  collisionCheckBasis: 'curated 126 + full 264 + completion overlay newRecipes，共 330 个现有 production ID，无 dz1979-/dz- 前缀。',
  pwaPrefixDependencies: {
    found: false,
    note: 'PWA 仅对 creative-（AI 菜）与 adhoc_（临时计划项）做前缀特判，与 production 库无关；ex-/comp-/fam-/static-/hoc- 前缀只生成不解析，recipe merge/detail/plan 链按普通字符串处理 ID。',
  },
  iosIdHandling: {
    plainString: true,
    note: 'RemoteRecipe.id 按 String 解码（Int 自动转 String），无前缀解析。',
  },
  conclusion: 'dz1979-pXXX 与现有 production ID 无冲突；PWA merge/detail/plan 链与 iOS 均按普通字符串处理 recipe ID，可安全采用，无需修改 runtime 代码。',
};

// -- Disposition rules -----------------------------------------------------
// Priority: alternate-source > source-review > crosswalk > existing/new.

const alt12Ids = new Set(
  crosswalk.alternateSourceRequiredList.map((entry) => entry.entryId),
);

// Promotion-stage tags stay source-safe: only 川菜 + the original book
// category. Semantic tags (素菜, main-ingredient, etc.) are deferred to a
// separate curation pass and are never inferred from ingredients here.
function proposedTagsFor(entryId, category) {
  return ['川菜', category];
}

function methodPreviewFor(entryId) {
  const recipe = recipeByEntryId.get(entryId);
  const steps = recipe?.methodSummary?.steps ?? [];
  return steps.map((step) => `${step.order}. ${step.summary}`).join('\n');
}

// -- Production ingredient plan -------------------------------------------
// exact quantities convert to production qty/unit strings; everything else
// stays display-only with inventoryComparable=false.

function ingredientToProductionPlan(ingredient) {
  const quantity = ingredient.normalizedQuantity ?? {};
  const rawItem = ingredient.rawItemText;
  const rawQuantity = ingredient.rawQuantityText ?? null;
  const base = {
    sourceRawItemText: rawItem,
    sourceRawQuantityText: rawQuantity,
  };

  if (ingredient.memberQuantityMode === 'unallocated-group-total') {
    return [{
      ...base,
      productionItem: rawItem,
      qty: null,
      unit: null,
      displayQuantity: rawQuantity,
      inventoryComparable: false,
      conversionReason: 'unallocated-group-total：组内数量未分配，不得擅自拆分，保留原文展示。',
    }];
  }

  if (ingredient.memberQuantityMode === 'same-for-each') {
    return (ingredient.members ?? []).map((member) => {
      const exact = quantity.kind === 'exact-mass' || quantity.kind === 'exact-count';
      return {
        sourceRawItemText: member.item,
        sourceRawQuantityText: rawQuantity,
        productionItem: member.item,
        qty: exact ? String(quantity.qty) : null,
        unit: exact ? (quantity.kind === 'exact-mass' ? 'g' : quantity.unit) : null,
        displayQuantity: exact ? null : rawQuantity,
        inventoryComparable: exact,
        conversionReason: `same-for-each：组“${rawItem}”每项 ${quantity.qty}${quantity.unit}，安全拆分继承。`,
      };
    });
  }

  if (quantity.kind === 'exact-mass') {
    return [{
      ...base,
      productionItem: rawItem,
      qty: String(quantity.qty),
      unit: 'g',
      displayQuantity: null,
      inventoryComparable: true,
      conversionReason: `exact-mass：${rawQuantity} 折算 ${quantity.qty}g。`,
    }];
  }

  if (quantity.kind === 'exact-count') {
    return [{
      ...base,
      productionItem: rawItem,
      qty: String(quantity.qty),
      unit: quantity.unit,
      displayQuantity: null,
      inventoryComparable: true,
      conversionReason: `exact-count：${rawQuantity} 折算 ${quantity.qty}${quantity.unit ?? ''}。`,
    }];
  }

  return [{
    ...base,
    productionItem: rawItem,
    qty: null,
    unit: null,
    displayQuantity: rawQuantity,
    inventoryComparable: false,
    conversionReason: `${quantity.kind}：不伪造精确数值，保留原文“${rawQuantity}”作为 displayQuantity。`,
  }];
}

function productionIngredientPlanFor(entryId) {
  const recipe = recipeByEntryId.get(entryId);
  const inventoryIngredients = (recipe?.ingredients ?? [])
    .flatMap((ingredient) => ingredientToProductionPlan(ingredient));

  const methodOnlyAnalysis = (recipe?.methodOnlyIngredients ?? []).map((moi) => {
    const text = moi.rawItemText;
    const isCookingMedium = /汤|开水|水$|水，/.test(text);
    if (isCookingMedium) {
      return {
        sourceRawItemText: text,
        sourceRawQuantityText: moi.rawQuantityText ?? null,
        classification: 'cooking-medium',
        includedInProduction: false,
        conversionWarning: null,
        reason: '汤/水为烹调介质，不入库存。',
      };
    }
    const isOptionalAlternative = /替代|如无|可加|可选|附注/.test(moi.use ?? '');
    if (isOptionalAlternative) {
      return {
        sourceRawItemText: text,
        sourceRawQuantityText: moi.rawQuantityText ?? null,
        classification: 'optional-alternative',
        includedInProduction: false,
        conversionWarning: null,
        reason: moi.use ?? '可选/替代项，非核心库存食材。',
      };
    }
    return {
      sourceRawItemText: text,
      sourceRawQuantityText: moi.rawQuantityText ?? null,
      classification: 'core-no-quantity',
      includedInProduction: false,
      conversionWarning: `做法中的核心食材但数量无法安全表示（rawQuantityText=${moi.rawQuantityText ?? 'null'}），需人工确认后决定是否入库存。`,
      reason: moi.use ?? '',
    };
  });

  const exactCount = inventoryIngredients.filter((ingredient) => ingredient.inventoryComparable).length;
  const displayOnlyCount = inventoryIngredients.filter((ingredient) => !ingredient.inventoryComparable).length;
  let quantityReadiness;
  if (exactCount > 0 && displayOnlyCount === 0) quantityReadiness = 'exact-comparable';
  else if (displayOnlyCount > 0 && exactCount === 0) quantityReadiness = 'display-only';
  else quantityReadiness = 'mixed';

  return { inventoryIngredients, methodOnlyAnalysis, quantityReadiness };
}

const entries = [];
for (const catalogEntry of catalog.entries) {
  const { entryId, bookName, category, bookPage } = catalogEntry;
  const walk = crosswalk.entries.find((entry) => entry.entryId === entryId);
  if (!walk) throw new Error(`missing crosswalk entry: ${entryId}`);

  const classification = walk.proposedClassification;
  const sourceQuality = walk.sourceQuality;

  let disposition;
  const blockingReasons = [];
  if (sourceQuality === 'alternate-source-required') {
    disposition = 'blocked-alternate-source';
    blockingReasons.push('sourceQuality=alternate-source-required：需替代来源补全正文后重新评估。');
  } else if (sourceQuality === 'needs-source-review') {
    disposition = 'blocked-source-review';
    blockingReasons.push('sourceQuality=needs-source-review：来源保真问题未解决。');
    blockingReasons.push(...walk.sourceQualityReasons.slice(0, 3));
  } else if (classification === 'probable-match-needs-review') {
    disposition = 'blocked-crosswalk';
    blockingReasons.push('classification=probable-match-needs-review：正文复核未确认，reviewRequired=true。');
  } else if (classification === 'exact-name' || classification === 'confirmed-alias') {
    disposition = 'existing-project-match';
    blockingReasons.push('已有真实 project ID，复用现有 production recipe，不创建重复菜谱。');
  } else {
    disposition = 'new-recipe-candidate';
  }

  const proposedProductionAction = {
    'existing-project-match': '复用现有 project recipe；未来 source-enrichment 候选单独记录，本轮不改现有 production recipe。',
    'new-recipe-candidate': '后续真正可新增到 production 的候选：按下方转换预览新建 recipe（本轮不生成 patch）。',
    'blocked-source-review': '待 source 保真问题解决后重新评估 promotion。',
    'blocked-alternate-source': '需替代来源补全正文后重新评估 promotion。',
    'blocked-crosswalk': '待正文 adjudication 确认（remain-probable 升级或 reject 回 book-only）后重新评估。',
  }[disposition];

  const item = {
    entryId,
    bookName,
    category,
    classification,
    sourceQuality,
    projectIds: walk.projectIds,
    promotionDisposition: disposition,
    promotionState: promotedEntryIds.has(entryId) ? 'promoted' : 'not-promoted',
    blockingReasons,
    proposedProductionAction,
  };

  if (disposition === 'new-recipe-candidate') {
    item.proposedName = bookName;
    item.proposedTags = proposedTagsFor(entryId, category);
    item.proposedIdStrategy = `dz1979-p${bookPage}`;
    item.ingredientTarget = 'data/sichuan-recipes.{curated,full}.json 的 recipe_ingredients[id]（或 completion overlay newRecipeIngredients）；精确数量转 qty/unit 数字字符串，非精确数量保留 displayQuantity 且 inventoryComparable=false（见 productionIngredientPlan）。';
    item.methodTarget = 'recipe method 文本：由 methodSummary.steps 拼接“order. summary”换行（见 methodPreview）；经 completion overlay recipes{id:{method}} 或 curated JSON recipe.method 落地。';
    item.provenanceStrategy = '新建 provenance 侧文件（productionId -> entryId/bookPage/pdfPage/characteristicsSummary/uncertainties/confidence），现有 production schema 无对应字段。';
    item.schemaGapNotes = [
      '基本 recipe + recipe_ingredients 无需 schema 扩展。',
      'characteristicsSummary 无 production 字段（可保留于 provenance 层）。',
      'uncertainties/confirmedReadings/confidence/sourceQuality 无 production 字段。',
      'normalized 数值数量转 qty/unit 数字字符串；range/approximate/qualitative/unresolved 不伪造精确值，仅保留 displayQuantity。',
      'methodOnlyIngredients 中核心食材若数量无法安全表示，需人工确认后再入库存（见 methodOnlyAnalysis）。',
    ];
    item.methodPreview = methodPreviewFor(entryId);
    item.productionIngredientPlan = productionIngredientPlanFor(entryId);
  }

  entries.push(item);
}

// -- Verification ----------------------------------------------------------

const problems = [];
const dispositionCounts = {};
const quantityReadinessCounts = { 'exact-comparable': 0, mixed: 0, 'display-only': 0 };
const mixedQuantityCandidates = [];
const conversionWarningCandidates = [];
for (const entry of entries) {
  dispositionCounts[entry.promotionDisposition] = (dispositionCounts[entry.promotionDisposition] ?? 0) + 1;
  if (entry.promotionDisposition === 'new-recipe-candidate') {
    const readiness = entry.productionIngredientPlan.quantityReadiness;
    quantityReadinessCounts[readiness] += 1;
    if (readiness === 'mixed') mixedQuantityCandidates.push(entry.entryId);
    const warnings = entry.productionIngredientPlan.methodOnlyAnalysis
      .filter((item) => item.conversionWarning);
    if (warnings.length > 0) conversionWarningCandidates.push(entry.entryId);
  }
}

const uniqueIds = new Set(entries.map((entry) => entry.entryId));
if (entries.length !== 147 || uniqueIds.size !== 147) {
  problems.push(`entry-count-mismatch:${entries.length}/${uniqueIds.size}`);
}
if (Object.values(dispositionCounts).reduce((sum, n) => sum + n, 0) !== 147) {
  problems.push('disposition-sum-not-147');
}

const confirmedIds = new Set(
  entries.filter((entry) => (
    entry.classification === 'exact-name' || entry.classification === 'confirmed-alias'
  )).map((entry) => entry.entryId),
);
const newCandidateIds = new Set(
  entries.filter((entry) => entry.promotionDisposition === 'new-recipe-candidate')
    .map((entry) => entry.entryId),
);
if (confirmedIds.size !== 81) problems.push(`confirmed-count-not-81:${confirmedIds.size}`);
const overlap = [...confirmedIds].filter((id) => newCandidateIds.has(id));
if (overlap.length > 0) problems.push(`confirmed-in-new-candidate:${overlap.join(',')}`);

const bookOnlyReadyIds = new Set(
  entries.filter((entry) => (
    entry.classification === 'book-only'
    && entry.sourceQuality === 'ready-for-later-promotion-review'
  )).map((entry) => entry.entryId),
);
if (bookOnlyReadyIds.size !== newCandidateIds.size
  || [...bookOnlyReadyIds].some((id) => !newCandidateIds.has(id))) {
  problems.push('new-recipe-candidate-not-equal-book-only-and-ready');
}

const p173 = entries.find((entry) => entry.entryId === 'dz1979-p173');
if (!p173 || p173.promotionDisposition !== 'blocked-crosswalk') {
  problems.push('p173-not-blocked-crosswalk');
}

const altBlocked = entries.filter((entry) => entry.sourceQuality === 'alternate-source-required');
if (altBlocked.length !== 12
  || altBlocked.some((entry) => entry.promotionDisposition !== 'blocked-alternate-source')) {
  problems.push('alternate-source-12-not-all-blocked');
}

const needsInNewCandidate = entries.filter((entry) => (
  entry.sourceQuality === 'needs-source-review'
  && entry.promotionDisposition === 'new-recipe-candidate'
));
if (needsInNewCandidate.length > 0) {
  problems.push(`needs-source-review-in-new-candidate:${needsInNewCandidate.map((e) => e.entryId).join(',')}`);
}

const promotedEntries = entries.filter((entry) => entry.promotionState === 'promoted');
const promotedNotCandidate = promotedEntries.filter((entry) => (
  entry.promotionDisposition !== 'new-recipe-candidate'
));
if (promotedNotCandidate.length > 0) {
  problems.push(`promoted-not-new-candidate:${promotedNotCandidate.map((e) => e.entryId).join(',')}`);
}
const promotedNewCount = promotedEntries.length;
const remainingNewCandidateCount = newCandidateIds.size - promotedNewCount;
if (promotedNewCount !== 5) problems.push(`promoted-new-count-not-5:${promotedNewCount}`);
if (remainingNewCandidateCount !== 34) {
  problems.push(`remaining-new-candidate-not-34:${remainingNewCandidateCount}`);
}

const dangling = entries.flatMap((entry) => (
  entry.projectIds
    .filter(({ id }) => !id)
    .map(() => entry.entryId)
));
if (dangling.length > 0) problems.push(`dangling-project-ids:${dangling.join(',')}`);

const output = {
  schema: 'kitchenmanager.source-restoration.promotion-readiness.v1',
  generatedAt: new Date().toISOString().slice(0, 10),
  purpose: '《大众川菜》1979 production promotion readiness：机械生成 147 道 promotionDisposition 清单与 new-recipe-candidate 转换预览。只制定可执行候选清单，不修改任何生产数据，不做 production promotion。',
  applicationReady: false,
  productionPromotion: false,
  promotionStateDefinitions: {
    promoted: '已由 source-restoration 主动 promotion 进入 production 的 recipe（见 production-promotions ledger）。',
    'not-promoted': '尚未 promotion 的 recipe。',
  },
  promotionLedgerSource: 'data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json',
  promotionStateNote: 'promotionDisposition 保持 promotion 前的来源/匹配分类（50/39/45/12/1），不因已 promotion 重分类；promotionState 为独立维度。future batch 选择必须排除 promotionState=promoted。',
  futureBatchSelectionRule: {
    excludePromotionState: 'promoted',
    collisionRule: '若 ID/name 碰撞来自 promotion ledger 中同一 entryId -> productionId -> name 且 production 内容一致，视为 expected promoted match；其他任何碰撞仍报错。',
  },
  dispositionDefinitions: {
    'existing-project-match': 'exact-name/confirmed-alias 且已有真实 project ID；复用现有 recipe，不创建重复。',
    'new-recipe-candidate': 'book-only 且 sourceQuality=ready；后续真正可能新增到 production 的集合。',
    'blocked-source-review': 'sourceQuality=needs-source-review 且非 alternate；来源保真问题未解决。',
    'blocked-alternate-source': 'sourceQuality=alternate-source-required；需替代来源。',
    'blocked-crosswalk': 'probable-match-needs-review；正文复核未确认，即使 ready 也不得 promotion。',
  },
  dispositionPriority: 'alternate-source > source-review > crosswalk > existing-match/new-candidate',
  productionChainAudit,
  idCompatibilityAudit,
  summary: {
    totalEntries: entries.length,
    dispositionCounts,
    confirmedProjectMappingTotal: confirmedIds.size,
    newRecipeCandidateCount: newCandidateIds.size,
    newRecipeCandidateIds: [...newCandidateIds].sort(),
    existingProjectMatchCount: dispositionCounts['existing-project-match'],
    blockedSourceReviewCount: dispositionCounts['blocked-source-review'],
    blockedAlternateSourceCount: dispositionCounts['blocked-alternate-source'],
    blockedCrosswalkCount: dispositionCounts['blocked-crosswalk'],
    quantityReadinessCounts,
    mixedQuantityCandidateIds: mixedQuantityCandidates.sort(),
    methodOnlyConversionWarningCandidateIds: conversionWarningCandidates.sort(),
    promotedNewRecipeCount: promotedNewCount,
    promotedNewRecipeIds: promotedEntries.map((entry) => entry.entryId).sort(),
    remainingNewRecipeCandidateCount: remainingNewCandidateCount,
    schemaExtensionNeeded: false,
    verificationProblems: problems,
  },
  entries,
};

const outPath = path.join(
  repoRoot,
  'data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json',
);
fs.writeFileSync(outPath, `${JSON.stringify(output, null, 2)}\n`);

console.log(`Wrote ${outPath}`);
console.log(`dispositionCounts: ${JSON.stringify(dispositionCounts)}`);
console.log(`verificationProblems: ${problems.length}`);
if (problems.length > 0) {
  console.log(problems);
  process.exitCode = 1;
}
