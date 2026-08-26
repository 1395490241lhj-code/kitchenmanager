import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

import { runDemoKitchenEntry } from '../src/onboarding.js';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

test('first-run onboarding offers a reachable demo-kitchen entry alongside skipping', () => {
  const onboarding = read('src/onboarding.js');
  const app = read('app.js');
  const styles = read('styles.css');

  // 入口只挂在那一步的文案真的承诺了示例厨房的地方。
  assert.match(onboarding, /body: '你可以先用示例厨房走一遍流程，再决定要不要记录自己的食材。'/);
  assert.match(onboarding, /offersDemo: true/);
  assert.match(onboarding, /class="km-onboard-demo"/);
  assert.match(onboarding, /试用示例厨房/);
  // 只在这一步、且确实接了回调时才显示，避免出现点了没反应的死按钮。
  assert.match(onboarding, /demoBtn\.hidden = !\(s\.offersDemo && typeof onTryDemoKitchen === 'function'\)/);

  // 复用既有状态机，不在引导里重写 demo 初始化。
  assert.match(app, /import \{ enterDemoKitchen \}/);
  assert.match(app, /onTryDemoKitchen/);
  assert.match(app, /enterDemoKitchen\(pack, \{ onRoute \}\)/);
  // 引导不 import demo 模块、也不碰 demo 的任何存储键——它只发出一个回调。
  assert.doesNotMatch(onboarding, /from '[^']*demo-kitchen/);
  assert.doesNotMatch(onboarding, /DEMO_KITCHEN_ITEMS|demo_snapshot|demo_mode|demo_step/);
  assert.match(read('src/views/home/demo-kitchen.js'), /if \(n > 0\) setHomeTab\('recs'\);/);

  // 跳过 / 走完引导开始自己的厨房，两条路径都保留。
  assert.match(onboarding, /skipBtn\.onclick = finish;/);
  assert.match(onboarding, /nextBtn\.textContent = step === STEPS\.length - 1 \? '开启厨房 ✨' : '下一步'/);

  assert.match(styles, /\.km-onboard-demo \{/);
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
  const demo = read('src/views/home/demo-kitchen.js');
  const storage = read('src/storage.js');
  const styles = read('styles.css');

  assert.match(storage, /demo_mode: 'km_demo_mode'/);
  assert.match(storage, /demo_snapshot: 'km_demo_snapshot_v1'/);
  assert.match(storage, /demo_step: 'km_demo_step_v1'/);
  assert.match(demo, /localStorage\.setItem\(S\.keys\.demo_mode, '1'\)/);
  assert.match(demo, /localStorage\.setItem\(S\.keys\.demo_step, 'recs'\)/);
  assert.match(demo, /S\.save\(S\.keys\.demo_snapshot/);
  assert.match(demo, /当前是示例体验/);
  assert.match(demo, /第 2 步：选一道今天想吃的菜/);
  // 接线检查：prose 收敛到 src/copy.js（见 copy-constants.test.mjs），这里只锚定常量引用。
  assert.match(demo, /DEMO_COPY\.STEP_RECS_BODY/);
  assert.match(demo, /第 3 步：做完后更新库存/);
  assert.match(demo, /DEMO_COPY\.STEP_COOK_BODY/);
  assert.match(demo, /示例体验完成/);
  assert.match(demo, /开始我的厨房/);
  assert.match(demo, /localStorage\.removeItem\(S\.keys\.demo_mode\)/);
  assert.match(demo, /localStorage\.removeItem\(S\.keys\.demo_snapshot\)/);
  assert.match(demo, /localStorage\.removeItem\(S\.keys\.demo_step\)/);
  assert.doesNotMatch(demo, /localStorage\.clear\(/);
  assert.match(styles, /\.demo-kitchen-primary/);
  assert.match(styles, /\.demo-kitchen-actions/);
});

test('guided demo advances on plan add and cooked-meal completion only in demo mode', () => {
  const home = read('src/views/home-view.js');
  const demo = read('src/views/home/demo-kitchen.js');
  const cookedMeal = read('src/views/home/cooked-meal-modal.js');

  assert.match(demo, /function markDemoPlanAdded\(added\)/);
  assert.match(demo, /setDemoStep\('plan'\)/);
  assert.match(home, /onPlanAdded: markDemoPlanAdded/);
  assert.match(demo, /function syncDemoStepFromTab\(tabName/);
  assert.match(demo, /if \(tabName === 'recs'\) \{\s*setDemoStep\('recs'\);/);
  assert.match(demo, /setDemoStep\(getTodayPlanCount\(\) > 0 \? 'cook' : 'recs'\);/);
  assert.match(home, /syncDemoStepFromTab\(tab, \{ onRoute \}\);/);
  assert.match(cookedMeal, /if \(isDemoKitchenMode\(\)\) \{\s*setDemoStep\('cook'\);/);
  assert.match(cookedMeal, /if \(isDemoKitchenMode\(\)\) \{\s*setDemoStep\('done'\);/);
  assert.match(cookedMeal, /refreshDemoKitchenBanner\(\{ onRoute \}\);/);
});

test('almost recommendation cards can join today plan and still fill shopping list', () => {
  const home = read('src/views/home-view.js');
  const styles = read('styles.css');

  assert.match(home, /<button type="button" class="btn ok small home-suggest-cook">加入计划<\/button>/);
  assert.match(home, /home-suggest-shopping/);
  assert.match(home, /补到买菜/);
  assert.match(home, /await addRecipeToPlanWithMissingCheck\(card\.id, pack, inv/);
  assert.match(home, /missing: card\.row\?\.missing/);
  assert.match(home, /addMissingRecipeIngredientsToShopping\(card\.row\.r, pack, inv, card\.row\.list\)/);
  assert.match(home, /PLAN_COPY\.ADDED_WITH_SHOPPING/);
  assert.match(home, /PLAN_COPY\.ADDED_SHOPPING_LATER/);
  assert.doesNotMatch(home, /card\.tone === 'almost' \? '加入买菜' : '做这道'/);
  assert.match(styles, /\.home-suggest-shopping/);
});

test('real first inventory entry guides users into recommendations', () => {
  const home = read('src/views/home-view.js');
  const styles = read('styles.css');

  assert.match(home, /setHomeTab\('recs'\);/);
  assert.match(home, /setPostInventoryGuide\(n\);/);
  assert.match(home, /已记录 \$\{n\} 样食材，看看今天能做什么。/);
  assert.match(home, /已经记下食材了/);
  assert.match(home, /下一步，选一道今天想吃的菜加入计划。/);
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
  assert.match(home, /PLAN_COPY\.FIRST_PLAN_GUIDE/);
  assert.match(home, /consumeFirstPlanGuideMessage\(added\)/);
  assert.match(home, /showFirstPlanGuideToast\(firstPlanGuide\)/);
  assert.doesNotMatch(storage, /postInventoryGuide|firstInventory|realEntry/);
});


// ── 「试用示例厨房」入口的成功 / 失败两条路径 ────────────────────────────────
// runDemoKitchenEntry 不碰 DOM API，只读写 button 的 disabled / textContent，
// 所以这里用一个最小的假按钮直接跑，无需 jsdom。

function fakeDemoButton() {
  return { disabled: false, textContent: '试用示例厨房' };
}

function silenceConsoleError() {
  const original = console.error;
  const calls = [];
  console.error = (...args) => calls.push(args);
  return { calls, restore: () => { console.error = original; } };
}

test('demo entry finishes onboarding only after the demo actually started', async () => {
  const button = fakeDemoButton();
  const order = [];

  const entered = await runDemoKitchenEntry({
    button,
    onTryDemoKitchen: async () => { order.push('demo'); },
    onEntered: () => { order.push('finish'); }
  });

  assert.equal(entered, true);
  // 顺序很重要：先真正进入 demo，成功了才写 km_onboarded_v1 / 关遮罩。
  assert.deepEqual(order, ['demo', 'finish']);
});

test('failed demo entry keeps onboarding open and lets the user retry', async () => {
  const button = fakeDemoButton();
  let finished = 0;
  const quiet = silenceConsoleError();

  let entered;
  try {
    entered = await runDemoKitchenEntry({
      button,
      onTryDemoKitchen: async () => { throw new Error('getCurrentPack failed'); },
      onEntered: () => { finished += 1; }
    });
  } finally {
    quiet.restore();
  }

  // 引导没有被完成、也没有被关闭——onEntered 根本没被调用。
  assert.equal(entered, false);
  assert.equal(finished, 0);
  assert.equal(quiet.calls.length, 1);
  // 按钮恢复可点，并且文案提示可以重试。
  assert.equal(button.disabled, false);
  assert.match(button.textContent, /重试/);

  // 重试成功后才收尾。
  const retried = await runDemoKitchenEntry({
    button,
    onTryDemoKitchen: async () => {},
    onEntered: () => { finished += 1; }
  });
  assert.equal(retried, true);
  assert.equal(finished, 1);
});

test('demo entry ignores repeat clicks while it is still entering', async () => {
  const button = fakeDemoButton();
  let attempts = 0;
  let release;
  const pending = new Promise(resolve => { release = resolve; });

  const first = runDemoKitchenEntry({
    button,
    onTryDemoKitchen: async () => { attempts += 1; await pending; },
    onEntered: () => {}
  });

  // 等待期间按钮已禁用，第二次点击直接被忽略，不会重复进入 demo。
  assert.equal(button.disabled, true);
  assert.match(button.textContent, /正在准备/);
  assert.equal(await runDemoKitchenEntry({
    button,
    onTryDemoKitchen: async () => { attempts += 1; },
    onEntered: () => {}
  }), false);

  release();
  assert.equal(await first, true);
  assert.equal(attempts, 1);
});
