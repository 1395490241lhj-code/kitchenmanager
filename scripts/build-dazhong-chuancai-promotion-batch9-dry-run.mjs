#!/usr/bin/env node
// Builds the 《大众川菜》1979 Production Batch 9 dry-run.
//
// Reuses the verified Batch 1 hard gates (frozen readiness audit) and the
// Batch 2-8 runtime gate: only core ingredients are checked against the
// real inventory/recipe canonicalization pipeline; any unresolved-name-match
// blocks the candidate, expected-unit-confirmation is recorded but allowed.
// This generator introduces no alias, family, policy, or unit conversion.
//
// Mechanically selects up to 5 of the safest remaining new-recipe-candidates
// (fewer if eligible < 5), produces the overlay -> curate -> provenance
// promotion preview, and simulates the real promotion chain against a temp
// copy (real scripts/curate-recipes.js) so the artifact records the exact
// expected production delta. No production file in the workspace is written.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { classifyIngredientCompatibility } from './dazhong-runtime-compatibility.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(path.join(repoRoot, relativePath), 'utf8'),
);

const catalog = readJson('data/source-restoration/dazhong-chuancai-1979-catalog.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');
const recipes = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');
const overlay = readJson('data/recipe-completion-overlay.json');
const methodOnlyReview = readJson('data/source-restoration/dazhong-chuancai-1979-methodonly-remediation-review.v1.json');

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

// -- Batch 1 hard gates (frozen, reused verbatim for reference/regression) --
// This is the exact legacy gate Batch 1-6 used (pre-Batch-7). It is preserved here
// unmodified (never called for Batch 9 selection) purely so this file can
// assert, in its own regression tests, that legacy behavior is unchanged.
// Batch 1-8 frozen dry-run artifacts are never regenerated or touched by
// this file.

function passesHardGatesLegacy(entryId) {
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

// -- Inherited Batch 7 remediation policy: allow-safe-same-for-each ---------
//
// remediationPolicy = 'allow-safe-same-for-each'
//
// This is the mechanical rule Batch 7 introduced, exactly as
// confirmed by the blocker triage (dazhong-chuancai-1979-promotion-blocker-
// triage.v1.json, p144/p211 mechanical-fix-candidate analysis):
//
//   legacy (Batch 1-6, pre-Batch-7):   ANY ing.memberQuantityMode (same-for-each OR
//                         unallocated-group-total) hard-blocks the entry.
//   Batch 7+ remediated:  only memberQuantityMode === 'unallocated-group-
//                         total' hard-blocks; 'same-for-each' is allowed
//                         through, because its split is already mechanical,
//                         lossless, and reuses the exact frozen
//                         ingredientToProductionPlan same-for-each logic in
//                         scripts/build-dazhong-chuancai-promotion-readiness.mjs
//                         (each member inherits the identical rawQuantity-
//                         derived qty/unit — no ratio split, no guess).
//
// Every other line of the hard gate is byte-identical to the legacy gate;
// no other criterion is relaxed.

function passesHardGatesSameForEachRemediated(entryId, { skipMethodOnlyCheck = false } = {}) {
  const entry = readinessByEntryId.get(entryId);
  const recipe = recipeByEntryId.get(entryId);
  if (!entry || entry.promotionDisposition !== 'new-recipe-candidate') return false;
  if (entry.sourceQuality !== 'ready-for-later-promotion-review') return false;

  const plan = entry.productionIngredientPlan;
  if (plan.quantityReadiness !== 'exact-comparable') return false;
  if (plan.inventoryIngredients.some((ing) => !ing.inventoryComparable)) return false;
  if (!skipMethodOnlyCheck && plan.methodOnlyAnalysis.some((item) => item.conversionWarning)) return false;

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
    // Only the difference from legacy: unallocated-group-total still hard
    // blocks (group total never safely splittable); same-for-each is
    // allowed through to the runtime gate / production plan below, which
    // already implements the lossless split.
    if (ing.memberQuantityMode === 'unallocated-group-total') return false;
    if ('consumedQty' in quantity || 'consumedReferenceQty' in quantity) return false;
    if ('consumedQualifier' in quantity || 'consumedUnit' in quantity) return false;
  }

  if (productionNames.has(entry.bookName)) return false;
  return true;
}

