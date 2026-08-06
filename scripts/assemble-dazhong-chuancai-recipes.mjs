import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { isVerifiedContentMissing } from './lib/content-missing.mjs';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, '..');
const outputPath = path.join(
  repoRoot,
  'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
);
const catalogPath = path.join(
  repoRoot,
  'data/source-restoration/dazhong-chuancai-1979-catalog.v1.json',
);
const batchPlanPath = path.join(
  repoRoot,
  'data/source-restoration/dazhong-chuancai-1979-batch-plan.v1.json',
);
const nameMatchesPath = path.join(
  repoRoot,
  'data/source-restoration/dazhong-chuancai-1979-name-matches.v1.json',
);
const pilotPath = path.join(
  repoRoot,
  'data/source-restoration/dazhong-chuancai-1979-pilot.v1.json',
);

const inputBatchFiles = process.argv.slice(2).map((inputPath) => path.resolve(inputPath));
if (inputBatchFiles.length === 0) {
  throw new Error('Pass one or more primary-reviewed batch JSON files.');
}

const readJson = async (inputPath) => JSON.parse(await readFile(inputPath, 'utf8'));
const sha256 = (value) => createHash('sha256').update(value).digest('hex');

const [catalogBuffer, catalog, batchPlan, nameMatches, pilot] = await Promise.all([
  readFile(catalogPath),
  readJson(catalogPath),
  readJson(batchPlanPath),
  readJson(nameMatchesPath),
  readJson(pilotPath),
]);

let existing = null;
try {
  existing = await readJson(outputPath);
} catch (error) {
  if (error.code !== 'ENOENT') throw error;
}

const allowedQuantityKinds = new Set([
  'exact-mass',
  'exact-count',
  'range-mass',
  'range-count',
  'approximate-mass',
  'approximate-count',
  'qualitative-amount',
  'unresolved',
]);
const allowedRecognitionConfidence = new Set(['high', 'medium', 'low']);
const allowedConversionConfidence = new Set(['high', 'medium', 'low', 'unresolved']);

const catalogByEntryId = new Map(catalog.entries.map((entry) => [entry.entryId, entry]));
const matchByEntryId = new Map(nameMatches.bookMatches.map((entry) => [entry.entryId, entry]));
const batchById = new Map(batchPlan.batches.map((batch) => [batch.batchId, batch]));
const catalogIndexByEntryId = new Map(
  catalog.entries.map((entry, index) => [entry.entryId, index]),
);

const sourceRangeFor = (entryId) => {
  const index = catalogIndexByEntryId.get(entryId);
  const entry = catalog.entries[index];
  const next = catalog.entries[index + 1];
  const pdfEndPage = next ? next.pdfPage - 1 : 239;
  return {
    pdfStartPage: entry.pdfPage,
    pdfEndPage,
    bookStartPage: entry.bookPage,
    bookEndPage: pdfEndPage - 13,
  };
};

const projectMatchFor = (entryId) => {
  const match = matchByEntryId.get(entryId);
  const ids = Object.entries(match.projectIds ?? {}).map(([library, id]) => ({ library, id }));
  if (match.classification.id === 'exact_name') {
    return {
      classification: 'exact-name',
      projectName: match.projectName,
      projectIds: ids,
      candidateProjectName: null,
      reviewRequired: false,
    };
  }
  if (match.classification.id === 'clear_alias') {
    return {
      classification: 'confirmed-alias',
      projectName: match.projectName,
      projectIds: ids,
      candidateProjectName: null,
      reviewRequired: false,
    };
  }
  if (match.classification.id === 'suspected_match') {
    return {
      classification: 'probable-match-needs-review',
      projectName: null,
      projectIds: [],
      candidateProjectName: match.projectName,
      reviewRequired: true,
    };
  }
  return {
    classification: 'book-only',
    projectName: null,
    projectIds: [],
    candidateProjectName: null,
    reviewRequired: false,
  };
};

const assertString = (value, label) => {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new Error(`${label} must be a non-empty string.`);
  }
};

