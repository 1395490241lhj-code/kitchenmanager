#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { recipeIdDigest } from './recipe-runtime-quality.mjs';
import { assertValidRecipeQuantitySemantics } from './recipe-quantity-semantics.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BASELINE = '0116009dfd35f1fde3eeedcee9bae1771d8db965';
const PRE_PROMOTION_BASELINE = '7ad674d548f2d4749e183383a668f63461150842';
const OUT_JSON = 'data/source-restoration/dazhong-chuancai-1979-closeout-audit.v1.json';
const OUT_MD = 'data/source-restoration/dazhong-chuancai-1979-closeout-audit.v1.md';
const readJson = (file) => JSON.parse(fs.readFileSync(path.join(repoRoot, file), 'utf8'));
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const sorted = (values) => [...values].sort();

const catalog = readJson('data/source-restoration/dazhong-chuancai-1979-catalog.v1.json');
const canonical = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');
const crosswalk = readJson('data/source-restoration/dazhong-chuancai-1979-crosswalk-dry-run.v1.json');
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');
const ledger = readJson('data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');
const overlay = readJson('data/recipe-completion-overlay.json');
const removed = readJson('data/recipe-curation-removed.json');
const needing = readJson('data/recipes-needing-completion.json');
const runtimeBaseline = readJson('data/recipe-runtime-baseline.json');
const sidecar = readJson('data/recipe-quantity-semantics.json');
const methodOnlyReview = readJson('data/source-restoration/dazhong-chuancai-1979-methodonly-remediation-review.v1.json');
const finalQuantityReview = readJson('data/source-restoration/dazhong-chuancai-1979-final-quantity-blocker-review.v1.json');

const problems = [];
const fail = (condition, code) => { if (!condition) problems.push(code); };
const unique = (values, code) => fail(new Set(values).size === values.length, code);
const equalSet = (left, right, code) => fail(same(sorted(left), sorted(right)), code);
const catalogIds = catalog.entries.map((entry) => entry.entryId);
const canonicalIds = canonical.recipes.map((entry) => entry.entryId);
const crosswalkIds = crosswalk.entries.map((entry) => entry.entryId);
const readinessIds = readiness.entries.map((entry) => entry.entryId);
for (const [label, ids] of Object.entries({ catalog: catalogIds, canonical: canonicalIds, crosswalk: crosswalkIds, readiness: readinessIds })) {
  fail(ids.length === 147, `${label}-count-not-147`);
  unique(ids, `${label}-duplicate-entry-id`);
  equalSet(ids, catalogIds, `${label}-entry-set-mismatch`);
}

const matrixDefinitions = [
  ['existing-project-match', (entry) => entry.promotionDisposition === 'existing-project-match', 50],
  ['promoted-new-recipe-candidate', (entry) => entry.promotionDisposition === 'new-recipe-candidate' && entry.promotionState === 'promoted', 39],
  ['blocked-source-review', (entry) => entry.promotionDisposition === 'blocked-source-review', 45],
  ['blocked-alternate-source', (entry) => entry.promotionDisposition === 'blocked-alternate-source', 12],
  ['blocked-crosswalk', (entry) => entry.promotionDisposition === 'blocked-crosswalk', 1],
];
const accountingMatrix = matrixDefinitions.map(([status, predicate, expectedCount]) => {
  const entryIds = readiness.entries.filter(predicate).map((entry) => entry.entryId).sort();
  fail(entryIds.length === expectedCount, `accounting-${status}:${entryIds.length}`);
  return { status, count: entryIds.length, entryIds };
});
const accountedIds = accountingMatrix.flatMap((row) => row.entryIds);
fail(accountedIds.length === 147, `accounting-total:${accountedIds.length}`);
unique(accountedIds, 'accounting-duplicate-entry-id');
equalSet(accountedIds, catalogIds, 'accounting-entry-set-mismatch');

