#!/usr/bin/env node
// Builds the Batch 11 consumed-dual dry-run. It writes review artifacts only:
// no production overlay, curated pack, ledger, readiness, runtime, or real
// quantity-semantics sidecar is modified.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { classifyIngredientCompatibility } from './dazhong-runtime-compatibility.mjs';
import { assertValidRecipeQuantitySemantics } from './recipe-quantity-semantics.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const readJson = (file) => JSON.parse(fs.readFileSync(path.join(repoRoot, file), 'utf8'));
const BASELINE = 'c4d2a7b74090bdbee70e1e3fa81d749e786739bd';
const DRY_RUN_FILE = 'data/source-restoration/dazhong-chuancai-1979-promotion-batch11-dry-run.v1.json';
const CONTRACT_REVIEW_FILE = 'data/source-restoration/dazhong-chuancai-1979-dual-quantity-contract-review.v1.json';
const UNIT_WHITELIST = /^(g|ml|个|只|颗|枚|根|条|片|块|瓣|张|把|棵|头|支|份|盒|袋|包|瓶|罐|听)$/;

const catalog = readJson('data/source-restoration/dazhong-chuancai-1979-catalog.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');
const canonical = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');
const overlay = readJson('data/recipe-completion-overlay.json');
const contractReview = readJson(CONTRACT_REVIEW_FILE);

const recipeById = new Map(canonical.recipes.map((recipe) => [recipe.entryId, recipe]));
const readinessById = new Map(readiness.entries.map((entry) => [entry.entryId, entry]));
const catalogById = new Map(catalog.entries.map((entry) => [entry.entryId, entry]));
const productionIds = new Set([
  ...curated.recipes.map((recipe) => recipe.id),
  ...full.recipes.map((recipe) => recipe.id),
  ...(overlay.newRecipes ?? []).map((recipe) => recipe.id),
]);
const productionNames = new Set([
  ...curated.recipes.map((recipe) => recipe.name),
  ...full.recipes.map((recipe) => recipe.name),
]);

function productionMethod(entryId) {
  return recipeById.get(entryId).methodSummary.steps
    .map((step) => `${step.order}. ${step.summary}`)
    .join('\n');
}

function productionIngredients(entryId) {
  return readinessById.get(entryId).productionIngredientPlan.inventoryIngredients.map((ingredient) => ({
    item: ingredient.productionItem,
    qty: ingredient.qty,
    unit: ingredient.unit,
  }));
}

function productionRecipe(entryId) {
  const entry = readinessById.get(entryId);
  const catalogEntry = catalogById.get(entryId);
  return {
    id: `dz1979-p${catalogEntry.bookPage}`,
    name: entry.bookName,
    tags: ['川菜', catalogEntry.category],
    method: productionMethod(entryId),
  };
}

function buildSidecar(entryIds) {
  const recipes = {};
  for (const entryId of entryIds) {
    const recipe = recipeById.get(entryId);
    const entries = {};
    for (const ingredient of recipe.ingredients) {
      const quantity = ingredient.normalizedQuantity ?? {};
      const hasConsumed = ['consumedQty', 'consumedUnit', 'consumedReferenceQty', 'consumedQualifier']
        .some((key) => key in quantity);
      if (!hasConsumed) continue;
      entries[ingredient.rawItemText] = {
        input: { qty: quantity.qty, unit: quantity.unit },
        consumed: {
          qty: quantity.consumedQty ?? null,
          unit: quantity.consumedUnit,
          referenceQty: quantity.consumedReferenceQty ?? null,
          qualifier: quantity.consumedQualifier ?? null,
        },
        rawQuantityText: ingredient.rawQuantityText,
        provenance: {
          sourceId: 'dazhong-chuancai-1979',
          entryId,
          pdfPage: recipe.source.pdfStartPage,
          bookPage: recipe.source.bookStartPage,
        },
      };
    }
    if (Object.keys(entries).length > 0) recipes[entryId] = { ingredients: entries };
  }
  return { schema: 'kitchenmanager.recipe-quantity-semantics.v1', recipes };
}

function candidateBasePack(entryId) {
  const recipe = productionRecipe(entryId);
  return {
    recipes: [recipe],
    recipe_ingredients: { [recipe.id]: productionIngredients(entryId) },
  };
}

