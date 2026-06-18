import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

test('首页推荐卡只通过明确的查看做法按钮打开预览', () => {
  const home = read('src/views/home-view.js');
  const recipeCard = read('src/components/recipe-card.js');

  assert.match(home, /home-suggest-preview/);
  assert.match(home, /if \(previewBtn\) previewBtn\.onclick = openPreview;/);
  assert.doesNotMatch(home, /el\.onclick = event =>[\s\S]*?openPreview\(event\);/);
  assert.doesNotMatch(home, /name\.onclick = openPreview/);
  assert.doesNotMatch(recipeCard, /card\.addEventListener\('click', event =>[\s\S]*?openPreview\(event\);/);
  assert.match(recipeCard, /detailBtn\.onclick = event => \{[\s\S]*?if \(canPreview\) openPreview\(event\);/);
});

test('首页推荐卡轻点和左右滑动仍用于切换推荐', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /cardWrap\.onclick = \(event\) => \{[\s\S]*?stepRecommendation\(1\);/);
  assert.match(home, /cardWrap\.onpointerdown/);
  assert.match(home, /cardWrap\.onpointerup/);
  assert.match(home, /stepRecommendation\(dx < 0 \? 1 : -1\);/);
  assert.match(home, /const isCardControlTarget = \(target\) => Boolean\(target && target\.closest\('button, a, input, select, textarea, \[data-no-card-swipe\]'\)\);/);
});

test('搜索结果卡仍保持整卡点击打开预览', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /card\.onclick = openPreview;/);
  assert.match(home, /card\.querySelector\('\.target-recipe-view-btn'\)\.onclick/);
});

test('菜谱预览弹窗正文和 footer 分层，footer 不再作为正文内 sticky 覆盖层', () => {
  const home = read('src/views/home-view.js');
  const styles = read('styles.css');

  assert.match(home, /content\.className = 'recipe-preview-shell';/);
  assert.match(home, /<div class="km-modal-body recipe-preview-body">/);
  assert.match(home, /<div class="km-modal-actions recipe-preview-actions">/);
  assert.match(styles, /\.recipe-preview-shell\s*\{[\s\S]*?overflow: hidden;/);
  assert.match(styles, /\.recipe-preview-actions\s*\{[\s\S]*?position: static;/);
  assert.match(styles, /\.recipe-preview-actions \.recipe-preview-go-plan:not\(\[hidden\]\)\s*\{[\s\S]*?grid-column: 1 \/ -1;/);
});