const canonicalById = new Map(canonical.recipes.map((entry) => [entry.entryId, entry]));
const crosswalkById = new Map(crosswalk.entries.map((entry) => [entry.entryId, entry]));
const readinessById = new Map(readiness.entries.map((entry) => [entry.entryId, entry]));
const catalogById = new Map(catalog.entries.map((entry) => [entry.entryId, entry]));
for (const entryId of catalogIds) {
  const source = canonicalById.get(entryId);
  const walk = crosswalkById.get(entryId);
  const ready = readinessById.get(entryId);
  const index = catalogById.get(entryId);
  fail(source?.bookName === index.bookName && ready?.bookName === index.bookName, `book-name-mismatch:${entryId}`);
  fail(source?.category === index.category && ready?.category === index.category, `category-mismatch:${entryId}`);
  fail(ready?.classification === walk?.proposedClassification, `classification-mismatch:${entryId}`);
  fail(ready?.sourceQuality === walk?.sourceQuality, `source-quality-mismatch:${entryId}`);
  fail(same(ready?.projectIds, walk?.projectIds), `project-ids-mismatch:${entryId}`);
  fail(same(source?.projectMatch, walk?.sourceProjectMatchBefore), `canonical-crosswalk-mismatch:${entryId}`);
}

const gitLog = execFileSync('git', ['log', '--all', '--format=%H\t%s'], { cwd: repoRoot, encoding: 'utf8' })
  .trim().split('\n').map((line) => line.split('\t'));
const ledgerEntries = ledger.batches.flatMap((batch) => batch.entries ?? []);
const ledgerEntryIds = ledgerEntries.map((entry) => entry.entryId);
const ledgerProductionIds = ledgerEntries.map((entry) => entry.productionId);
const ledgerNames = ledgerEntries.map((entry) => entry.name);
fail(ledger.batches.length === 11, `ledger-batch-count:${ledger.batches.length}`);
fail(ledgerEntries.length === 39, `ledger-entry-count:${ledgerEntries.length}`);
unique(ledgerEntryIds, 'ledger-duplicate-entry-id');
unique(ledgerProductionIds, 'ledger-duplicate-production-id');
unique(ledgerNames, 'ledger-duplicate-name');
equalSet(ledgerEntryIds, accountingMatrix.find((row) => row.status === 'promoted-new-recipe-candidate').entryIds, 'ledger-promoted-set-mismatch');

