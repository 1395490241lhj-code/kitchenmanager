#!/usr/bin/env node
// Applies the frozen Batch 11 proposal and its quantity-semantics sidecar.

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { assertValidRecipeQuantitySemantics } from '../../recipe-quantity-semantics.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const readJson = (file) => JSON.parse(fs.readFileSync(path.join(repoRoot, file), 'utf8'));
const writeJson = (file, value) => fs.writeFileSync(path.join(repoRoot, file), `${JSON.stringify(value, null, 2)}\n`);
const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch11-dry-run.v1.json');
const quantityReview = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch11-quantity-review.v1.json');
const overlay = readJson('data/recipe-completion-overlay.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');
const sidecarPath = 'data/recipe-quantity-semantics.json';
const expectedIds = ['dz1979-p222', 'dz1979-p226', 'dz1979-p224'];

const fail = (message) => { throw new Error(message); };
if (JSON.stringify(dryRun.items.map((item) => item.productionId)) !== JSON.stringify(expectedIds)) fail('Frozen Batch11 order mismatch.');
if (dryRun.verificationProblems.length || dryRun.productionWrites !== false || dryRun.applicationReady !== false) fail('Frozen Batch11 dry-run is not clean.');
if (quantityReview.records.length !== 21
  || JSON.stringify(quantityReview.summary.unitCounts) !== JSON.stringify({ g: 20, '个': 1 })
  || quantityReview.verificationProblems.length) fail('Frozen Batch11 quantity review mismatch.');
if (curated.recipes.length !== 162 || fs.existsSync(path.join(repoRoot, sidecarPath))) fail('Production baseline or sidecar existence mismatch.');

const batchRecipes = dryRun.items.map((item) => item.proposedOverlayRecipe);
const batchIngredients = Object.fromEntries(dryRun.items.map((item) => [
  item.productionId,
  item.proposedOverlayIngredients[item.productionId],
]));
const proposedPack = { recipes: batchRecipes, recipe_ingredients: batchIngredients };
const validation = assertValidRecipeQuantitySemantics(dryRun.proposedQuantitySemanticsSidecar, proposedPack);
if (validation.joins.length !== 4
  || JSON.stringify(validation.joins) !== JSON.stringify(dryRun.sidecarValidation.joins)) fail('Frozen Batch11 sidecar joins mismatch.');

const existingNames = new Set([...curated.recipes, ...full.recipes, ...(overlay.newRecipes ?? [])].map((r) => r.name));
const existingIds = new Set([...curated.recipes, ...full.recipes, ...(overlay.newRecipes ?? [])].map((r) => r.id));
for (const recipe of batchRecipes) {
  if (existingIds.has(recipe.id) || existingNames.has(recipe.name)) fail(`Production collision: ${recipe.id}/${recipe.name}`);
}

const nextOverlay = {
  ...overlay,
  newRecipes: [...(overlay.newRecipes ?? []), ...batchRecipes],
  newRecipeIngredients: { ...(overlay.newRecipeIngredients ?? {}), ...batchIngredients },
};
if (nextOverlay.updatedAt !== overlay.updatedAt) fail('Overlay updatedAt drift.');
const rollbackFiles = [
  'data/recipe-completion-overlay.json',
  'data/sichuan-recipes.curated.json',
  'data/recipe-curation-summary.md',
  'data/recipe-curation-removed.json',
  'data/recipes-needing-completion.json',
];
const snapshots = new Map(rollbackFiles.map((file) => [file, fs.readFileSync(path.join(repoRoot, file))]));
try {
  writeJson('data/recipe-completion-overlay.json', nextOverlay);
  writeJson(sidecarPath, dryRun.proposedQuantitySemanticsSidecar);
  execFileSync('node', [path.join(repoRoot, 'scripts/curate-recipes.js')], { cwd: repoRoot, stdio: 'pipe' });
  const after = readJson('data/sichuan-recipes.curated.json');
  const addedIds = after.recipes.filter((recipe) => !curated.recipes.some((old) => old.id === recipe.id)).map((recipe) => recipe.id);
  if (after.recipes.length !== 165
    || Object.keys(after.recipe_ingredients).length !== Object.keys(curated.recipe_ingredients).length + 3
    || JSON.stringify([...addedIds].sort()) !== JSON.stringify([...expectedIds].sort())) fail('Post-promotion delta mismatch.');
  for (const recipe of curated.recipes) {
    if (JSON.stringify(after.recipes.find((entry) => entry.id === recipe.id)) !== JSON.stringify(recipe)
      || JSON.stringify(after.recipe_ingredients[recipe.id]) !== JSON.stringify(curated.recipe_ingredients[recipe.id])) fail(`Existing production drift: ${recipe.id}`);
  }
  for (const item of dryRun.items) {
    if (JSON.stringify(after.recipes.find((recipe) => recipe.id === item.productionId)) !== JSON.stringify(item.proposedCuratedRecipe)
      || JSON.stringify(after.recipe_ingredients[item.productionId]) !== JSON.stringify(item.proposedCuratedIngredients[item.productionId])) fail(`Frozen proposal mismatch: ${item.productionId}`);
  }
  const actualSidecar = readJson(sidecarPath);
  if (JSON.stringify(actualSidecar) !== JSON.stringify(dryRun.proposedQuantitySemanticsSidecar)) fail('Actual sidecar differs from frozen proposal.');
  assertValidRecipeQuantitySemantics(actualSidecar, after);
  console.log(`Promoted ${batchRecipes.length} recipes; curated ${curated.recipes.length} -> ${after.recipes.length}; sidecar joins ${validation.joins.length}.`);
} catch (error) {
  for (const [file, bytes] of snapshots) fs.writeFileSync(path.join(repoRoot, file), bytes);
  if (fs.existsSync(path.join(repoRoot, sidecarPath))) fs.unlinkSync(path.join(repoRoot, sidecarPath));
  throw error;
}
