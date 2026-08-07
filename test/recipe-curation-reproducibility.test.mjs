import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

import { buildDefaultRuntimePacks } from '../scripts/recipe-runtime-quality.mjs';

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8'),
);

const overlay = readJson('data/recipe-completion-overlay.json');
const base = readJson('data/sichuan-recipes.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const audit = readJson('data/recipe-curation-ingredient-overrides.v1.json');

const EXPECTED_OVERRIDE_IDS = [
  'ex--0b5f9f77',
  'ex--0d31aaec',
  'ex--0fd31741',
  'ex--3235554e',
  'ex--4f93c5ac',
  'ex--addb85f5',
  'ex--ec5d7e15',
  'ex--36f76a55',
  'ex--9f93d3f9',
];

const overrideIds = new Set(Object.keys(overlay.recipeIngredientOverrides || {}));
const itemsOf = (list) => (list || []).map((entry) => entry.item);
const isCoarse = (list) => !Array.isArray(list) || list.length <= 1;

function makeTempRepo() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dz1979-curation-'));
  fs.mkdirSync(path.join(tmp, 'scripts'));
  fs.mkdirSync(path.join(tmp, 'data'));
  fs.copyFileSync(
    new URL('../scripts/curate-recipes.js', import.meta.url).pathname,
    path.join(tmp, 'scripts', 'curate-recipes.js'),
  );
  fs.copyFileSync(
    new URL('../data/sichuan-recipes.json', import.meta.url).pathname,
    path.join(tmp, 'data', 'sichuan-recipes.json'),
  );
  fs.copyFileSync(
    new URL('../data/recipe-completion-overlay.json', import.meta.url).pathname,
    path.join(tmp, 'data', 'recipe-completion-overlay.json'),
  );
  return tmp;
}

function runCurate(tmp) {
  execFileSync('node', [path.join(tmp, 'scripts', 'curate-recipes.js')], {
    cwd: tmp,
    stdio: 'pipe',
  });
  return JSON.parse(
    fs.readFileSync(path.join(tmp, 'data', 'sichuan-recipes.curated.json'), 'utf8'),
  );
}

test('the nine override IDs are fixed and all exist in base, overlay, and curated', () => {
  assert.deepEqual([...overrideIds].sort(), [...EXPECTED_OVERRIDE_IDS].sort());
  for (const id of EXPECTED_OVERRIDE_IDS) {
    assert.equal(overlay.recipeIngredientOverrides[id], 'replace', id);
    assert.ok(base.recipe_ingredients[id] || base.recipes.some((r) => r.id === id), `${id} missing in base`);
    assert.ok(overlay.recipe_ingredients[id], `${id} missing overlay patch`);
    assert.ok(curated.recipe_ingredients[id], `${id} missing in curated`);
  }
});

test('the two 111301d backfill lists match accepted curated exactly', () => {
  const expected = {
    'ex--36f76a55': ['虾饼', '虾仁'],
    'ex--9f93d3f9': ['豆芽', '鸡蛋'],
  };
  for (const [id, list] of Object.entries(expected)) {
    assert.deepEqual(itemsOf(overlay.recipe_ingredients[id]), list, `${id} overlay`);
    assert.deepEqual(itemsOf(curated.recipe_ingredients[id]), list, `${id} curated`);
    const auditItem = audit.items.find((item) => item.id === id);
    assert.deepEqual(auditItem.acceptedIngredientList, list, `${id} audit`);
    assert.match(auditItem.basis, /111301d/, `${id} provenance must cite 111301d`);
  }
});