let previousPromotionCommit = null;
let frozenBatch11Sidecar = null;
const quantityRecords = [];
const promotionBatches = ledger.batches.map((batch, index) => {
  const number = index + 1;
  const expectedBatchId = `dz1979-production-b${String(number).padStart(2, '0')}`;
  const promotionCommit = gitLog.find(([, subject]) => subject === `data: promote dazhong batch ${number} recipes`)?.[0] ?? null;
  let baselineExists = true;
  let baselineAncestorOfPromotion = true;
  let previousPromotionAncestorOfBaseline = true;
  let dryRunBaselineAncestorOfLedgerBaseline = true;
  try { execFileSync('git', ['cat-file', '-e', `${batch.baselineCommit}^{commit}`], { cwd: repoRoot }); } catch { baselineExists = false; }
  try { execFileSync('git', ['merge-base', '--is-ancestor', batch.baselineCommit, promotionCommit], { cwd: repoRoot }); } catch { baselineAncestorOfPromotion = false; }
  if (previousPromotionCommit) {
    try { execFileSync('git', ['merge-base', '--is-ancestor', previousPromotionCommit, batch.baselineCommit], { cwd: repoRoot }); } catch { previousPromotionAncestorOfBaseline = false; }
  }
  const dryRun = readJson(batch.dryRunArtifact);
  const quantityReview = readJson(batch.quantityReviewArtifact);
  const entryIds = batch.entries.map((entry) => entry.entryId);
  const dryRunIds = (dryRun.items ?? []).map((entry) => entry.entryId);
  const dryRunBaselineCommit = dryRun.baseline?.main ?? null;
  const batchQuantityRecords = quantityReview.records ?? [];
  quantityRecords.push(...batchQuantityRecords);
  fail(batch.batchId === expectedBatchId, `batch-id-order:${batch.batchId}`);
  fail(batch.status === 'promoted', `batch-status:${batch.batchId}`);
  fail(Boolean(promotionCommit), `promotion-commit-missing:${batch.batchId}`);
  fail(baselineExists && baselineAncestorOfPromotion && previousPromotionAncestorOfBaseline, `baseline-chain:${batch.batchId}`);
  try { execFileSync('git', ['merge-base', '--is-ancestor', dryRunBaselineCommit, batch.baselineCommit], { cwd: repoRoot }); } catch { dryRunBaselineAncestorOfLedgerBaseline = false; }
  fail(dryRunBaselineAncestorOfLedgerBaseline, `dry-run-ledger-baseline-chain:${batch.batchId}`);
  fail(same(entryIds, dryRunIds), `dry-run-entry-order:${batch.batchId}`);
  fail((dryRun.verificationProblems ?? []).length === 0, `dry-run-problems:${batch.batchId}`);
  fail((quantityReview.verificationProblems ?? []).length === 0, `quantity-review-problems:${batch.batchId}`);
  for (const entry of batch.entries) {
    const item = dryRun.items.find((candidate) => candidate.entryId === entry.entryId);
    const ready = readinessById.get(entry.entryId);
    const expectedProvenance = {
      entryId: item?.provenanceRecord?.entryId,
      bookName: ready?.bookName,
      bookPage: item?.provenanceRecord?.bookPage,
      pdfPage: item?.provenanceRecord?.pdfPage,
      category: ready?.category,
      sourceFile: item?.provenanceRecord?.sourceFile,
    };
    fail(Boolean(item), `dry-run-item-missing:${entry.entryId}`);
    fail(same(curated.recipes.find((recipe) => recipe.id === entry.productionId), item?.proposedCuratedRecipe), `curated-frozen-recipe:${entry.entryId}`);
    fail(same(curated.recipe_ingredients[entry.productionId], item?.proposedCuratedIngredients?.[entry.productionId]), `curated-frozen-map:${entry.entryId}`);
    fail(same(overlay.newRecipes.find((recipe) => recipe.id === entry.productionId), item?.proposedOverlayRecipe), `overlay-frozen-recipe:${entry.entryId}`);
    fail(same(overlay.newRecipeIngredients?.[entry.productionId], item?.proposedOverlayIngredients?.[entry.productionId]), `overlay-frozen-map:${entry.entryId}`);
    fail(same(entry.provenanceRecord, expectedProvenance), `ledger-provenance-projection:${entry.entryId}`);
  }
  if (batch.batchId === 'dz1979-production-b11') frozenBatch11Sidecar = dryRun.proposedQuantitySemanticsSidecar;
  previousPromotionCommit = promotionCommit;
  return {
    batchId: batch.batchId,
    baselineCommit: batch.baselineCommit,
    dryRunBaselineCommit,
    promotionCommit,
    dryRunArtifact: batch.dryRunArtifact,
    quantityReviewArtifact: batch.quantityReviewArtifact,
    entryCount: entryIds.length,
    entryIds,
    quantityReviewRecordCount: batchQuantityRecords.length,
    quantityReviewUnitCounts: quantityReview.summary?.unitCounts ?? {},
    baselineExists,
    baselineAncestorOfPromotion,
    previousPromotionAncestorOfBaseline,
    dryRunBaselineAncestorOfLedgerBaseline,
  };
});

