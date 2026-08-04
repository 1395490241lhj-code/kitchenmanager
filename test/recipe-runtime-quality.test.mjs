import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  BASELINE_PATH,
  MANIFEST_PATH,
  analyzeRuntimeQuality,
  buildDefaultRuntimePacks,
  buildIdBaseline,
  generateCuratedMissingManifest,
  recipeIdDigest,
  validateManifest
} from '../scripts/recipe-runtime-quality.mjs';

const root = process.cwd();

function readJson(path) {
  return JSON.parse(readFileSync(path, 'utf8'));
}

test('default runtime quality covers the final Curated and Full merge chain', async () => {
  const runtime = await buildDefaultRuntimePacks();
  const baseline = readJson(BASELINE_PATH);
  const manifest = readJson(MANIFEST_PATH);
  const report = analyzeRuntimeQuality({
    ...runtime,
    baseline,
    manifest
  });

  assert.deepEqual(report.modes.curated.stats, {
    recipes: 403,
    methodsReady: 403,
    missingMethods: 0,
    ingredientMaps: 300,
    missingIngredientMaps: 103,
    ingredientEntries: 1194,
    duplicateIds: 0,
    duplicateNames: 0,
    orphanIngredientMaps: 0
  });
  assert.equal(report.modes.full.stats.recipes, 526);
  assert.equal(report.modes.full.stats.methodsReady, 403);
  assert.equal(report.modes.full.stats.missingMethods, 123);
  assert.equal(report.modes.full.stats.missingIngredientMaps, 30);
  assert.equal(report.modes.curated.errorCounts['curated-missing-method'] || 0, 0);
  assert.equal(report.modes.curated.errorCounts['curated-missing-ingredient-map'], 103);
  assert.ok(report.modes.curated.warningCounts['missing-qty-unit'] > 0);
  assert.ok(report.modes.curated.warningCounts['short-method'] > 0);
  assert.ok(report.modes.curated.warningCounts['generic-ingredient'] > 0);
  assert.ok(report.modes.curated.warningCounts['ingredient-step-mismatch'] > 0);
  assert.ok(report.modes.curated.warningCounts['repeated-ingredients'] > 0);
  assert.ok(report.modes.curated.warningCounts['repeated-methods'] > 0);
});

test('ID baseline and deterministic 103-entry manifest cover exactly the runtime gap', async () => {
  const runtime = await buildDefaultRuntimePacks();
  const baseline = readJson(BASELINE_PATH);
  const manifest = readJson(MANIFEST_PATH);
  const generatedBaseline = buildIdBaseline(runtime.basePacks);
  assert.deepEqual(generatedBaseline, baseline);
  for (const mode of ['curated', 'full']) {
    assert.equal(recipeIdDigest(runtime.basePacks[mode]), baseline.sources[mode].idSha256);
    assert.equal(runtime.basePacks[mode].recipes.length, baseline.sources[mode].count);
  }

  const regenerated = generateCuratedMissingManifest(runtime.packs.curated, runtime.basePacks, runtime.sources);
  assert.deepEqual(regenerated, manifest);
  assert.equal(manifest.length, 103);
  assert.equal(new Set(manifest.map(entry => entry.id)).size, 103);
  assert.equal(new Set(manifest.map(entry => entry.name)).size, 103);
  assert.ok(manifest.every(entry => entry.methodSource === 'recipe-methods'));
  assert.ok(manifest.every(entry => ['P1', 'P2', 'P3'].includes(entry.priority)));
  assert.ok(manifest.every(entry => Array.isArray(entry.suggestedCoreIngredients)));

  const batchSizes = [...manifest.reduce((groups, entry) => {
    groups.set(entry.batch, (groups.get(entry.batch) || 0) + 1);
    return groups;
  }, new Map()).values()];
  assert.deepEqual(batchSizes, [15, 15, 15, 15, 15, 14, 14]);
  assert.ok(batchSizes.every(size => size >= 10 && size <= 20));
  assert.deepEqual(validateManifest(manifest, runtime.packs.curated, runtime.basePacks, runtime.sources), []);
});

test('analysis mode stays green while strict mode reports the known nonzero data errors', () => {
  const script = join(root, 'scripts', 'recipe-runtime-quality.mjs');
  const analysis = spawnSync(process.execPath, [script], { cwd: root, encoding: 'utf8' });
  assert.equal(analysis.status, 0, analysis.stderr);
  assert.match(analysis.stdout, /errors total=103/);
  assert.match(analysis.stdout, /strict=analysis-only/);

  const strict = spawnSync(process.execPath, [script, '--strict'], { cwd: root, encoding: 'utf8' });
  assert.equal(strict.status, 1, strict.stdout + strict.stderr);
  assert.match(strict.stdout, /curated-missing-ingredient-map/);
  assert.match(strict.stdout, /strict=enabled/);
});