test('runtime overlay merge and curate both reproduce the nine accepted ingredient lists', async () => {
  const tmp = makeTempRepo();
  try {
    const curateOutput = runCurate(tmp);
    const runtime = await buildDefaultRuntimePacks();
    for (const id of EXPECTED_OVERRIDE_IDS) {
      const expected = itemsOf(curated.recipe_ingredients[id]);
      assert.deepEqual(
        itemsOf(curateOutput.recipe_ingredients[id]),
        expected,
        `${id} curate drift`,
      );
      assert.deepEqual(
        itemsOf(runtime.packs.curated.recipe_ingredients[id]),
        expected,
        `${id} runtime drift`,
      );
    }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('replace overrides base lists that already have 2+ items', () => {
  for (const id of EXPECTED_OVERRIDE_IDS) {
    const baseItems = itemsOf(base.recipe_ingredients[id]);
    if (baseItems.length < 2) continue; // the two 111301d backfills have 1-item bases
    assert.ok(baseItems.length >= 2, id);
    assert.notDeepEqual(itemsOf(overlay.recipe_ingredients[id]), baseItems, `${id} should differ from base`);
  }
});

test('non-override patches keep the old coarse rule', async () => {
  const runtime = await buildDefaultRuntimePacks();
  for (const [id, list] of Object.entries(overlay.recipe_ingredients || {})) {
    const baseItems = itemsOf(base.recipe_ingredients[id]);
    let expected;
    if (overrideIds.has(id)) {
      expected = itemsOf(list);
    } else if (isCoarse(baseItems)) {
      expected = itemsOf(list);
    } else {
      expected = baseItems;
    }
    assert.deepEqual(
      itemsOf(runtime.packs.curated.recipe_ingredients[id]),
      expected,
      `${id} merge decision mismatch`,
    );
  }
  // The one non-override patch has a coarse base and must still be applied.
  assert.equal(isCoarse(itemsOf(base.recipe_ingredients['ex--10cdbeaf'])), true);
  assert.deepEqual(
    itemsOf(runtime.packs.curated.recipe_ingredients['ex--10cdbeaf']),
    itemsOf(overlay.recipe_ingredients['ex--10cdbeaf']),
  );
});

test('overrides only affect ingredients, never method/name/tags', async () => {
  const runtime = await buildDefaultRuntimePacks();
  for (const id of EXPECTED_OVERRIDE_IDS) {
    const baseRecipe = base.recipes.find((r) => r.id === id);
    const merged = runtime.packs.curated.recipes.find((r) => r.id === id);
    assert.equal(merged.name, baseRecipe.name, `${id} name changed`);
    assert.deepEqual(merged.tags, baseRecipe.tags, `${id} tags changed`);
    // The method comes from the pre-existing method patch (overlay.recipes),
    // not from the ingredient override. Assert it matches the patch exactly.
    const methodPatch = overlay.recipes[id]?.method;
    assert.equal(merged.method, methodPatch, `${id} method changed by override`);
  }
});

test('curate reproduces accepted curated with 0 add / 0 delete / 0 modify', () => {
  const tmp = makeTempRepo();
  try {
    const curateOutput = runCurate(tmp);
    assert.equal(curateOutput.recipes.length, curated.recipes.length);
    assert.deepEqual(
      curateOutput.recipes.map((r) => r.id),
      curated.recipes.map((r) => r.id),
    );
    assert.deepEqual(curateOutput.recipes, curated.recipes);
    assert.deepEqual(curateOutput.recipe_ingredients, curated.recipe_ingredients);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('curate keep/remove sets and human decisions are unchanged', () => {
  const tmp = makeTempRepo();
  try {
    execFileSync('node', [path.join(tmp, 'scripts', 'curate-recipes.js')], {
      cwd: tmp,
      stdio: 'pipe',
    });
    const realRemoved = readJson('data/recipe-curation-removed.json');
    const tmpRemoved = JSON.parse(
      fs.readFileSync(path.join(tmp, 'data', 'recipe-curation-removed.json'), 'utf8'),
    );
    assert.equal(tmpRemoved.removed.length, realRemoved.removed.length);
    for (let i = 0; i < realRemoved.removed.length; i += 1) {
      const a = realRemoved.removed[i];
      const b = tmpRemoved.removed[i];
      assert.equal(a.id, b.id);
      assert.equal(a.name, b.name);
      assert.equal(a.reason, b.reason);
      assert.equal(a.duplicateOf || '', b.duplicateOf || '');
    }
    const realNeeding = readJson('data/recipes-needing-completion.json');
    const tmpNeeding = JSON.parse(
      fs.readFileSync(path.join(tmp, 'data', 'recipes-needing-completion.json'), 'utf8'),
    );
    assert.equal(tmpNeeding.items.length, realNeeding.items.length);
    for (let i = 0; i < realNeeding.items.length; i += 1) {
      assert.equal(tmpNeeding.items[i].id, realNeeding.items[i].id);
      assert.equal(tmpNeeding.items[i].name, realNeeding.items[i].name);
      assert.equal(tmpNeeding.items[i].reason, realNeeding.items[i].reason);
      assert.equal(
        tmpNeeding.items[i].suggestedPriority,
        realNeeding.items[i].suggestedPriority,
      );
    }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('curate is idempotent across consecutive runs', () => {
  const tmp = makeTempRepo();
  try {
    runCurate(tmp);
    const first = fs.readFileSync(path.join(tmp, 'data', 'sichuan-recipes.curated.json'), 'utf8');
    runCurate(tmp);
    const second = fs.readFileSync(path.join(tmp, 'data', 'sichuan-recipes.curated.json'), 'utf8');
    assert.equal(first, second);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('runtime merge and curate merge agree on override semantics', async () => {
  const tmp = makeTempRepo();
  try {
    const curateOutput = runCurate(tmp);
    const runtime = await buildDefaultRuntimePacks();
    for (const id of EXPECTED_OVERRIDE_IDS) {
      assert.deepEqual(
        itemsOf(runtime.packs.curated.recipe_ingredients[id]),
        itemsOf(curateOutput.recipe_ingredients[id]),
        `${id} runtime/curate mismatch`,
      );
    }
    assert.deepEqual(itemsOf(runtime.packs.curated.recipe_ingredients['ex--10cdbeaf']),
      itemsOf(curateOutput.recipe_ingredients['ex--10cdbeaf']));
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