const curatedIdCounts = new Map();
const curatedNameCounts = new Map();
for (const recipe of curated.recipes) {
  curatedIdCounts.set(recipe.id, (curatedIdCounts.get(recipe.id) ?? 0) + 1);
  curatedNameCounts.set(recipe.name, (curatedNameCounts.get(recipe.name) ?? 0) + 1);
}
const overlayIdCounts = new Map();
const overlayNameCounts = new Map();
for (const recipe of overlay.newRecipes ?? []) {
  overlayIdCounts.set(recipe.id, (overlayIdCounts.get(recipe.id) ?? 0) + 1);
  overlayNameCounts.set(recipe.name, (overlayNameCounts.get(recipe.name) ?? 0) + 1);
}
for (const entry of ledgerEntries) {
  const ready = readinessById.get(entry.entryId);
  fail(entry.productionId === entry.entryId, `production-id-mismatch:${entry.entryId}`);
  fail(entry.name === ready.bookName && entry.sourceQuality === ready.sourceQuality && entry.originalClassification === ready.classification, `ledger-provenance-mismatch:${entry.entryId}`);
  fail(curatedIdCounts.get(entry.productionId) === 1 && curatedNameCounts.get(entry.name) === 1, `curated-identity:${entry.entryId}`);
  fail(overlayIdCounts.get(entry.productionId) === 1 && overlayNameCounts.get(entry.name) === 1, `overlay-identity:${entry.entryId}`);
  fail(Array.isArray(curated.recipe_ingredients[entry.productionId]), `curated-map-missing:${entry.entryId}`);
  fail(Array.isArray(overlay.newRecipeIngredients?.[entry.productionId]), `overlay-map-missing:${entry.entryId}`);
}

const ledgerEntrySet = new Set(ledgerEntryIds);
const existingMatches = readiness.entries.filter((entry) => entry.promotionDisposition === 'existing-project-match');
const blockedEntries = readiness.entries.filter((entry) => entry.promotionDisposition.startsWith('blocked-'));
for (const entry of existingMatches) {
  fail(!ledgerEntrySet.has(entry.entryId), `existing-match-in-ledger:${entry.entryId}`);
  fail(!curatedIdCounts.has(entry.proposedIdStrategy ?? entry.entryId) && !overlayIdCounts.has(entry.entryId), `existing-match-duplicated:${entry.entryId}`);
}
for (const entry of blockedEntries) fail(!ledgerEntrySet.has(entry.entryId) && entry.promotionState === 'not-promoted', `blocked-promoted:${entry.entryId}`);

const methodOnlyNullKeys = methodOnlyReview.items.flatMap((recipe) => recipe.items.flatMap((item) => (
  item.splitItems.map((split) => `${recipe.entryId}:${split.item}`)
)));
const reviewedNonExactNullKeys = Object.entries(finalQuantityReview.reviewedNonExactNullAllowlist)
  .flatMap(([entryId, items]) => items.map((item) => `${entryId}:${item}`));
const approvedNullKeys = new Set([...methodOnlyNullKeys, ...reviewedNonExactNullKeys]);
const quantityByKey = new Map(quantityRecords.map((record) => [`${record.productionId}:${record.item}`, record]));
unique(quantityRecords.map((record) => `${record.productionId}:${record.item}`), 'quantity-review-duplicate-key');
fail(quantityRecords.length === 294, `quantity-review-record-count:${quantityRecords.length}`);
const actualNullRows = [];
for (const entry of ledgerEntries) {
  for (const ingredient of curated.recipe_ingredients[entry.productionId] ?? []) {
    const key = `${entry.productionId}:${ingredient.item}`;
    fail(!Object.keys(ingredient).some((field) => field.startsWith('consumed')), `consumed-in-base:${key}`);
    if (ingredient.qty === null || ingredient.unit === null) {
      actualNullRows.push({ productionId: entry.productionId, item: ingredient.item, qty: ingredient.qty, unit: ingredient.unit });
      fail(ingredient.qty === null && ingredient.unit === null && approvedNullKeys.has(key), `unapproved-null:${key}`);
    } else {
      const record = quantityByKey.get(key);
      fail(Boolean(record) && Number(record.qty) === Number(ingredient.qty) && record.unit === ingredient.unit, `quantity-review-mismatch:${key}`);
    }
  }
}
equalSet(actualNullRows.map((row) => `${row.productionId}:${row.item}`), approvedNullKeys, 'approved-null-set-mismatch');
fail(!JSON.stringify(quantityRecords).includes('consumed'), 'consumed-in-quantity-review');

