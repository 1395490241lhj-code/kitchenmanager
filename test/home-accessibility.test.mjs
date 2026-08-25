import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

const home = read('src/views/home-view.js');
const styles = read('styles.css');

test('tabs and their panel are wired together by id', () => {
  assert.match(home, /class="wx-tab" data-tab="plan" role="tab" id="wxTabPlan" aria-controls="wxTabPanel"/);
  assert.match(home, /class="wx-tab" data-tab="recs" role="tab" id="wxTabRecs" aria-controls="wxTabPanel"/);
  assert.match(home, /class="wx-body" role="tabpanel" id="wxTabPanel"/);
  // 面板的名字直接取自选中的 tab 元素，不维护 tab 名 → id 的映射表。
  assert.match(home, /if \(active\) body\.setAttribute\('aria-labelledby', t\.id\);/);
});

test('switching a tab maintains aria-selected and roving tabindex together', () => {
  assert.match(home, /t\.setAttribute\('aria-selected', String\(active\)\)/);
  assert.match(home, /t\.tabIndex = active \? 0 : -1/);
  // 初始标记为 -1，等 switchTab 把选中的那个抬回 0；避免首帧出现两个 Tab 停靠点。
  assert.match(home, /id="wxTabPlan"[^>]*aria-selected="false" tabindex="-1"/);
  assert.match(home, /id="wxTabRecs"[^>]*aria-selected="false" tabindex="-1"/);
});

test('arrow/Home/End keys drive the tablist and move focus with the selection', () => {
  assert.match(home, /import \{ nextTabIndex \} from '\.\.\/utils\/tablist-keyboard\.js/);
  assert.match(home, /t\.onkeydown = \(event\) => \{[\s\S]*?nextTabIndex\(event\.key, index, tabs\.length\)/);
  // 未被 tablist 认领的键必须原样放行，否则会吃掉 Tab / Shift+Tab。
  assert.match(home, /if \(target < 0\) return;\s*\n\s*event\.preventDefault\(\);/);
  assert.match(home, /switchTab\(tabs\[target\]\.dataset\.tab\);\s*\n\s*tabs\[target\]\.focus\(\);/);
});

test('stat pills announce the current count, not just the label', () => {
  // 旧写法 aria-label="查看临期" 会盖掉按钮内容，把唯一有信息量的数字读没了。
  assert.match(home, /aria-label="\$\{escapeHtml\(label\)\} \$\{escapeHtml\(String\(value \|\| 0\)\)\} 项，查看详情"/);
  assert.doesNotMatch(home, /aria-label="查看\$\{escapeHtml\(label\)\}"/);
  // 容器要有 role 才能让 aria-label 生效；裸 div 上的 aria-label 会被辅助技术忽略。
  assert.match(home, /class="wx-summary-stats" role="group" aria-label="今日厨房状态"/);
});

test('the recommendation card no longer poses as a button around its own buttons', () => {
  const cycling = home.slice(
    home.indexOf('const bindRecommendationCycling'),
    home.indexOf('const renderWxSectionIntro')
  );
  assert.ok(cycling.length > 0, '应能定位到 bindRecommendationCycling');
  assert.doesNotMatch(cycling, /setAttribute\('role', 'button'\)/);
  assert.doesNotMatch(cycling, /setAttribute\('tabindex', '0'\)/);
  assert.doesNotMatch(cycling, /onkeydown/);
  // swipe / 轻点手势保留。
  assert.match(cycling, /cardWrap\.onpointerdown/);
  assert.match(cycling, /cardWrap\.onpointerup/);
  assert.match(cycling, /cardWrap\.onclick/);
  // 键盘等价路径：「换一批 ›」的出现条件正是 stepRecommendation(1) 会生效的条件。
  assert.match(home, /hasNextLocal \? '<button type="button" class="wx-mini-btn" id="wxRecNext">换一批 ›<\/button>' : ''/);
  assert.match(home, /if \(nextBtn\) nextBtn\.onclick = \(\) => stepRecommendation\(1\)/);
});

test('home tab and stat pill have their own visible focus ring in both themes', () => {
  // 这两个是首页最重要的控件，之前恰好漏在全局 focus-visible 列表之外。
  assert.match(styles, /\.wx-tab:focus-visible \{\s*outline: 2px solid var\(--primary\);/);
  assert.match(styles, /\.wx-stat-pill:focus-visible \{\s*outline: 2px solid var\(--primary\);/);
  // 用 --primary 实色而不是半透明，浅色/深色下都能满足非文本 3:1。
  assert.doesNotMatch(styles, /\.wx-tab:focus-visible \{\s*outline: 2px solid rgba/);
});

test('home controls reach a 44px target without overlapping each other', () => {
  assert.match(styles, /\.wx-stat-pill \{[\s\S]*?min-height: 32px;/);
  assert.match(styles, /\.wx-stat-pill::after \{[\s\S]*?inset: -6px 0;/);
  assert.match(styles, /\.wx-panel\.is-two-tab \.wx-tab \{\s*min-height: 40px;/);
  assert.match(styles, /\.wx-tab::after \{[\s\S]*?inset: -2px 0;/);
  assert.match(styles, /\.wx-mini-btn \{[\s\S]*?min-height: 36px;/);
  assert.match(styles, /\.wx-mini-btn::after \{[\s\S]*?inset: -4px 0;/);
  assert.match(styles, /\.wx-rec-card ~ \.wx-actions \.wx-mini-btn \{\s*min-height: 36px;/);
  // 外扩只做纵向，横向留 0；行间距必须 >= 上下外扩之和，否则换行后命中区会叠在一起。
  assert.match(styles, /\.wx-summary-stats \{[\s\S]*?gap: 12px;/);
  assert.match(styles, /\.wx-actions \{[\s\S]*?gap: 8px;/);
});
