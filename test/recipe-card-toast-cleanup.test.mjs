import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

test('searchResultCard 使用 Toast 反馈加入今日计划，不再调用 alert', () => {
  const source = read('src/components/recipe-card.js');

  assert.doesNotMatch(source, /alert\('已加入今日计划。'\)/);
  assert.doesNotMatch(source, /alert\('已在今日计划里。'\)/);
  assert.doesNotMatch(source, /\balert\(/);
  assert.match(source, /addRecipeToPlanWithMissingCheck\(r\.id, ctx\.pack, ctx\.inv/);
  assert.match(source, /source: 'search-result'/);
});

test('attachQuickDelete 不再包含旧 overlay 影子代码，仍使用 overlay 模块读写', () => {
  const source = read('src/components/recipe-card.js');
  const staleOverlayKey = ['kitchen', 'overlay'].join('-');

  assert.equal(source.includes(staleOverlayKey), false);
  assert.match(source, /import \{\s*loadOverlay,\s*saveOverlay\s*\} from '\.\.\/backup\.js\?v=\d+';/s);
  assert.match(source, /const ov = loadOverlay\(\);/);
  assert.match(source, /saveOverlay\(ov\);/);
});