const sidecarValidation = assertValidRecipeQuantitySemantics(sidecar, curated);
const sidecarRows = Object.entries(sidecar.recipes).flatMap(([recipeId, recipe]) => (
  Object.entries(recipe.ingredients).map(([item, semantics]) => ({ recipeId, item, input: semantics.input, consumed: semantics.consumed }))
));
fail(Object.keys(sidecar.recipes).length === 3, `sidecar-recipe-count:${Object.keys(sidecar.recipes).length}`);
fail(sidecarRows.length === 4 && sidecarValidation.joins.length === 4, `sidecar-record-count:${sidecarRows.length}`);
fail(same(sidecar, frozenBatch11Sidecar), 'sidecar-frozen-batch11-mismatch');

const runtimeFiles = ['app.js'];
const walk = (dir) => {
  for (const name of fs.readdirSync(path.join(repoRoot, dir))) {
    const relative = path.join(dir, name);
    const stat = fs.statSync(path.join(repoRoot, relative));
    if (stat.isDirectory()) walk(relative);
    else if (/\.(?:js|mjs|swift)$/.test(name)) runtimeFiles.push(relative);
  }
};
walk('src');
walk('ios-native');
const sidecarConsumerReferences = runtimeFiles.filter((file) => /recipe-quantity-semantics|quantity_semantics|quantitySemantics/.test(fs.readFileSync(path.join(repoRoot, file), 'utf8')));
fail(sidecarConsumerReferences.length === 0, `runtime-sidecar-dependency:${sidecarConsumerReferences.join(',')}`);

const protectedBaselineFiles = [
  'data/sichuan-recipes.json',
  'data/recipe-completion-overlay.json',
  'data/sichuan-recipes.curated.json',
  'data/recipe-curation-removed.json',
  'data/recipes-needing-completion.json',
  'data/recipe-runtime-baseline.json',
  'data/recipe-quantity-semantics.json',
  'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
  'data/source-restoration/dazhong-chuancai-1979-crosswalk-dry-run.v1.json',
  'data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json',
  'data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json',
];
const baselineIntegrity = protectedBaselineFiles.map((file) => {
  const baselineBytes = execFileSync('git', ['show', `${BASELINE}:${file}`], { cwd: repoRoot, maxBuffer: 32 * 1024 * 1024 });
  const byteEqual = fs.readFileSync(path.join(repoRoot, file)).equals(baselineBytes);
  fail(byteEqual, `baseline-byte-drift:${file}`);
  return { file, byteEqual };
});
const prePromotionJson = (file) => JSON.parse(execFileSync('git', ['show', `${PRE_PROMOTION_BASELINE}:${file}`], { cwd: repoRoot, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 }));
const prePromotionCurated = prePromotionJson('data/sichuan-recipes.curated.json');
const prePromotionOverlay = prePromotionJson('data/recipe-completion-overlay.json');
for (const recipe of prePromotionCurated.recipes) {
  fail(same(curated.recipes.find((entry) => entry.id === recipe.id), recipe), `pre-promotion-curated-recipe-drift:${recipe.id}`);
  fail(same(curated.recipe_ingredients[recipe.id], prePromotionCurated.recipe_ingredients[recipe.id]), `pre-promotion-curated-map-drift:${recipe.id}`);
}
for (const recipe of prePromotionOverlay.newRecipes ?? []) {
  fail(same(overlay.newRecipes.find((entry) => entry.id === recipe.id), recipe), `pre-promotion-overlay-recipe-drift:${recipe.id}`);
  fail(same(overlay.newRecipeIngredients?.[recipe.id], prePromotionOverlay.newRecipeIngredients?.[recipe.id]), `pre-promotion-overlay-map-drift:${recipe.id}`);
}
const prePromotionStableFiles = ['data/sichuan-recipes.json', 'data/recipe-curation-removed.json', 'data/recipes-needing-completion.json'].map((file) => {
  const byteEqual = fs.readFileSync(path.join(repoRoot, file)).equals(execFileSync('git', ['show', `${PRE_PROMOTION_BASELINE}:${file}`], { cwd: repoRoot, maxBuffer: 32 * 1024 * 1024 }));
  fail(byteEqual, `pre-promotion-byte-drift:${file}`);
  return { file, byteEqual };
});
fail(curated.recipes.length - prePromotionCurated.recipes.length === 39, 'curated-not-exact-plus-39');
fail((overlay.newRecipes ?? []).length - (prePromotionOverlay.newRecipes ?? []).length === 39, 'overlay-not-exact-plus-39');
fail(full.recipes.length === 264, `full-count:${full.recipes.length}`);
fail(removed.removed.length === 204, `removed-count:${removed.removed.length}`);
fail(needing.items.length === 13, `needing-count:${needing.items.length}`);
fail(runtimeBaseline.sources.curated.count === 165 && runtimeBaseline.sources.curated.idSha256 === recipeIdDigest(curated), 'runtime-curated-baseline-mismatch');
fail(runtimeBaseline.sources.full.count === 264 && runtimeBaseline.sources.full.idSha256 === recipeIdDigest(full), 'runtime-full-baseline-mismatch');

