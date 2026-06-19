import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';

const root = process.cwd();

function readSource(path) {
  return readFileSync(join(root, path), 'utf8');
}

function getBlock(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  assert.notEqual(start, -1, `Missing block start: ${startMarker}`);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert.notEqual(end, -1, `Missing block end: ${endMarker}`);
  return source.slice(start, end);
}

test('AI recipe draft save keeps toast and hash navigation without immediate reload', () => {
  const source = readSource('src/components/recipe-card.js');
  const block = getBlock(
    source,
    'export function renderAiRecipeDraftCard',
    'export function renderRecipeSearchResults'
  );

  assert.doesNotMatch(block, /location\.reload\(\)/);
  assert.match(block, /saveOverlay\(overlay\);/);
  assert.match(block, /window\.invalidatePackCache\?\.\(\);/);
  assert.match(block, /showToast\('AI 草稿已保存', \{ tone: 'success' \}\);/);
  assert.match(block, /location\.hash = goEdit \? `#recipe-edit:\$\{tempId\}` : `#recipe:\$\{tempId\}`;/);
});

test('searchResultCard supports optional preview callback without inline hash handlers', () => {
  const source = readSource('src/components/recipe-card.js');
  const block = getBlock(
    source,
    'export function searchResultCard',
    'function compactStatusBadge'
  );

  assert.match(block, /onPreviewRecipe = null/);
  assert.doesNotMatch(block, /onclick="location\.hash='#recipe:/);
  assert.match(block, /id="viewRecipeBtn"/);
  assert.match(block, /if \(typeof onPreviewRecipe === 'function'\) onPreviewRecipe\(r\);/);
  assert.match(block, /else location\.hash = `#recipe:\$\{r\.id\}`;/);
  assert.match(block, /viewBtn\.onclick = openRecipe;/);
  assert.match(block, /event\?\.stopPropagation\(\);[\s\S]*?const plan = S\.load/);
});

test('legacy memo modal is still wired and shows a toast after adding shopping item', () => {
  const source = readSource('src/views/home-view.js');
  const block = getBlock(source, 'function buildMemoModal', 'function renderUrgentMetrics');

  assert.match(source, /buildMemoModal\(\(\) => close\(\)\)/);
  assert.match(
    block,
    /addShoppingItem\(name, '', '', '速记'\);[\s\S]*?showToast\('已加入买菜清单', \{ tone: 'success' \}\);/
  );
});
