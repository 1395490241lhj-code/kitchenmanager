import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

test('home quick actions render as two separate compact cards', () => {
  const home = read('src/views/home-view.js');
  const styles = read('styles.css');

  assert.match(home, /id="qaStock"/);
  assert.match(home, /id="qaRecipeImport"/);
  assert.match(home, /id="qaRecipeImport"[\s\S]*?<span class="tq-emoji">📖<\/span>/);
  assert.match(home, /<strong>导入菜谱<\/strong><small>粘贴链接识别<\/small>/);
  assert.match(home, /<strong>记食材<\/strong><small>记录冰箱食材<\/small>/);
  assert.doesNotMatch(home, /id="qaRecipeImport"><span class="tq-emoji">📸<\/span>/);
  assert.match(styles, /Home quick actions should read as two tappable cards/);
  assert.match(styles, /\.today-quick-row,[\s\S]*?grid-template-columns: repeat\(2, minmax\(0, 1fr\)\);/);
  assert.match(styles, /\.today-quick-row::after,[\s\S]*?content: none;/);
  assert.match(styles, /\.today-quick-btn \.tq-emoji\s*\{[\s\S]*?width: 34px;/);
});
