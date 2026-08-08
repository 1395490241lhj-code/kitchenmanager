#!/usr/bin/env node
// Applies 《大众川菜》1979 Production Batch 6 from the frozen dry-run
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

const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch6-dry-run.v1.json');
const overlayPath = path.join(repoRoot, 'data', 'recipe-completion-overlay.json');
const overlay = readJson('data/recipe-completion-overlay.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');

const EXPECTED_PRODUCTION_IDS = ['dz1979-p159', 'dz1979-p168'];

const actualIds = dryRun.items.map((item) => item.productionId);
if (JSON.stringify(actualIds) !== JSON.stringify(EXPECTED_PRODUCTION_IDS)) {
  console.error('Frozen dry-run selection does not match the expected Batch 6 five. Aborting.');
  console.error({ expected: EXPECTED_PRODUCTION_IDS, actual: actualIds });
  process.exit(1);
}

if (dryRun.verificationProblems.length > 0) {
  console.error('Frozen dry-run reports verification problems. Aborting.');
  console.error(dryRun.verificationProblems);
  process.exit(1);
}

if (curated.recipes.length !== 151) {
  console.error(`Expected pre-promotion curated count 151, found ${curated.recipes.length}. Aborting.`);
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

console.log(`Promoted ${batchRecipes.length} recipes.`);
console.log(`curated ${curated.recipes.length} -> ${afterCurated.recipes.length}`);
console.log(`added ids: ${addedIds.join(', ')}`);