const sourceReviewEntries = readiness.entries.filter((entry) => entry.promotionDisposition === 'blocked-source-review');
const alternateEntries = readiness.entries.filter((entry) => entry.promotionDisposition === 'blocked-alternate-source');
const crosswalkEntries = readiness.entries.filter((entry) => entry.promotionDisposition === 'blocked-crosswalk');
const alternateContentMissingCount = alternateEntries.filter((entry) => canonicalById.get(entry.entryId).contentMissing === true).length;
const alternateContentIncompleteCount = alternateEntries.filter((entry) => canonicalById.get(entry.entryId).contentIncomplete === true).length;
const unresolvedSourceLimitations = {
  totalCount: blockedEntries.length,
  blockedSourceReview: {
    count: sourceReviewEntries.length,
    entryIds: sourceReviewEntries.map((entry) => entry.entryId),
    entriesWithRecordedUncertainty: sourceReviewEntries.filter((entry) => (canonicalById.get(entry.entryId).uncertainties ?? []).length > 0).length,
    finalMeaning: 'Current canonical extraction is preserved, but source-fidelity uncertainty remains. This is an accepted closeout disposition for the current scan, not approval for production; targeted source review is required before any future promotion.',
  },
  blockedAlternateSource: {
    count: alternateEntries.length,
    entryIds: alternateEntries.map((entry) => entry.entryId),
    contentMissingCount: alternateContentMissingCount,
    contentIncompleteCount: alternateContentIncompleteCount,
    otherSourceGapCount: alternateEntries.length - alternateContentMissingCount - alternateContentIncompleteCount,
    finalMeaning: 'The current scan cannot supply all required source content. Its visible evidence is fully preserved; another edition, copy, or primary source is required before reconsideration.',
  },
  blockedCrosswalk: {
    count: crosswalkEntries.length,
    entryIds: crosswalkEntries.map((entry) => entry.entryId),
    finalMeaning: 'Source extraction is usable, but the probable project mapping remains unadjudicated. Keep blocked until the p173 crosswalk decision is resolved.',
  },
};
fail(unresolvedSourceLimitations.totalCount === 58, `unresolved-total:${unresolvedSourceLimitations.totalCount}`);

const statusFieldAudit = {
  ledgerPartialPromotion: {
    value: ledger.partialPromotion,
    stale: false,
    meaning: 'The ledger records only the 39 source-restoration-created recipes, a selective subset of the 147-entry corpus; it is not the remaining-candidate counter.',
  },
  readinessProductionPromotion: {
    value: readiness.productionPromotion,
    stale: false,
    meaning: 'This flag describes the readiness artifact generator as non-promoting/read-only; the separate ledger is the authority for completed production promotions.',
  },
  readinessSchemaExtensionNeeded: {
    value: readiness.summary.schemaExtensionNeeded,
    stale: false,
    meaning: 'The existing base recipe shape required no extension. Dual consumed quantities live in the separate sidecar contract and are not loaded by current consumers.',
  },
  readinessApplicationReady: {
    value: readiness.applicationReady,
    stale: false,
    meaning: 'Zero remaining promotion candidates does not make source-equivalent quantities, unresolved source limitations, or the intermediate restoration pack application-ready.',
  },
  restorationApplicationReady: {
    value: canonical.applicationReady,
    stale: false,
    meaning: 'Canonical restoration remains intermediate-only source evidence, not a serving-scaled application data pack.',
  },
};
fail(ledger.partialPromotion === true, 'ledger-partial-promotion-value');
fail(readiness.productionPromotion === false, 'readiness-production-promotion-value');
fail(readiness.summary.schemaExtensionNeeded === false, 'readiness-schema-extension-value');
fail(readiness.applicationReady === false && canonical.applicationReady === false, 'application-ready-value');

