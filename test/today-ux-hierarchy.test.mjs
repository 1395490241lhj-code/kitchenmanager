import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

test('今日页顶部 Hero 回答今晚吃什么并展示厨房状态', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /renderTodayDecisionHero/);
  assert.match(home, /今天的厨房/);
  assert.match(home, /今晚吃什么？/);
  assert.match(home, /冰箱里有 \$\{usableCount\} 样食材，可以推荐 \$\{recommendationCount\} 道菜/);
  assert.match(home, /生成今日推荐/);
  assert.match(home, /添加食材/);
  assert.match(home, /今日计划/);
  assert.match(home, /快过期/);
  assert.match(home, /待买/);
});

test('推荐卡把加入今日计划作为主按钮，并保留缺菜检测入口', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /<button type="button" class="btn ok small home-suggest-cook">加入今日计划<\/button>/);
  assert.match(home, /home-suggest-preview/);
  assert.match(home, /home-suggest-shopping/);
  assert.match(home, /addRecipeToPlanWithMissingCheck/);
  assert.doesNotMatch(home, /addRecipeToPlan\(/);
});

test('推荐卡缺食材展示支持只差 1 样和还缺多样', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /function formatMissingSummary/);
  assert.match(home, /只差 1 样：\$\{items\[0\]\}/);
  assert.match(home, /还缺 \$\{items\.length\} 样：/);
  assert.match(home, /items\.length > 3 \? '等' : ''/);
  assert.match(home, /home-suggest-missing/);
});

test('今日计划、推荐、快过期和导入区域都有明确层级，demo banner 逻辑仍保留', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /renderWxSectionIntro\(\s*'今日计划'/);
  assert.match(home, /renderTodayRecommendationSection/);
  assert.match(home, /今日推荐/);
  assert.match(home, /推荐先做这几道/);
  assert.match(home, /暂无合适推荐/);
  assert.match(home, /renderExpiringIngredientsSection/);
  assert.match(home, /快过期食材/);
  assert.match(home, /从小红书导入菜谱/);
  assert.match(home, /renderDemoKitchenBanner/);
  assert.match(home, /if \(isDemoMode\) \{\s*container\.appendChild\(renderDemoKitchenBanner/);
});

test('备份提醒和 PWA 安装提示仍在 Hero 之后渲染', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /container\.appendChild\(renderTodayDecisionHero\(pack, inv, summaryStats, \{ onRoute \}\)\);[\s\S]*renderBackupNudge/);
  assert.match(home, /renderBackupNudge\(inv, \{ isDemoMode \}\)/);
  assert.match(home, /renderPwaInstallNudge\(inv, \{ isDemoMode \}\)/);
});