const validateIngredient = (ingredient, label) => {
  assertString(ingredient.rawItemText, `${label}.rawItemText`);
  assertString(ingredient.rawQuantityText, `${label}.rawQuantityText`);
  assertString(ingredient.conversionBasis, `${label}.conversionBasis`);
  const quantity = ingredient.normalizedQuantity;
  if (!quantity || !allowedQuantityKinds.has(quantity.kind)) {
    throw new Error(`${label} has an unsupported normalized quantity kind.`);
  }
  if (!ingredient.confidence
    || !allowedRecognitionConfidence.has(ingredient.confidence.recognition)
    || !allowedConversionConfidence.has(ingredient.confidence.conversion)) {
    throw new Error(`${label} has invalid confidence metadata.`);
  }

  if (quantity.kind === 'exact-mass') {
    if (!Number.isFinite(quantity.qty) || quantity.unit !== 'g') {
      throw new Error(`${label} exact mass must have a finite g quantity.`);
    }
    if (quantity.consumedQty !== undefined
      && (!Number.isFinite(quantity.consumedQty) || quantity.consumedUnit !== 'g')) {
      throw new Error(`${label} explicit consumed mass must have a finite g quantity.`);
    }
    if (quantity.consumedReferenceQty !== undefined
      || quantity.consumedQualifier !== undefined) {
      if (!Number.isFinite(quantity.consumedReferenceQty)
        || quantity.consumedUnit !== 'g'
        || typeof quantity.consumedQualifier !== 'string'
        || quantity.consumedQualifier.trim() === ''
        || quantity.consumedQty !== undefined) {
        throw new Error(`${label} approximate consumed mass must retain a reference g quantity and qualifier.`);
      }
    }
  } else if (quantity.kind === 'exact-count') {
    if (!Number.isFinite(quantity.qty) || typeof quantity.unit !== 'string') {
      throw new Error(`${label} exact count must retain a finite count and unit.`);
    }
  } else if (quantity.kind.startsWith('range-')) {
    if (quantity.qty !== null
      || !Number.isFinite(quantity.minQty)
      || !Number.isFinite(quantity.maxQty)
      || quantity.minQty > quantity.maxQty) {
      throw new Error(`${label} range must keep qty=null and finite ordered endpoints.`);
    }
  } else if (quantity.kind.startsWith('approximate-')
    || quantity.kind === 'qualitative-amount') {
    if (quantity.qty !== null) {
      throw new Error(`${label} approximate/qualitative amount must keep qty=null.`);
    }
  } else if (quantity.kind === 'unresolved') {
    if (quantity.qty !== null || quantity.unit !== null) {
      throw new Error(`${label} unresolved quantity must keep qty/unit null.`);
    }
    if (ingredient.conversionCandidate?.accepted === true) {
      throw new Error(`${label} unresolved quantity cannot accept a conversion candidate.`);
    }
  }

  if (ingredient.memberQuantityMode === 'same-for-each') {
    if (!Array.isArray(ingredient.members) || ingredient.members.length < 2) {
      throw new Error(`${label} each-member group must have at least two members.`);
    }
    if (ingredient.groupTotal !== undefined) {
      throw new Error(`${label} each-member group must not have groupTotal.`);
    }
    for (const member of ingredient.members) {
      if (member.qty !== quantity.qty || member.unit !== quantity.unit) {
        throw new Error(`${label} each-member quantity does not match normalized quantity.`);
      }
    }
  } else if (ingredient.memberQuantityMode === 'unallocated-group-total') {
    if (!Array.isArray(ingredient.members) || ingredient.members.length < 2) {
      throw new Error(`${label} group-total entry must have at least two members.`);
    }
    if (!ingredient.groupTotal) {
      throw new Error(`${label} group-total entry is missing groupTotal.`);
    }
    for (const member of ingredient.members) {
      if (member.qty !== null || member.unit !== null) {
        throw new Error(`${label} unallocated members must keep qty/unit null.`);
      }
    }
  }
};

