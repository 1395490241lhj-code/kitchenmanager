import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

test('empty inventory home prioritizes demo kitchen, then text entry, then recipes', () => {
  const home = read('src/views/home-view.js');
  const styles = read('styles.css');

  assert.match(home, /今天不知道吃什么？/);
  assert.match(home, /先试一个示例厨房，马上看看今天能做什么、缺什么、该买什么。/);
  assert.match(home, /id="obDemo"/);
  assert.match(home, /试用示例厨房/);
  assert.match(home, /id="obManual"/);
  assert.match(home, /记录我的食材/);
  assert.match(home, /id="obRecipes"/);
  assert.doesNotMatch(home, /id="obReceipt"/);
  assert.match(home, /#obManual'\)\.onclick = \(\) => openBatchInputModal\(pack, \{ onRoute, initialTab: 'text' \}\)/);
  assert.match(home, /if \(n > 0\) lastWxTab = 'recs';/);

  assert.match(styles, /\.home-hero\.is-onboarding \.home-onboarding-demo\.is-primary/);
  assert.match(styles, /\.home-onboarding-link/);
});

test('first-run onboarding copy explains the cooking flow without product jargon', () => {
  const source = read('src/onboarding.js');
  const stepsBlock = source.slice(source.indexOf('const STEPS'), source.indexOf('export function hasOnboarded'));

  assert.match(source, /const ONBOARD_KEY = 'km_onboarded_v1';/);
  assert.match(stepsBlock, /title: '先记几样食材'/);
  assert.match(stepsBlock, /body: '不用完整整理冰箱，先写 3 到 5 样常见食材就行。'/);
  assert.match(stepsBlock, /title: '看看今天能做什么'/);
  assert.match(stepsBlock, /body: '我会根据现有食材推荐能做的菜，也会提醒还缺什么。'/);
  assert.match(stepsBlock, /title: '做完顺手更新'/);
  assert.match(stepsBlock, /饭后记一下/);
  assert.doesNotMatch(stepsBlock, /悬浮 Dock 舱|双轨制冰箱|高情商主厨校准|未来厨房|管家会帮你自动理解一切/);
});

test('real first inventory entry guides users into recommendations', () => {
  const home = read('src/views/home-view.js');
  const styles = read('styles.css');

  assert.match(home, /lastWxTab = 'recs';/);
  assert.match(home, /setPostInventoryGuide\(n\);/);
  assert.match(home, /已记录 \$\{n\} 样食材，看看今天能做什么。/);
  assert.match(home, /已经记下食材了/);
  assert.match(home, /下一步，选一道今天想吃的菜加入今日计划。/);
  assert.match(home, /id="postInventoryGuideRecs"/);
  assert.match(home, /id="postInventoryGuideAdd"/);
  assert.match(home, /postInventoryGuideAdd'\)\.onclick = \(\) => \{\s*openBatchInputModal\(pack, \{ onRoute, initialTab: 'text' \}\);/);
  assert.match(styles, /\.post-inventory-guide/);
});

test('empty recommendation state offers clear next steps after sparse inventory', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /还没有匹配到能直接做的菜/);
  assert.match(home, /可以再记几样食材，或者先去菜谱里挑一道。/);
  assert.match(home, /id="wxRecAddFood"/);
  assert.match(home, /id="wxRecGoRecipes"/);
  assert.match(home, /wxRecAddFood'\)\.onclick = \(\) => openBatchInputModal\(pack, \{ onRoute, initialTab: 'text' \}\)/);
  assert.match(home, /wxRecGoRecipes'\)\.onclick = \(\) => \{ location\.hash = '#recipes'; \}/);
});

test('first plan add after real entry explains the dinner-close loop without storage keys', () => {
  const home = read('src/views/home-view.js');
  const storage = read('src/storage.js');

  assert.match(home, /postInventoryPlanGuidePending/);
  assert.match(home, /已加入今日计划。做完后点“饭后记一下”，我会帮你更新剩余食材和待买清单。/);
  assert.match(home, /consumeFirstPlanGuideMessage\(added\)/);
  assert.match(home, /showFirstPlanGuideToast\(firstPlanGuide\)/);
  assert.doesNotMatch(storage, /postInventoryGuide|firstInventory|realEntry/);
});