function reviewedConsumedIsExact(entryId) {
  const generated = buildSidecar([entryId]);
  const reviewed = contractReview.proposedContract.prototype.recipes?.[entryId];
  if (!reviewed || JSON.stringify(generated.recipes[entryId]) !== JSON.stringify(reviewed)) return false;
  try {
    assertValidRecipeQuantitySemantics(generated, candidateBasePack(entryId));
    return true;
  } catch {
    return false;
  }
}

function passesHardGates(entryId) {
  const entry = readinessById.get(entryId);
  const recipe = recipeById.get(entryId);
  if (!entry || !recipe || entry.promotionDisposition !== 'new-recipe-candidate'
    || entry.promotionState !== 'not-promoted'
    || entry.sourceQuality !== 'ready-for-later-promotion-review') return false;
  const plan = entry.productionIngredientPlan;
  if (plan.quantityReadiness !== 'exact-comparable'
    || plan.inventoryIngredients.some((ingredient) => !ingredient.inventoryComparable)
    || plan.methodOnlyAnalysis.some((item) => item.conversionWarning)) return false;
  if (recipe.contentMissing === true || recipe.contentIncomplete === true || recipe.uncertainties.length > 0) return false;
  if (recipe.confidence.recognition !== 'high' || recipe.confidence.conversion !== 'high'
    || recipe.methodSummary.confidence !== 'high' || recipe.titleVisualCheck.confidence !== 'high'
    || recipe.ingredients.some((ingredient) => (
      ingredient.confidence.recognition !== 'high' || ingredient.confidence.conversion !== 'high'
    ))) return false;
  if (recipe.ingredients.some((ingredient) => ingredient.memberQuantityMode === 'unallocated-group-total')) return false;
  if (recipe.ingredients.some((ingredient) => !['exact-mass', 'exact-count'].includes(ingredient.normalizedQuantity.kind))) return false;

  const hasConsumed = recipe.ingredients.some((ingredient) => (
    ['consumedQty', 'consumedUnit', 'consumedReferenceQty', 'consumedQualifier']
      .some((key) => key in ingredient.normalizedQuantity)
  ));
  if (!hasConsumed || !reviewedConsumedIsExact(entryId)) return false;
  const productionId = productionRecipe(entryId).id;
  return !productionIds.has(productionId) && !productionNames.has(entry.bookName);
}

function auditRuntimeCompatibility(entryId) {
  const coreResults = [];
  const nonCoreObservations = [];
  for (const ingredient of productionIngredients(entryId)) {
    const result = classifyIngredientCompatibility(ingredient.item, ingredient.qty, ingredient.unit);
    const record = {
      item: ingredient.item,
      qty: ingredient.qty,
      unit: ingredient.unit,
      role: result.role,
      canonical: result.canonical,
      normalizedQuantity: result.normalizedQuantity,
    };
    if (result.role === 'core') {
      coreResults.push({ ...record, compatibility: result.compatibility, reasons: result.reasons });
    } else {
      nonCoreObservations.push({ ...record, observation: result.observation });
    }
  }
  const unresolved = coreResults.filter((result) => result.compatibility === 'unresolved-name-match');
  const confirmations = coreResults.filter((result) => result.compatibility === 'expected-unit-confirmation');
  return {
    coreResults,
    nonCoreObservations,
    unresolvedItems: unresolved.map((result) => result.item),
    unitConfirmationItems: confirmations.map((result) => `${result.item}(${result.unit})`),
    blocked: unresolved.length > 0,
  };
}

const remaining = readiness.entries.filter((entry) => (
  entry.promotionDisposition === 'new-recipe-candidate' && entry.promotionState === 'not-promoted'
));
const hardGateSurvivors = remaining.filter((entry) => passesHardGates(entry.entryId)).map((entry) => entry.entryId);
const hardGateBlocked = remaining.map((entry) => entry.entryId).filter((id) => !hardGateSurvivors.includes(id));
const runtimeAudits = new Map(hardGateSurvivors.map((id) => [id, auditRuntimeCompatibility(id)]));
const runtimeBlocked = hardGateSurvivors.filter((id) => runtimeAudits.get(id).blocked);
const eligible = hardGateSurvivors.filter((id) => !runtimeAudits.get(id).blocked);

function rankKey(entryId) {
  const recipe = recipeById.get(entryId);
  return [
    runtimeAudits.get(entryId).unitConfirmationItems.length,
    recipe.ingredients.filter((ingredient) => ingredient.memberQuantityMode).length,
    recipe.ingredients.length,
    recipe.methodSummary.steps.length,
    entryId,
  ];
}