const validateRecipe = (recipe, expectedEntryId, batchId) => {
  const catalogEntry = catalogByEntryId.get(expectedEntryId);
  if (!catalogEntry) throw new Error(`Unknown catalog entry: ${expectedEntryId}`);
  if (recipe.entryId !== expectedEntryId || recipe.batchId !== batchId) {
    throw new Error(`Recipe identity/order mismatch for ${expectedEntryId}.`);
  }
  if (recipe.bookName !== catalogEntry.bookName || recipe.category !== catalogEntry.category) {
    throw new Error(`Catalog metadata mismatch for ${expectedEntryId}.`);
  }
  const expectedSource = sourceRangeFor(expectedEntryId);
  for (const [key, value] of Object.entries(expectedSource)) {
    if (recipe.source?.[key] !== value) {
      throw new Error(`${expectedEntryId} source.${key} must be ${value}.`);
    }
  }
  if (!recipe.titleVisualCheck
    || recipe.titleVisualCheck.matchesCatalog !== true
    || !allowedRecognitionConfidence.has(recipe.titleVisualCheck.confidence)) {
    throw new Error(`${expectedEntryId} is missing a valid visual title check.`);
  }
  const contentMissingVerified = isVerifiedContentMissing(recipe);
  if (contentMissingVerified) {
    if (!Array.isArray(recipe.ingredients) || recipe.ingredients.length !== 0) {
      throw new Error(`${expectedEntryId} contentMissing recipes must have an empty ingredients array.`);
    }
    const steps = recipe.methodSummary?.steps;
    if (!Array.isArray(steps) || steps.length !== 0) {
      throw new Error(`${expectedEntryId} contentMissing recipes must have an empty method step array.`);
    }
  } else {
    if (recipe.contentMissing === true) {
      throw new Error(`${expectedEntryId} contentMissing=true requires a page-boundary uncertainty with an allowed reasonCode (scan-page-blank or source-content-missing).`);
    }
    if (!Array.isArray(recipe.ingredients) || recipe.ingredients.length === 0) {
      throw new Error(`${expectedEntryId} has no printed ingredients.`);
    }
    recipe.ingredients.forEach((ingredient, index) => (
      validateIngredient(ingredient, `${expectedEntryId}.ingredients[${index}]`)
    ));
    const steps = recipe.methodSummary?.steps;
    if (!Array.isArray(steps) || steps.length < 2 || steps.length > 6) {
      throw new Error(`${expectedEntryId} must have a 2–6 step method summary.`);
    }
    for (const [index, step] of steps.entries()) {
      if (step.order !== index + 1) {
        throw new Error(`${expectedEntryId} method step order is not contiguous.`);
      }
      assertString(step.summary, `${expectedEntryId}.methodSummary.steps[${index}].summary`);
    }
  }
  if (!contentMissingVerified || recipe.characteristicsSummary !== null) {
    assertString(recipe.characteristicsSummary, `${expectedEntryId}.characteristicsSummary`);
  }
  if (!Array.isArray(recipe.methodOnlyIngredients)
    || !Array.isArray(recipe.confirmedReadings)
    || !Array.isArray(recipe.uncertainties)) {
    throw new Error(`${expectedEntryId} method-only ingredients/confirmed readings/uncertainties must be arrays.`);
  }
  for (const key of [
    'tools',
    'containers',
    'fuels',
    'cleaningMaterials',
    'nonEdiblePackaging',
  ]) {
    if (!Array.isArray(recipe.nonIngredientMaterials?.[key])) {
      throw new Error(`${expectedEntryId}.nonIngredientMaterials.${key} must be an array.`);
    }
  }
  return {
    ...recipe,
    projectMatch: projectMatchFor(expectedEntryId),
  };
};

const replacementBatches = new Map();
for (const inputPath of inputBatchFiles) {
  const worker = await readJson(inputPath);
  const plannedBatch = batchById.get(worker.batchId);
  if (!plannedBatch) throw new Error(`Unknown batch: ${worker.batchId}`);
  if (worker.applicationReady !== false) {
    throw new Error(`${worker.batchId} must remain applicationReady=false.`);
  }
  if (worker.batchReview?.workerVisualReview !== true
    || (worker.batchReview?.primaryVisualReview !== true && !worker.batchReview?.externalVisualReview?.completed)
    || worker.batchReview?.ocrUsedAsAuthority !== false) {
    throw new Error(`${worker.batchId} requires worker and primary visual review metadata.`);
  }
  if (!Array.isArray(worker.recipes)
    || worker.recipes.length !== plannedBatch.entryIds.length) {
    throw new Error(`${worker.batchId} recipe count does not match the fixed batch plan.`);
  }
  const recipes = worker.recipes.map((recipe, index) => (
    validateRecipe(recipe, plannedBatch.entryIds[index], worker.batchId)
  ));
  replacementBatches.set(worker.batchId, {
    batchId: worker.batchId,
    recipes,
    batchReview: worker.batchReview,
  });
}

const existingBatches = new Map(
  (existing?.batchReviews ?? []).map((review) => [review.batchId, {
    batchId: review.batchId,
    batchReview: review,
    recipes: (existing.recipes ?? []).filter((recipe) => recipe.batchId === review.batchId),
  }]),
);
for (const [batchId, replacement] of replacementBatches) {
  existingBatches.set(batchId, replacement);
}

const orderedCompleted = batchPlan.batches
  .filter((batch) => existingBatches.has(batch.batchId));
for (const batch of orderedCompleted) {
  const reviewed = existingBatches.get(batch.batchId);
  if (reviewed.recipes.length !== batch.entryIds.length) {
    throw new Error(`${batch.batchId} existing recipe count no longer matches the plan.`);
  }
}

const recipes = orderedCompleted.flatMap((batch) => existingBatches.get(batch.batchId).recipes);
const batchReviews = orderedCompleted.map((batch) => ({
  batchId: batch.batchId,
  ...existingBatches.get(batch.batchId).batchReview,
}));
const completedBatchIds = orderedCompleted.map((batch) => batch.batchId);
const quantityKindCounts = Object.entries(recipes
  .flatMap((recipe) => recipe.ingredients)
  .reduce((counts, ingredient) => {
    const kind = ingredient.normalizedQuantity.kind;
    counts[kind] = (counts[kind] ?? 0) + 1;
    return counts;
  }, {}))
  .map(([kind, count]) => ({ kind, count }));

