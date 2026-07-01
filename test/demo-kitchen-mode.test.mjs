import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

test('demo kitchen mode uses centralized keys and snapshots business data', () => {
  const home = read('src/views/home-view.js');
  const demo = read('src/views/home/demo-kitchen.js');
  const storage = read('src/storage.js');

  assert.match(storage, /demo_mode: 'km_demo_mode'/);
  assert.match(storage, /demo_snapshot: 'km_demo_snapshot_v1'/);
  assert.match(storage, /demo_step: 'km_demo_step_v1'/);
  assert.match(demo, /const DEMO_BUSINESS_KEY_NAMES = \[/);
  assert.match(demo, /'inventory'/);
  assert.match(demo, /'plan'/);
  assert.match(demo, /'shopping_items'/);
  assert.match(demo, /'staples'/);
  assert.match(demo, /'pantry_config'/);
  assert.match(demo, /'prep_done'/);
  assert.match(demo, /'ai_recs'/);
  assert.match(demo, /'local_recs'/);
  assert.match(demo, /'rec_time'/);
  assert.match(demo, /'rec_signature'/);
  assert.match(demo, /'recipe_usage'/);
  assert.match(demo, /'recipe_activity'/);
  assert.match(demo, /'favorite_recipes'/);
  assert.match(demo, /S\.save\(S\.keys\.demo_snapshot/);
  assert.match(demo, /localStorage\.setItem\(S\.keys\.demo_mode, '1'\)/);
  assert.match(demo, /localStorage\.setItem\(S\.keys\.demo_step, 'recs'\)/);
  assert.match(home, /section\.querySelector\('#obDemo'\)\.onclick = \(\) => enterDemoKitchen\(pack, \{ onRoute \}\);/);
});

test('demo kitchen exit restores snapshot without clearing personal settings', () => {
  const home = read('src/views/home-view.js');
  const demo = read('src/views/home/demo-kitchen.js');
  const styles = read('styles.css');

  assert.match(demo, /function exitDemoKitchen/);
  assert.match(demo, /restoreDemoKitchenSnapshot\(snapshot\)/);
  assert.match(demo, /localStorage\.removeItem\(S\.keys\.demo_mode\)/);
  assert.match(demo, /localStorage\.removeItem\(S\.keys\.demo_snapshot\)/);
  assert.match(demo, /localStorage\.removeItem\(S\.keys\.demo_step\)/);
  assert.doesNotMatch(demo, /localStorage\.clear\(/);
  assert.doesNotMatch(home, /localStorage\.clear\(/);
  assert.doesNotMatch(demo, /removeItem\(S\.keys\.settings\)/);
  assert.doesNotMatch(demo, /removeItem\(S\.keys\.schema_version\)/);
  assert.doesNotMatch(demo, /km_onboarded_v1[\s\S]{0,160}removeItem/);
  assert.match(demo, /当前是示例体验/);
  assert.match(demo, /退出示例/);
  assert.match(demo, /开始我的厨房/);
  assert.match(demo, /你的设置不会被删除/);
  assert.match(styles, /\.demo-kitchen-banner/);
  assert.match(styles, /\.demo-kitchen-primary/);
  assert.match(styles, /\.demo-kitchen-exit/);
});

test('demo kitchen keeps text-first entry and receipt tab availability', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /#obManual'\)\.onclick = \(\) => openBatchInputModal\(pack, \{ onRoute, initialTab: 'text' \}\)/);
  assert.match(home, /data-tab="receipt"/);
  assert.match(home, /id="batchReceiptFile" accept="image\/\*"/);
  assert.match(home, /data-tab="text"/);
});