const ranked = [...eligible].sort((a, b) => {
  const left = rankKey(a);
  const right = rankKey(b);
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] < right[index]) return -1;
    if (left[index] > right[index]) return 1;
  }
  return 0;
});
const selected = ranked.slice(0, 5);

function quantityReviewFor(entryId, productionId, ingredients) {
  const source = recipeById.get(entryId);
  const canonicalByItem = new Map(source.ingredients.map((ingredient) => [ingredient.rawItemText, ingredient]));
  return ingredients.map((ingredient) => {
    const canonicalIngredient = canonicalByItem.get(ingredient.item);
    if (!canonicalIngredient) throw new Error(`no canonical ingredient for ${entryId}:${ingredient.item}`);
    const quantity = canonicalIngredient.normalizedQuantity;
    return {
      entryId,
      productionId,
      recipeName: readinessById.get(entryId).bookName,
      item: ingredient.item,
      qty: ingredient.qty,
      unit: ingredient.unit,
      evidenceType: 'source-restoration',
      canonicalSourceFile: 'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
      sourceRawQuantityText: canonicalIngredient.rawQuantityText,
      normalizedQuantity: { kind: quantity.kind, qty: quantity.qty, unit: quantity.unit },
      dryRunArtifact: DRY_RUN_FILE,
      reviewStatus: 'approved',
    };
  });
}

const items = selected.map((entryId, index) => {
  const recipe = productionRecipe(entryId);
  const ingredients = productionIngredients(entryId);
  const audit = runtimeAudits.get(entryId);
  return {
    entryId,
    productionId: recipe.id,
    name: recipe.name,
    category: catalogById.get(entryId).category,
    tags: recipe.tags,
    selectionMetrics: {
      rankKey: rankKey(entryId),
      rankPosition: index + 1,
    },
    proposedOverlayRecipe: recipe,
    proposedOverlayIngredients: { [recipe.id]: ingredients },
    proposedCuratedRecipe: recipe,
    proposedCuratedIngredients: { [recipe.id]: ingredients },
    quantityReviewPreview: { records: quantityReviewFor(entryId, recipe.id, ingredients) },
    coreRuntimeCompatibility: {
      coreIngredientResults: audit.coreResults,
      nonCoreObservations: audit.nonCoreObservations,
      unitConfirmationItems: audit.unitConfirmationItems,
      unresolvedItems: audit.unresolvedItems,
      gatePassed: !audit.blocked,
    },
    provenanceRecord: {
      entryId,
      bookPage: recipeById.get(entryId).source.bookStartPage,
      pdfPage: recipeById.get(entryId).source.pdfStartPage,
      sourceFile: 'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
    },
  };
});

const proposedBasePack = {
  recipes: items.map((item) => item.proposedCuratedRecipe),
  recipe_ingredients: Object.assign({}, ...items.map((item) => item.proposedCuratedIngredients)),
};
const proposedQuantitySemanticsSidecar = buildSidecar(selected);
const sidecarValidation = assertValidRecipeQuantitySemantics(
  proposedQuantitySemanticsSidecar,
  proposedBasePack,
);
const quantityReviewRecords = items.flatMap((item) => item.quantityReviewPreview.records);