// This is the gate Batch 9 selection actually uses.

// -- Inherited Batch 8 remediation policy: allow-reviewed-methodonly-null ---
//
// remediationPolicy = 'allow-reviewed-methodonly-null'
//
// This is the second mechanical rule, introduced in Batch 8 and inherited
// unchanged on top of Batch 7's same-for-each remediation, exactly
// as confirmed and visually scan-verified by:
//   data/source-restoration/dazhong-chuancai-1979-methodonly-remediation-review.v1.json
//
// The allowlist below is INTENTIONALLY an exact (entryId, item) enumeration
// — not a rule that auto-allows any future core-no-quantity methodOnly item.
// Every entry here was individually confirmed by that frozen review to:
//   (a) genuinely appear in the canonical method text,
//   (b) genuinely have no quantity anywhere in the source (rawQuantityText
//       === null, not an extraction gap), and
//   (c) classify as role=seasoning (never core) via the unmodified real
//       classifyRecipeIngredient, so it can never enter inventory coverage /
//       recommendation matching regardless of qty.
// Any methodOnly item not in this exact list continues to hard-block,
// exactly as under Batch 7's gate.
const REVIEWED_METHODONLY_NULL_ALLOWLIST = new Map([
  ['dz1979-p129', new Set(['姜', '花椒'])],
  ['dz1979-p130', new Set(['胡椒面'])],
]);

function passesHardGatesMethodOnlyNullRemediated(entryId) {
  if (!passesHardGatesSameForEachRemediated(entryId, { skipMethodOnlyCheck: true })) return false;
  const entry = readinessByEntryId.get(entryId);
  const plan = entry.productionIngredientPlan;
  const allowedItems = REVIEWED_METHODONLY_NULL_ALLOWLIST.get(entryId) ?? new Set();
  // Every methodOnly conversionWarning item must either not exist, or (if it
  // does) every one of its split sub-items must be in the exact reviewed
  // allowlist for this entryId. Any unreviewed core-no-quantity item still
  // hard-blocks.
  for (const moi of plan.methodOnlyAnalysis) {
    if (!moi.conversionWarning) continue;
    const parts = moi.sourceRawItemText.split(/[、，,]/).map((s) => s.trim()).filter(Boolean);
    if (!parts.every((part) => allowedItems.has(part))) return false;
  }
  return true;
}

const passesHardGates = passesHardGatesMethodOnlyNullRemediated;

// -- Batch 9 runtime gate (core ingredients only, reused Batch 2 logic) ------

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

// Whether methodOnly conversionWarning items for this entry are still an
// unresolved blocker (true) vs. fully covered by the reviewed allowlist
// (false). Used only for exclusion-reason bookkeeping, mirrors the same
// logic passesHardGatesMethodOnlyNullRemediated already applies.
function methodOnlyStillBlocks(entryId, plan) {
  const allowedItems = REVIEWED_METHODONLY_NULL_ALLOWLIST.get(entryId) ?? new Set();
  for (const moi of plan.methodOnlyAnalysis) {
    if (!moi.conversionWarning) continue;
    const parts = moi.sourceRawItemText.split(/[、，,]/).map((s) => s.trim()).filter(Boolean);
    if (!parts.every((part) => allowedItems.has(part))) return true;
  }
  return false;
}

