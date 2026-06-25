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
  assert.match(home, /先用一个示例厨房体验一次：看推荐、安排今日计划、做完后更新库存。/);
  assert.match(home, /id="obDemo"/);
  assert.match(home, /开始示例体验/);
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
  assert.match(stepsBlock, /title: '先从一次体验开始'/);
  assert.match(stepsBlock, /body: '你可以先用示例厨房走一遍流程，再决定要不要记录自己的食材。'/);
  assert.match(stepsBlock, /title: '真实使用也很简单'/);
  assert.match(stepsBlock, /body: '记几样食材后，我会帮你看今天能做什么、缺什么、该买什么。'/);
  assert.match(stepsBlock, /title: '数据在本地'/);
  assert.match(stepsBlock, /设置页可以导出备份/);
  assert.doesNotMatch(stepsBlock, /悬浮 Dock 舱|双轨制冰箱|高情商主厨校准|未来厨房|管家会帮你自动理解一切/);
});

test('guided demo stores step state and renders reversible example guidance', () => {
  const home = read('src/views/home-view.js');
  const storage = read('src/storage.js');
  const styles = read('styles.css');

  assert.match(storage, /demo_mode: 'km_demo_mode'/);
  assert.match(storage, /demo_snapshot: 'km_demo_snapshot_v1'/);
  assert.match(storage, /demo_step: 'km_demo_step_v1'/);
  assert.match(home, /localStorage\.setItem\(S\.keys\.demo_mode, '1'\)/);
  assert.match(home, /localStorage\.setItem\(S\.keys\.demo_step, 'recs'\)/);
  assert.match(home, /S\.save\(S\.keys\.demo_snapshot/);
  assert.match(home, /当前是示例体验/);
  assert.match(home, /第 2 步：看看今天能做什么/);
  assert.match(home, /第 3 步：今日计划已经安排好了/);
  assert.match(home, /第 4 步：做完后更新库存/);
  assert.match(home, /示例体验完成/);
  assert.match(home, /开始我的厨房/);
  assert.match(home, /localStorage\.removeItem\(S\.keys\.demo_mode\)/);
  assert.match(home, /localStorage\.removeItem\(S\.keys\.demo_snapshot\)/);
  assert.match(home, /localStorage\.removeItem\(S\.keys\.demo_step\)/);
  assert.doesNotMatch(home, /localStorage\.clear\(/);
  assert.match(styles, /\.demo-kitchen-primary/);
  assert.match(styles, /\.demo-kitchen-actions/);
});

test('guided demo advances on plan add and cooked-meal completion only in demo mode', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /function markDemoPlanAdded\(added\)/);
  assert.match(home, /setDemoStep\('plan'\)/);
  assert.match(home, /markDemoPlanAdded\(added\)/);
  assert.match(home, /if \(isDemoKitchenMode\(\)\) setDemoStep\('cook'\);/);
  assert.match(home, /if \(isDemoKitchenMode\(\)\) setDemoStep\('done'\);/);
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
