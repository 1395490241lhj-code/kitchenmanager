import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

test('到期食材弹窗加入买菜保留局部反馈并补充 Toast', () => {
  const home = read('src/views/home-view.js');

  assert.match(home, /li\.querySelector\('\.km-expiry-add'\)\.onclick = \(e\) => \{[\s\S]*?addShoppingItem\(it\.name/);
  assert.match(home, /showToast\('已加入买菜清单', \{ tone: 'success' \}\);[\s\S]*?btn\.textContent = '已加入';[\s\S]*?btn\.disabled = true;[\s\S]*?onChange\(\);/);
});

test('库存页快速加入成功后显示 Toast，空输入不显示 success Toast', () => {
  const inventory = read('src/views/inventory-view.js');

  assert.match(inventory, /if \(!count\) \{[\s\S]*?showInlineStatus\(statusEl, '先写一两样食材吧。', 'info'\);[\s\S]*?return 0;[\s\S]*?\}/);
  assert.match(inventory, /showInlineStatus\(statusEl, `已加入 \$\{count\} 样食材`, 'ok'\);[\s\S]*?showToast\(`已加入 \$\{count\} 样食材`, \{ tone: 'success' \}\);/);
  assert.match(inventory, /if \(textarea\) textarea\.value = '';/);
  assert.match(inventory, /renderTable\(\);/);
  assert.match(inventory, /setTimeout\(\(\) => onInventoryChanged\(\), 1500\);/);
});

test('inventory-view import 格式拆开，不再出现 ;import', () => {
  const inventory = read('src/views/inventory-view.js');

  assert.doesNotMatch(inventory, /;import/);
  assert.match(inventory, /showToast\s*\n\} from '\.\.\/components\/status\.js\?v=219';\nimport \{ markShoppingItemsStockedIn \} from '\.\.\/shopping\.js\?v=219';/);
});

test('旧 is-previewable 推荐卡样式已清理，搜索结果卡交互样式保留', () => {
  const styles = read('styles.css');

  assert.doesNotMatch(styles, /is-previewable/);
  assert.match(styles, /\.target-recipe-result-card:hover/);
  assert.match(styles, /@media \(prefers-reduced-motion: reduce\) \{[\s\S]*?\.target-recipe-result-card[\s\S]*?transition: none;/);
});
