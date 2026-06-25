import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

test('首页推荐区不再常驻显示操作说明文案', () => {
  const home = read('src/views/home-view.js');

  assert.doesNotMatch(home, /点“做这道”会加入今日计划/);
  assert.doesNotMatch(home, /轻点 \/ 左右滑动换一道/);
  assert.doesNotMatch(home, /轻点 \/ 左右滑动看下一个本地菜/);
  assert.doesNotMatch(home, /推荐仅供参考/);
  assert.doesNotMatch(home, /本地菜谱匹配结果，不调用 AI/);
});

test('推荐卡按钮、切换和 Toast 反馈仍保留', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /home-suggest-preview/);
  assert.match(home, /查看做法/);
  assert.match(home, /home-suggest-cook/);
  assert.match(home, /加入今日计划/);
  assert.match(home, /home-suggest-shopping/);
  assert.match(home, /补到买菜/);
  assert.match(home, /const stepRecommendation = \(delta = 1\) =>/);
  assert.match(home, /cardWrap\.onpointerdown/);
  assert.match(home, /cardWrap\.onpointerup/);
  assert.match(home, /addRecipeToPlanWithMissingCheck\(card\.id, pack, inv/);
  assert.match(home, /shoppingAddedCount/);
});

test('删除说明文案后清理旧 CSS，并保留低占用圆点指示', () => {
  const styles = read('styles.css');

  assert.doesNotMatch(styles, /\.wx-rec-guide\b/);
  assert.doesNotMatch(styles, /\.wx-rec-hint\b/);
  assert.doesNotMatch(styles, /\.wx-rec-note\b/);
  assert.doesNotMatch(styles, /\.target-recipe-summary\b/);
  assert.match(styles, /\.wx-rec-dots-only\s*\{/);
});
