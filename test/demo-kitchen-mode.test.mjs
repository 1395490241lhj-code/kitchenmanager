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
  const storage = read('src/storage.js');

  assert.match(storage, /demo_mode: 'km_demo_mode'/);
  assert.match(storage, /demo_snapshot: 'km_demo_snapshot_v1'/);
  assert.match(home, /const DEMO_BUSINESS_KEY_NAMES = \[/);
  assert.match(home, /'inventory'/);
  assert.match(home, /'plan'/);
  assert.match(home, /'shopping_items'/);
  assert.match(home, /'staples'/);
  assert.match(home, /'pantry_config'/);
  assert.match(home, /'prep_done'/);
  assert.match(home, /'ai_recs'/);
  assert.match(home, /'local_recs'/);
  assert.match(home, /'rec_time'/);
  assert.match(home, /'rec_signature'/);
  assert.match(home, /'recipe_usage'/);
  assert.match(home, /'recipe_activity'/);
  assert.match(home, /'favorite_recipes'/);
  assert.match(home, /S\.save\(S\.keys\.demo_snapshot/);
  assert.match(home, /localStorage\.setItem\(S\.keys\.demo_mode, '1'\)/);
  assert.match(home, /section\.querySelector\('#obDemo'\)\.onclick = \(\) => enterDemoKitchen\(pack, \{ onRoute \}\);/);
});

test('demo kitchen exit restores snapshot without clearing personal settings', () => {
  const home = read('src/views/home-view.js');
  const styles = read('styles.css');

  assert.match(home, /function exitDemoKitchen/);
  assert.match(home, /restoreDemoKitchenSnapshot\(snapshot\)/);
  assert.match(home, /localStorage\.removeItem\(S\.keys\.demo_mode\)/);
  assert.match(home, /localStorage\.removeItem\(S\.keys\.demo_snapshot\)/);
  assert.doesNotMatch(home, /localStorage\.clear\(/);
  assert.doesNotMatch(home, /removeItem\(S\.keys\.settings\)/);
  assert.doesNotMatch(home, /removeItem\(S\.keys\.schema_version\)/);
  assert.doesNotMatch(home, /km_onboarded_v1[\s\S]{0,160}removeItem/);
  assert.match(home, /当前是示例厨房/);
  assert.match(home, /退出示例厨房/);
  assert.match(home, /你的设置不会被删除/);
  assert.match(styles, /\.demo-kitchen-banner/);
  assert.match(styles, /\.demo-kitchen-exit/);
});

test('demo kitchen keeps text-first entry and receipt tab availability', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /#obManual'\)\.onclick = \(\) => openBatchInputModal\(pack, \{ onRoute, initialTab: 'text' \}\)/);
  assert.match(home, /data-tab="receipt"/);
  assert.match(home, /id="batchReceiptFile" accept="image\/\*"/);
  assert.match(home, /data-tab="text"/);
});