if (problems.length) {
  console.error(`Closeout audit aborted: ${problems.join(', ')}`);
  process.exit(1);
}

const output = {
  schema: 'kitchenmanager.source-restoration.closeout-audit.v1',
  generatedAt: '2026-08-09',
  generator: 'scripts/build-dazhong-chuancai-closeout-audit.mjs',
  baseline: { commit: BASELINE, sourceEntryCount: 147, curatedCount: 165, promotedCandidateCount: 39, remainingPromotionCandidateCount: 0 },
  accounting: { totalEntries: 147, matrix: accountingMatrix, uniqueAndComplete: true },
  promotionSummary: {
    batchCount: promotionBatches.length,
    promotedRecipeCount: ledgerEntries.length,
    batches: promotionBatches,
    baselineChainValid: promotionBatches.every((batch) => batch.baselineExists && batch.baselineAncestorOfPromotion && batch.previousPromotionAncestorOfBaseline && batch.dryRunBaselineAncestorOfLedgerBaseline),
  },
  productionIntegrity: {
    curatedCount: curated.recipes.length,
    fullCount: full.recipes.length,
    promotedIdsUnique: new Set(ledgerProductionIds).size === ledgerProductionIds.length,
    promotedNamesUnique: new Set(ledgerNames).size === ledgerNames.length,
    promotedPresentExactlyOnceInCuratedAndOverlay: true,
    existingProjectMatchesNotDuplicated: true,
    blockedEntriesAbsentFromLedger: true,
    runtimeBaselineMatches: true,
    fullRemovedNeedingStable: true,
    prePromotionBaseline: PRE_PROMOTION_BASELINE,
    prePromotionCuratedCount: prePromotionCurated.recipes.length,
    prePromotionOverlayNewRecipeCount: prePromotionOverlay.newRecipes.length,
    existingPrePromotionRecipesAndMapsUnchanged: true,
    exactPromotedDelta: 39,
    prePromotionStableFiles,
    baselineIntegrity,
  },
  quantityPolicy: {
    sourceRestorationReviewedRecordCount: quantityRecords.length,
    promotedIngredientRowCount: ledgerEntries.flatMap((entry) => curated.recipe_ingredients[entry.productionId] ?? []).length,
    reviewedKeysUnique: true,
    baseQtyUnitMatchesReviewedRecords: true,
    approvedNullRule: 'Only exact entryId+item pairs from the frozen methodOnly and final non-exact quantity reviews may use qty=null/unit=null.',
    approvedNullRows: actualNullRows,
    approvedNullCount: actualNullRows.length,
    consumedFieldsAbsentFromBaseAndQuantityReview: true,
  },
  sidecarSummary: {
    schema: sidecar.schema,
    recipeCount: Object.keys(sidecar.recipes).length,
    dualRecordCount: sidecarRows.length,
    joins: sidecarRows,
    inputMatchesBaseQtyUnit: true,
    identity: 'recipeId + exact production item; array index forbidden',
    currentPwaIosConsumersLoadSidecar: false,
    consumerReferenceFiles: sidecarConsumerReferences,
  },
  unresolvedSourceLimitations,
  historicalArtifactFields: [
    { field: 'promotion dry-run baseline.curated/promoted/remaining/applicationReady', meaning: 'Point-in-time pre-promotion snapshot; frozen evidence, not current state.' },
    { field: 'promotion dry-run productionWrites=false', meaning: 'The dry-run generator did not write production; it does not claim the proposal was never later promoted.' },
    { field: 'quantity-review applicationReady=false', meaning: 'The frozen review artifact itself is non-production evidence.' },
    { field: 'readiness productionPromotion=false', meaning: 'Generator behavior flag; current promotion truth comes from the ledger.' },
    { field: 'historical review production invariants and remaining counts', meaning: 'Review-time snapshots must remain frozen after later batches.' },
  ],
  finalStatusDefinitions: {
    promotionComplete: 'All 39/39 source-ready new-recipe-candidates are recorded in the ledger and production.',
    sourceRestorationComplete: 'All 147 catalog entries are extracted/accounted for and have a final explainable disposition for the current scanned-source scope; blocked limitations may remain.',
    applicationReady: 'The restoration dataset itself is safe for direct application consumption with serving/runtime semantics.',
  },
  promotionComplete: true,
  sourceRestorationComplete: true,
  applicationReady: false,
  statusFieldAudit,
  remainingFollowUps: [
    { category: 'blocked-source-review', count: 45, requirement: 'Resolve recorded recognition/conversion/allocation/old-term source-fidelity issues before reconsidering individual entries.' },
    { category: 'blocked-alternate-source', count: 12, requirement: 'Obtain another authoritative source for missing, incomplete, or otherwise unavailable content.' },
    { category: 'blocked-crosswalk', count: 1, requirement: 'Adjudicate dz1979-p173 probable mapping before any promotion decision.' },
  ],
  verificationProblems: problems,
};