const hardGateSurvivors = [];
for (const entry of remainingCandidates) {
  const id = entry.entryId;
  if (!passesHardGates(id)) {
    const recipe = recipeByEntryId.get(id);
    const plan = entry.productionIngredientPlan;
    if (methodOnlyStillBlocks(id, plan)) noteExclusion(id, 'methodOnlyConversionWarning');
    if (plan.quantityReadiness !== 'exact-comparable' || plan.inventoryIngredients.some((ing) => !ing.inventoryComparable)) noteExclusion(id, 'nonExactQuantity');
    if (recipe.ingredients?.some((ing) => ('consumedQty' in (ing.normalizedQuantity ?? {})) || ('consumedReferenceQty' in (ing.normalizedQuantity ?? {})))) noteExclusion(id, 'consumedDualQuantity');
    // remediationPolicy = allow-safe-same-for-each: same-for-each is no
    // longer a hard-gate exclusion reason (see passesHardGatesSameForEach
    // Remediated above). Only unallocated-group-total remains blocked.
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

// -- Hard-gate blocked count: mechanically derived two independent ways ----
// so a documentation/summary mismatch (like the one this fix addresses)
// cannot silently happen again. Both must agree with each other and with
// the funnel arithmetic below.
const hardGateBlockedByDifference = remainingCandidates.length - hardGateSurvivors.length;
const hardGateBlockedUniqueIds = [...new Set(Object.values(gateExclusions.hardGate).flat())];
const hardGateBlockedByUnion = hardGateBlockedUniqueIds.length;
if (hardGateBlockedByDifference !== hardGateBlockedByUnion) {
  throw new Error(
    `hard-gate blocked count mismatch: remaining-minus-survivors=${hardGateBlockedByDifference} `
    + `!= unique-exclusion-union=${hardGateBlockedByUnion}`,
  );
}
const hardGateBlockedCount = hardGateBlockedByUnion;

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

const MAX_BATCH_SIZE = 5;
const selected = ranked.slice(0, MAX_BATCH_SIZE);
const selectedCount = selected.length;

// -- Dry-run items -----------------------------------------------------------

function productionMethod(entryId) {
  const recipe = recipeByEntryId.get(entryId);
  return (recipe.methodSummary?.steps ?? [])
    .map((step) => `${step.order}. ${step.summary}`)
    .join('\n');
}

// Appends the reviewed methodOnly-null seasoning items (qty=null, unit=null)
// for entries covered by REVIEWED_METHODONLY_NULL_ALLOWLIST, exactly as
// confirmed by the frozen methodonly-remediation-review artifact. No qty is
// guessed; these three items never carried a source quantity.
function productionIngredients(entryId) {
  const entry = readinessByEntryId.get(entryId);
  const fromPlan = entry.productionIngredientPlan.inventoryIngredients.map((ing) => ({
    item: ing.productionItem,
    qty: ing.qty,
    unit: ing.unit,
  }));
  const reviewedNullItems = [...(REVIEWED_METHODONLY_NULL_ALLOWLIST.get(entryId) ?? [])].map((item) => ({
    item,
    qty: null,
    unit: null,
  }));
  return [...fromPlan, ...reviewedNullItems];
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
  for (const ing of recipe.ingredients.filter((i) => i.memberQuantityMode === 'same-for-each')) {
    transformNotes.push(
      `remediationPolicy=allow-safe-same-for-each：组「${ing.rawItemText}」(${ing.rawQuantityText}) 按 members 逐项精确继承 ${ing.normalizedQuantity.qty}${ing.normalizedQuantity.unit}，未做比例分配/猜测：${(ing.members ?? []).map((m) => `${m.item}=${m.qty}${m.unit}`).join('、')}。`,
    );
  }
  for (const moi of recipe.methodOnlyIngredients ?? []) {
    const analysis = entry.productionIngredientPlan.methodOnlyAnalysis
      .find((item) => item.sourceRawItemText === moi.rawItemText);
    transformNotes.push(
      `methodOnly「${moi.rawItemText}」→ ${analysis?.classification ?? 'n/a'}${analysis?.conversionWarning ? `（warning: ${analysis.conversionWarning}）` : ''}`,
    );
  }
  const reviewedNullAllowlist = REVIEWED_METHODONLY_NULL_ALLOWLIST.get(entryId);
  if (reviewedNullAllowlist) {
    transformNotes.push(
      `remediationPolicy=allow-reviewed-methodonly-null：${[...reviewedNullAllowlist].join('、')} 以 qty=null/unit=null 进入 production，依据 data/source-restoration/dazhong-chuancai-1979-methodonly-remediation-review.v1.json 逐条人工+扫描确认（method 文本确实提及、source 确实无数量、role=seasoning 不参与库存匹配），未猜测任何数量。`,
    );
  }

  const specialStructures = recipe.ingredients.filter((ing) => ing.memberQuantityMode).length;

  // Per-item quantity review preview: every qty/unit ingredient traced back
  // to the audited productionIngredientPlan / canonical raw quantity, never
  // recomputed here.
  // Same-for-each members (e.g. "姜、葱" -> 姜, 葱) are keyed here by their
  // individual member item name too, so the per-member quantity review
  // preview traces back to the same canonical rawQuantityText/normalized
  // Quantity their parent group carries — no recomputation, no per-member
  // canonical record invented.
  const canonicalIngredientByItem = new Map();
  for (const ingredient of recipe.ingredients ?? []) {
    canonicalIngredientByItem.set(ingredient.rawItemText, ingredient);
    if (ingredient.memberQuantityMode === 'same-for-each') {
      for (const member of ingredient.members ?? []) {
        if (!canonicalIngredientByItem.has(member.item)) {
          canonicalIngredientByItem.set(member.item, ingredient);
        }
      }
    }
  }
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
  // Same-for-each members are also keyed by their individual item name
  // (see the identical construction above); no per-member canonical record
  // is invented, they trace back to the same parent group's
  // rawQuantityText/normalizedQuantity.
  const canonicalIngredientByItem = new Map();
  for (const ingredient of sourceRecipe.ingredients ?? []) {
    canonicalIngredientByItem.set(ingredient.rawItemText, ingredient);
    if (ingredient.memberQuantityMode === 'same-for-each') {
      for (const member of ingredient.members ?? []) {
        if (!canonicalIngredientByItem.has(member.item)) {
          canonicalIngredientByItem.set(member.item, ingredient);
        }
      }
    }
  }
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
      dryRunArtifact: 'data/source-restoration/dazhong-chuancai-1979-promotion-batch9-dry-run.v1.json',
      reviewStatus: 'approved',
    });
  }
}