const now = new Date().toISOString();
const isComplete = recipes.length === catalog.entries.length
  && completedBatchIds.length === batchPlan.batches.length;
const output = {
  schema: 'kitchenmanager.source-restoration.recipes.v1',
  createdAt: existing?.createdAt ?? now,
  updatedAt: now,
  status: isComplete
    ? 'complete-reviewed-intermediate-only'
    : 'in-progress-reviewed-intermediate-only',
  applicationReady: false,
  purpose: 'Restore all 147 recipes from rendered pages while preserving source wording, uncertainty, and non-production boundaries.',
  source: {
    title: '大众川菜',
    edition: '1979年12月第一版',
    pdfFilename: '大众川菜 (刘建成等编) (Z-Library).pdf',
    pdfSha256: 'd7d5d62ea1585bbc1cba3f78eeda4e1ffddbae702180af5ea7fef25cd65f3c41',
    catalogSha256: sha256(catalogBuffer),
    readingMode: 'rendered-page-image',
    ocrUsedAsAuthority: false,
  },
  normalizationPolicy: pilot.normalizationPolicy,
  scope: {
    intermediateOnly: true,
    householdServingScale: false,
    productionRecipeGenerated: false,
    productionSchemaExpanded: false,
    productionPatchGenerated: false,
    cacheStampUpdated: false,
    uiChanged: false,
  },
  summary: {
    catalogEntryCount: catalog.entries.length,
    processedRecipeCount: recipes.length,
    remainingRecipeCount: catalog.entries.length - recipes.length,
    completedBatchCount: completedBatchIds.length,
    totalBatchCount: batchPlan.batches.length,
    ingredientEntryCount: recipes.flatMap((recipe) => recipe.ingredients).length,
    quantityKindCounts,
    unresolvedRecipeCount: recipes.filter((recipe) => recipe.uncertainties.length > 0).length,
  },
  completedBatchIds,
  batchReviews,
  recipes,
};

const completedById = new Map(batchReviews.map((review) => [review.batchId, review]));
const updatedBatches = batchPlan.batches.map((batch) => {
  const review = completedById.get(batch.batchId);
  if (!review) return batch;
  const batchRecipes = recipes.filter((recipe) => recipe.batchId === batch.batchId);
  return {
    ...batch,
    status: review.externalVisualReview?.completed ? 'completed-external-reviewed' : 'completed-primary-reviewed',
    processedAt: review.externalVisualReview?.completed ? (review.externalVisualReview.reviewedAt ?? now) : (review.primaryReviewedAt ?? now),
    processedEntryCount: batchRecipes.length,
    processing: {
      workerVisualReview: true,
      primaryVisualReview: !review.externalVisualReview?.completed,
      ocrUsedAsAuthority: false,
      renderedPdfPages: review.renderedPdfPages,
      ingredientEntryCount: batchRecipes.flatMap((recipe) => recipe.ingredients).length,
      unresolvedRecipeCount: batchRecipes.filter((recipe) => recipe.uncertainties.length > 0).length,
      reviewResult: review.externalVisualReview?.completed ? (review.externalVisualReview.reviewResult ?? 'completed-external-review') : (review.primaryReviewResult ?? 'completed-with-recorded-uncertainties'),
      correctionsApplied: review.correctionsApplied ?? [],
      ...(review.externalVisualReview?.completed ? { externalVisualReview: review.externalVisualReview } : {}),
    },
  };
});
const updatedPlan = {
  ...batchPlan,
  status: isComplete ? 'completed-primary-reviewed' : 'in-progress',
  constraints: {
    ...batchPlan.constraints,
    recipeBodyExtractionStarted: recipes.length > 0,
    recipeBodyExtractionCompleted: isComplete,
  },
  summary: {
    ...batchPlan.summary,
    processedRecipeCount: recipes.length,
    remainingRecipeCount: catalog.entries.length - recipes.length,
    completedBatchCount: completedBatchIds.length,
  },
  batches: updatedBatches,
};

await Promise.all([
  writeFile(outputPath, `${JSON.stringify(output, null, 2)}\n`),
  writeFile(batchPlanPath, `${JSON.stringify(updatedPlan, null, 2)}\n`),
]);

process.stdout.write(
  `Assembled ${recipes.length}/${catalog.entries.length} recipes from ${completedBatchIds.length}/${batchPlan.batches.length} reviewed batches.\n`,
);