function simulatePromotionChain() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dz1979-batch11-'));
  try {
    fs.mkdirSync(path.join(tmp, 'scripts'));
    fs.mkdirSync(path.join(tmp, 'data'));
    for (const file of ['scripts/curate-recipes.js', 'data/sichuan-recipes.json', 'data/recipe-completion-overlay.json']) {
      fs.copyFileSync(path.join(repoRoot, file), path.join(tmp, file));
    }
    const tmpOverlayPath = path.join(tmp, 'data/recipe-completion-overlay.json');
    const tmpOverlay = JSON.parse(fs.readFileSync(tmpOverlayPath, 'utf8'));
    const originalUpdatedAt = tmpOverlay.updatedAt;
    tmpOverlay.newRecipes.push(...items.map((item) => item.proposedOverlayRecipe));
    Object.assign(tmpOverlay.newRecipeIngredients, proposedBasePack.recipe_ingredients);
    fs.writeFileSync(tmpOverlayPath, `${JSON.stringify(tmpOverlay, null, 2)}\n`);
    execFileSync('node', [path.join(tmp, 'scripts/curate-recipes.js')], { cwd: tmp, stdio: 'pipe' });
    return {
      curated: JSON.parse(fs.readFileSync(path.join(tmp, 'data/sichuan-recipes.curated.json'), 'utf8')),
      removed: JSON.parse(fs.readFileSync(path.join(tmp, 'data/recipe-curation-removed.json'), 'utf8')),
      needing: JSON.parse(fs.readFileSync(path.join(tmp, 'data/recipes-needing-completion.json'), 'utf8')),
      updatedAtPreserved: JSON.parse(fs.readFileSync(tmpOverlayPath, 'utf8')).updatedAt === originalUpdatedAt,
    };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

const simulated = simulatePromotionChain();
const currentById = new Map(curated.recipes.map((recipe) => [recipe.id, recipe]));
const simulatedById = new Map(simulated.curated.recipes.map((recipe) => [recipe.id, recipe]));
const existingIds = [...currentById.keys()];
const newRecipeIds = [...simulatedById.keys()].filter((id) => !currentById.has(id)).sort();
const existingDeleted = existingIds.filter((id) => !simulatedById.has(id));
const existingRecipeModified = existingIds.filter((id) => (
  JSON.stringify(currentById.get(id)) !== JSON.stringify(simulatedById.get(id))
));
const existingMapModified = existingIds.filter((id) => (
  JSON.stringify(curated.recipe_ingredients[id]) !== JSON.stringify(simulated.curated.recipe_ingredients[id])
));

const simulation = {
  tempCurateResult: {
    headCuratedCount: curated.recipes.length,
    simulatedCuratedCount: simulated.curated.recipes.length,
    newRecipeIds,
    newRecipeCount: newRecipeIds.length,
    existingDeleted: existingDeleted.length,
    existingRecipeObjectModified: existingRecipeModified.length,
    existingIngredientMapModified: existingMapModified.length,
    strictCurrentPlusN: simulated.curated.recipes.length === curated.recipes.length + selected.length
      && newRecipeIds.length === selected.length
      && existingDeleted.length === 0
      && existingRecipeModified.length === 0
      && existingMapModified.length === 0,
  },
  auxiliaryGeneratedFiles: {
    recipeCurationRemoved: JSON.stringify(simulated.removed) === JSON.stringify(readJson('data/recipe-curation-removed.json')) ? 'unchanged' : 'changed',
    recipesNeedingCompletion: JSON.stringify(simulated.needing) === JSON.stringify(readJson('data/recipes-needing-completion.json')) ? 'unchanged' : 'changed',
    overlayUpdatedAtPreserved: simulated.updatedAtPreserved,
  },
};

const funnel = {
  remainingNotPromotedCandidates: remaining.length,
  afterHardGates: hardGateSurvivors.length,
  hardGateBlocked: hardGateBlocked.length,
  blockedByRuntimeNameGate: runtimeBlocked.length,
  eligible: eligible.length,
  selected: selected.length,
};
const expectedFunnel = {
  remainingNotPromotedCandidates: 3,
  afterHardGates: 3,
  hardGateBlocked: 0,
  blockedByRuntimeNameGate: 0,
  eligible: 3,
  selected: 3,
};
const expectedSet = ['dz1979-p222', 'dz1979-p224', 'dz1979-p226'];
const problems = [];
if (JSON.stringify(funnel) !== JSON.stringify(expectedFunnel)) problems.push(`funnel-mismatch:${JSON.stringify(funnel)}`);
if (JSON.stringify([...selected].sort()) !== JSON.stringify(expectedSet)) problems.push(`selected-set-mismatch:${selected.join(',')}`);
if (!simulation.tempCurateResult.strictCurrentPlusN) problems.push('temp-curate-not-strict-current-plus-n');
if (simulation.auxiliaryGeneratedFiles.recipeCurationRemoved !== 'unchanged'
  || simulation.auxiliaryGeneratedFiles.recipesNeedingCompletion !== 'unchanged') problems.push('auxiliary-data-drift');
if (!simulation.auxiliaryGeneratedFiles.overlayUpdatedAtPreserved) problems.push('overlay-updatedAt-drift');
if (sidecarValidation.joins.length !== 4) problems.push(`sidecar-join-count:${sidecarValidation.joins.length}`);
if (fs.existsSync(path.join(repoRoot, 'data/recipe-quantity-semantics.json'))) problems.push('real-sidecar-exists');
for (const record of quantityReviewRecords) {
  if (!UNIT_WHITELIST.test(record.unit)) problems.push(`unit-not-whitelisted:${record.productionId}:${record.item}`);
  if (Object.keys(record.normalizedQuantity).some((key) => key.startsWith('consumed'))) {
    problems.push(`consumed-leaked-into-quantity-review:${record.productionId}:${record.item}`);
  }
}

const unitCounts = {};
for (const record of quantityReviewRecords) unitCounts[record.unit] = (unitCounts[record.unit] ?? 0) + 1;
const output = {
  schema: 'kitchenmanager.source-restoration.promotion-batch11-dry-run.v1',
  generatedAt: new Date().toISOString().slice(0, 10),
  baseline: { main: BASELINE, curated: 162, promoted: 36, remaining: 3, applicationReady: false },
  purpose: 'Batch11 reviewed consumed-dual + validated sidecar semantics dry-run. Base qty/unit remains input; consumed exists only in proposedQuantitySemanticsSidecar. No production write or promotion.',
  applicationReady: false,
  remediationPolicy: 'allow-reviewed-consumed-dual-with-validated-sidecar',
  contractReviewArtifact: CONTRACT_REVIEW_FILE,
  sidecarContractValidator: 'scripts/recipe-quantity-semantics.mjs',
  selection: {
    order: 'expected-unit-confirmation count -> special structure count -> ingredient count -> method step count -> entryId',
    funnel,
    hardGateBlockedEntryIds: hardGateBlocked,
    runtimeNameGateBlockedEntryIds: runtimeBlocked,
    rankedEntryIds: ranked,
    selectedEntryIds: selected,
    note: 'Selection is mechanically derived; the expected set is only a stop-the-run postcondition.',
  },
  items,
  proposedQuantitySemanticsSidecar,
  sidecarValidation,
  quantityReviewPreview: {
    purpose: 'Base production input qty/unit only; consumed values remain exclusively in the proposed sidecar.',
    recordCount: quantityReviewRecords.length,
    unitCounts,
    records: quantityReviewRecords,
  },
  simulation,
  compatibility: {
    pwaIngredientShape: '{item,qty,unit}',
    iosIngredientShape: '{item,qty,unit}',
    oldConsumersLoadSidecar: false,
    basePackContainsConsumedFields: false,
  },
  productionWrites: false,
  writeTargets: [
    DRY_RUN_FILE,
    'data/source-restoration/dazhong-chuancai-1979-promotion-batch11-dry-run.v1.md',
  ],
  verificationProblems: problems,
};

const outPath = path.join(repoRoot, DRY_RUN_FILE);
fs.writeFileSync(outPath, `${JSON.stringify(output, null, 2)}\n`);
const markdown = `# 《大众川菜》1979 Production Batch 11 dry-run

Baseline: ${BASELINE}

## 结论

- Design B executable validation: passed (${sidecarValidation.joins.length} exact recipeId+item joins; no array index).
- Funnel: ${Object.values(funnel).join(' -> ')}.
- Mechanical order: ${selected.join(' -> ')}.
- Temp Curated: ${curated.recipes.length} -> ${simulated.curated.recipes.length}; existing recipe/map drift 0.
- Proposed sidecar: p222 菜油 500/100g; p226 菜油 500/100g; p226 干豆粉 500/200g; p224 菜油 500/100g.
- Quantity review: ${quantityReviewRecords.length} base-input records; units ${JSON.stringify(unitCounts)}; no consumed fields.
- Production/ledger/readiness/runtime writes: none. applicationReady=false.

本轮不创建 data/recipe-quantity-semantics.json，不正式 promotion Batch11。
`;
fs.writeFileSync(
  path.join(repoRoot, 'data/source-restoration/dazhong-chuancai-1979-promotion-batch11-dry-run.v1.md'),
  markdown,
);

console.log(`Wrote ${outPath}`);
console.log(`funnel: ${JSON.stringify(funnel)}`);
console.log(`selected: ${selected.join(', ')}`);
console.log(`records: ${quantityReviewRecords.length}, units: ${JSON.stringify(unitCounts)}`);
console.log(`verificationProblems: ${problems.length}`);
if (problems.length > 0) process.exitCode = 1;