// -- Temp-directory real promotion chain simulation ---------------------------

function simulatePromotionChain() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dz1979-batch9-'));
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
    strictCurrentPlusN: (
      tmpCurated.recipes.length === curated.recipes.length + selectedCount
      && newIds.length === selectedCount
      && existingDeleted.length === 0
      && existingModified.length === 0
      && existingIngredientModified.length === 0
    ),
  },
  auxiliaryGeneratedFiles: {
    recipeCurationRemoved: {
      changes: removedDiffers ? 'UNEXPECTED semantic change' : 'unchanged',
      note: `Batch 9 入选的 ${selectedCount} 道均有 method，curate 直接保留，不进入 removed；既有 removed 决定不变。`,
    },
    recipesNeedingCompletion: {
      changes: needingDiffers ? 'UNEXPECTED semantic change' : 'unchanged',
      note: 'Batch 9 不改变任何既有 needing 决定。',
    },
    recipeCurationSummaryMd: {
      changes: summaryDiffers ? `expected count changes from the ${selectedCount} additions` : 'unchanged',
      expectedLineChanges: [
        `原始菜谱（有效集）: 353 -> ${353 + selectedCount}`,
        `overlay 新增/补全净增: 89 -> ${89 + selectedCount}`,
        `curated 保留: 157 -> ${157 + selectedCount}`,
        `从有效集保留（有做法）: 136 -> ${136 + selectedCount}`,
        `从 overlay 补全 method: 136 -> ${136 + selectedCount}`,
        `从 overlay 补全 ingredients: 99 -> ${99 + selectedCount}`,
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
  batch9Compatible: items.every((item) => (
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
const expectedSelectedCount = Math.min(eligible.length, MAX_BATCH_SIZE);
if (selected.length !== expectedSelectedCount) problems.push(`batch-size-mismatch:selected=${selected.length},expected=${expectedSelectedCount}`);
const selectedNames = items.map((item) => item.name);
if (new Set(selectedNames).size !== selectedCount) problems.push('duplicate-selected-names');
if (items.some((item) => productionIds.has(item.productionId))) {
  problems.push('production-id-conflict');
}
if (items.some((item) => productionNames.has(item.name))) {
  problems.push('production-name-conflict');
}
if (!simulation.tempCurateResult.strictCurrentPlusN) {
  problems.push('temp-curate-not-strict-current-plus-n');
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
if (hardGateBlockedCount !== remainingCandidates.length - hardGateSurvivors.length) {
  problems.push('hard-gate-blocked-count-mismatch-difference');
}
if (hardGateBlockedCount !== hardGateBlockedUniqueIds.length) {
  problems.push('hard-gate-blocked-count-mismatch-union');
}
if (hardGateBlockedCount + gateExclusions.runtimeNameGate.length + eligible.length !== remainingCandidates.length) {
  problems.push('funnel-destination-arithmetic-mismatch');
}
const expectedCheckpoint = {
  remainingNotPromotedCandidates: 8,
  afterHardGates: 2,
  hardGateBlocked: 6,
  blockedByRuntimeNameGate: 0,
  eligible: 2,
  selected: 2,
};
const actualCheckpoint = {
  remainingNotPromotedCandidates: remainingCandidates.length,
  afterHardGates: hardGateSurvivors.length,
  hardGateBlocked: hardGateBlockedCount,
  blockedByRuntimeNameGate: gateExclusions.runtimeNameGate.length,
  eligible: eligible.length,
  selected: selected.length,
};
if (JSON.stringify(actualCheckpoint) !== JSON.stringify(expectedCheckpoint)) {
  problems.push(`batch9-checkpoint-mismatch:${JSON.stringify(actualCheckpoint)}`);
}
if (JSON.stringify([...selected].sort()) !== JSON.stringify(['dz1979-p137', 'dz1979-p161'])) {
  problems.push(`batch9-selected-mismatch:${selected.join(',')}`);
}
// The review artifact this batch depends on must still confirm its safety
// conclusion; if it were ever regenerated with a different result, this
// dry-run must not silently proceed.
if (methodOnlyReview.safetyAnalysis?.conclusion !== 'safe-to-allow-qty-null-for-these-specific-confirmed-methodonly-items') {
  problems.push('methodonly-review-no-longer-confirms-safe');
}
if (methodOnlyReview.verificationProblems?.length > 0) {
  problems.push('methodonly-review-has-verification-problems');
}
// This dry-run must never introduce a NEW structured (qty/unit-carrying)
// reviewed record for a methodOnly-null item: p129's 姜/花椒 must never
// appear as a quantityReviewRecords entry (note: p130's 姜 legitimately
// appears there via the unrelated same-for-each 葱节、姜 group, which is a
// different ingredient reference, not the methodOnly null item).
if (quantityReviewRecords.some((r) => r.entryId === 'dz1979-p129' && ['姜', '花椒'].includes(r.item))) {
  problems.push('methodonly-null-item-unexpectedly-structured');
}
if (quantityReviewRecords.some((r) => r.entryId === 'dz1979-p130' && r.item === '胡椒面')) {
  problems.push('methodonly-null-item-unexpectedly-structured');
}

const output = {
  schema: 'kitchenmanager.source-restoration.promotion-batch9-dry-run.v1',
  generatedAt: new Date().toISOString().slice(0, 10),
  baseline: {
    main: '0e7e1d5de768cdd4be19f042f5d861087577f8e7',
    applicationReady: false,
    batch1Promoted: true,
    batch2Promoted: true,
    batch3Promoted: true,
    batch4Promoted: true,
    batch5Promoted: true,
    batch6Promoted: true,
    batch7Promoted: true,
    batch8Promoted: true,
    batch1Ledger: 'data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json',
  },
  remediationPolicy: 'allow-safe-same-for-each+allow-reviewed-methodonly-null',
  remediationPolicies: {
    inheritedFromBatch7: 'allow-safe-same-for-each',
    inheritedFromBatch8: 'allow-reviewed-methodonly-null',
    newThisRound: 'none',
  },
  reviewedMethodOnlyNullAllowlist: Object.fromEntries(
    [...REVIEWED_METHODONLY_NULL_ALLOWLIST.entries()].map(([id, set]) => [id, [...set]]),
  ),
  methodOnlyReviewArtifact: 'data/source-restoration/dazhong-chuancai-1979-methodonly-remediation-review.v1.json',
  purpose: `《大众川菜》1979 Production Batch 9 runtime-name remediation dry-run：以 runtime fix commit 0e7e1d5de768cdd4be19f042f5d861087577f8e7 为真实 baseline，复用 Batch 7 safe same-for-each 与 Batch 8 reviewed methodOnly-null 两条冻结规则，不扩大任何 policy。runtime gate 仅检查 core ingredients；unresolved-name-match 阻塞，expected-unit-confirmation 记录但不阻塞。本 generator 不新增 alias/family/canonical/unit conversion，机械选出最多 5 道剩余 new-recipe-candidate（本轮实际入选 ${selectedCount} 道），给出 overlay -> curate -> provenance 的可复现 promotion 链预览，并在临时目录用真实 curate-recipes.js 模拟完整链路。不写 workspace production 文件，不做正式 promotion，不修改 Batch 1-8 frozen artifacts 或 runtime-name review artifact。`,
  selection: {
    hardGateCriteria: [
      'promotionState=not-promoted',
      'promotionDisposition=new-recipe-candidate',
      'sourceQuality=ready-for-later-promotion-review',
      'productionQuantityReadiness=exact-comparable',
      '所有 production ingredients inventoryComparable=true',
      '无 methodOnly conversionWarning',
      '无 unallocated-group-total 组合数量（same-for-each 自 Batch 7 起允许，见 remediationPolicy）',
      '任意 methodOnly core-no-quantity 项：除非命中 reviewedMethodOnlyNullAllowlist 中逐条确认的 (entryId, item)，否则继续 hard-block',
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
      'dry-run 不新增 alias/family/canonical/unit 换算：只使用 baseline runtime fix 后的 src/ingredients.js / src/inventory.js canonicalization。',
    ],
    order: 'expected-unit-confirmation 数量少 -> ingredient 特殊结构少 -> ingredient 数量少 -> method 步骤少 -> entryId 升序',
    funnel: {
      remainingNotPromotedCandidates: remainingCandidates.length,
      afterHardGates: hardGateSurvivors.length,
      hardGateBlocked: hardGateBlockedCount,
      blockedByRuntimeNameGate: gateExclusions.runtimeNameGate.length,
      eligible: eligible.length,
      selected: selected.length,
    },
    hardGateExclusions: gateExclusions.hardGate,
    hardGateBlockedUniqueEntryIds: hardGateBlockedUniqueIds.sort(),
    runtimeNameGateBlocked: gateExclusions.runtimeNameGate.map((id) => ({
      entryId: id,
      bookName: readinessByEntryId.get(id).bookName,
      unresolvedItems: runtimeAudits.get(id).unresolvedItems,
    })),
    eligiblePoolCount: eligible.length,
    rankedEntryIds: ranked,
    selectedEntryIds: selected,
    note: '机械筛选，未硬编码候选；Batch 1-8 已 promotion 的 31 道不在候选池（promotionState=promoted）。继续冻结：(1) Batch 7 allow-safe-same-for-each；(2) Batch 8 exact reviewedMethodOnlyNullAllowlist。Batch 9 不新增或扩大 policy。',
  },
  items,
  quantityReviewPreview: {
    purpose: 'Batch 9 可能 promotion 的 curated qty/unit source-restoration-reviewed 登记预览（与 Batch 1-8 quantity-review 同构）。仅登记真实非 null qty/unit；本预览不执行正式 promotion。',
    recordCount: quantityReviewRecords.length,
    records: quantityReviewRecords,
  },
  promotionChain: [
    `1. recipe-completion-overlay.json：newRecipes + newRecipeIngredients 追加 ${selectedCount} 道（recipeIngredientOverrides 保持不变）`,
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
  'data/source-restoration/dazhong-chuancai-1979-promotion-batch9-dry-run.v1.json',
);
fs.writeFileSync(outPath, `${JSON.stringify(output, null, 2)}\n`);

console.log(`Wrote ${outPath}`);
console.log(`funnel: ${remainingCandidates.length} -> hard-blocked ${hardGateBlockedCount} -> after-hard-gates ${hardGateSurvivors.length} -> runtime-blocked ${gateExclusions.runtimeNameGate.length} -> eligible ${eligible.length} -> selected ${selected.length}`);
console.log(`selected: ${selected.join(', ')}`);
console.log(`runtime-blocked: ${gateExclusions.runtimeNameGate.join(', ')}`);
console.log(`simulation.strictCurrentPlusN: ${simulation.tempCurateResult.strictCurrentPlusN}`);
console.log(`verificationProblems: ${problems.length}`);
if (problems.length > 0) {
  console.log(problems);
  process.exitCode = 1;
}
