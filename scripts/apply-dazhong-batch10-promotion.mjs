#!/usr/bin/env node
// Applies 《大众川菜》1979 Production Batch 10 from the frozen dry-run
// artifact to the real completion overlay, then re-runs the real curation
// chain. Strictly field-for-field from the dry-run proposals. Aborts on any
// collision or baseline mismatch instead of overwriting or reselecting.

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(path.join(repoRoot, relativePath), 'utf8'),
);

const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch10-dry-run.v1.json');
const overlayPath = path.join(repoRoot, 'data', 'recipe-completion-overlay.json');
const overlay = readJson('data/recipe-completion-overlay.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');
const quantityReview = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch10-quantity-review.v1.json');
const finalReview = readJson('data/source-restoration/dazhong-chuancai-1979-final-quantity-blocker-review.v1.json');

const EXPECTED_PRODUCTION_IDS = ['dz1979-p203', 'dz1979-p201', 'dz1979-p207'];

const actualIds = dryRun.items.map((item) => item.productionId);
if (JSON.stringify(actualIds) !== JSON.stringify(EXPECTED_PRODUCTION_IDS)) {
  console.error('Frozen dry-run selection does not match the expected Batch 10 three. Aborting.');
  console.error({ expected: EXPECTED_PRODUCTION_IDS, actual: actualIds });
  process.exit(1);
}

if (dryRun.verificationProblems.length > 0) {
  console.error('Frozen dry-run reports verification problems. Aborting.');
  console.error(dryRun.verificationProblems);
  process.exit(1);
}

if (curated.recipes.length !== 159) {
  console.error(`Expected pre-promotion curated count 159, found ${curated.recipes.length}. Aborting.`);
  process.exit(1);
}

if (quantityReview.records.length !== 22
  || JSON.stringify(quantityReview.summary.unitCounts) !== JSON.stringify({ g: 19, '根': 3 })
  || quantityReview.records.some((record) => record.item === '花椒')
  || quantityReview.verificationProblems.length > 0) {
  console.error('Frozen Batch 10 quantity review does not match 22 records (19g + 3根). Aborting.');
  process.exit(1);
}

const expectedAllowlist = {
  'dz1979-p201': ['花椒'],
  'dz1979-p203': ['花椒'],
  'dz1979-p207': ['花椒'],
};
if (finalReview.safeToAllow !== true
  || finalReview.verificationProblems.length > 0
  || JSON.stringify(finalReview.reviewedNonExactNullAllowlist) !== JSON.stringify(expectedAllowlist)
  || JSON.stringify(dryRun.reviewedNonExactNullAllowlist) !== JSON.stringify(expectedAllowlist)) {
  console.error('Final quantity review or exact non-exact-null allowlist mismatch. Aborting.');
  process.exit(1);
}
const nullIngredients = dryRun.items.flatMap((item) => (
  item.proposedOverlayIngredients[item.productionId]
    .filter((ingredient) => ingredient.qty === null || ingredient.unit === null)
    .map((ingredient) => [item.entryId, ingredient])
));
if (nullIngredients.length !== 3 || nullIngredients.some(([entryId, ingredient]) => (
  ingredient.item !== '花椒'
  || ingredient.qty !== null
  || ingredient.unit !== null
  || !expectedAllowlist[entryId]?.includes(ingredient.item)
))) {
  console.error('Frozen Batch 10 null ingredient set is not exactly the three reviewed 花椒 entries. Aborting.');
  process.exit(1);
}

const batchRecipes = dryRun.items.map((item) => item.proposedOverlayRecipe);
const batchIngredients = Object.fromEntries(
  dryRun.items.map((item) => [
    item.productionId,
    item.proposedOverlayIngredients[item.productionId],
  ]),
);

const existingNames = new Set([
  ...curated.recipes.map((r) => r.name),
  ...full.recipes.map((r) => r.name),
  ...(overlay.newRecipes ?? []).map((r) => r.name),
]);
const existingIds = new Set([
  ...curated.recipes.map((r) => r.id),
  ...full.recipes.map((r) => r.id),
  ...(overlay.newRecipes ?? []).map((r) => r.id),
]);

const problems = [];
for (const recipe of batchRecipes) {
  if (existingIds.has(recipe.id)) problems.push(`id collision: ${recipe.id}`);
  if (existingNames.has(recipe.name)) problems.push(`name collision: ${recipe.name}`);
}
if (problems.length > 0) {
  console.error('Collision detected, aborting promotion.');
  console.error(problems);
  process.exit(1);
}

const nextOverlay = {
  ...overlay,
  newRecipes: [...(overlay.newRecipes ?? []), ...batchRecipes],
  newRecipeIngredients: {
    ...(overlay.newRecipeIngredients ?? {}),
    ...batchIngredients,
  },
};
fs.writeFileSync(overlayPath, `${JSON.stringify(nextOverlay, null, 2)}\n`);

execFileSync('node', [path.join(repoRoot, 'scripts', 'curate-recipes.js')], {
  cwd: repoRoot,
  stdio: 'pipe',
});

const afterCurated = readJson('data/sichuan-recipes.curated.json');
const addedIds = afterCurated.recipes
  .map((r) => r.id)
  .filter((id) => !curated.recipes.some((r) => r.id === id));

if (afterCurated.recipes.length !== 162
  || JSON.stringify([...addedIds].sort()) !== JSON.stringify([...EXPECTED_PRODUCTION_IDS].sort())) {
  console.error('Post-promotion curated delta is not exactly the frozen Batch 10 three. Aborting.');
  process.exit(1);
}

console.log(`Promoted ${batchRecipes.length} recipes.`);
console.log(`curated ${curated.recipes.length} -> ${afterCurated.recipes.length}`);
console.log(`added ids: ${addedIds.join(', ')}`);