const markdown = `# 《大众川菜》1979 source-restoration closeout audit

Baseline: \`${BASELINE}\`

## Final status

- promotionComplete: **${output.promotionComplete}** — 39/39 new-recipe-candidates promoted.
- sourceRestorationComplete: **${output.sourceRestorationComplete}** — all 147 entries are accounted for with an explainable disposition for the current scanned-source scope.
- applicationReady: **${output.applicationReady}** — source-equivalent/intermediate data and 58 unresolved source limitations are not direct App readiness.

## Accounting

| Disposition | Count |
| --- | ---: |
${accountingMatrix.map((row) => `| ${row.status} | ${row.count} |`).join('\n')}
| **Total** | **147** |

## Production and quantity integrity

- Batch1–11 baseline chain: ${output.promotionSummary.baselineChainValid ? 'valid' : 'invalid'}.
- Curated: ${curated.recipes.length}; promoted IDs/names unique: 39/39; Full: ${full.recipes.length}.
- Reviewed source quantity records: ${quantityRecords.length}; approved narrow null rows: ${actualNullRows.length}.
- Quantity sidecar: ${Object.keys(sidecar.recipes).length} recipes / ${sidecarRows.length} dual records; input matches base; consumed stays sidecar-only.
- Current PWA/iOS sidecar dependencies: none.

## Unresolved source limitations

- blocked-source-review: 45. Current scan evidence is preserved; targeted source-fidelity review is required before promotion.
- blocked-alternate-source: 12 (${alternateContentMissingCount} contentMissing, ${alternateContentIncompleteCount} contentIncomplete, ${alternateEntries.length - alternateContentMissingCount - alternateContentIncompleteCount} other source gaps). Another authoritative source is required.
- blocked-crosswalk: 1 (dz1979-p173). Mapping adjudication remains required.

These 58 are accepted final **closeout dispositions for the current scanned-source scope**, not production approval. They remain explicit follow-ups.

## State fields

- ledger.partialPromotion=true remains a selective-corpus marker, not a remaining-candidate counter.
- readiness.productionPromotion=false remains a read-only generator flag.
- readiness.schemaExtensionNeeded=false remains correct: base consumers did not change; dual semantics use a separate sidecar.
- readiness/restoration applicationReady=false remains correct.

Verification problems: **${problems.length}**.
`;

fs.writeFileSync(path.join(repoRoot, OUT_JSON), `${JSON.stringify(output, null, 2)}\n`);
fs.writeFileSync(path.join(repoRoot, OUT_MD), markdown);
console.log(`Wrote ${OUT_JSON} and ${OUT_MD}; verificationProblems=${problems.length}`);
if (problems.length) process.exitCode = 1;
