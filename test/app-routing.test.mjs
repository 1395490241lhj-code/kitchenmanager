import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import vm from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();

// app.js 是浏览器入口，onRoute 没有导出。为了不为测试改变运行时代码，也不新增
// DOM 依赖，这里从 app.js 取出实际的 onRoute 函数体，在受控替身中执行。测试的是
// 真实分支、真实 hash 判断和真实 active-class 调用，而不是字符串匹配。
function getOnRouteSource() {
  const source = readFileSync(join(root, 'app.js'), 'utf8');
  const start = source.indexOf('async function onRoute() {');
  const end = source.indexOf("window.addEventListener('hashchange', onRoute);");
  assert.ok(start >= 0, 'app.js 应声明 onRoute');
  assert.ok(end > start, 'app.js 应在注册 hashchange 前结束 onRoute');
  return source.slice(start, end);
}

function createClassList() {
  const values = new Set();
  return {
    add: (...names) => names.forEach(name => values.add(name)),
    remove: (...names) => names.forEach(name => values.delete(name)),
    contains: name => values.has(name)
  };
}

function createRouteHarness() {
  const nav = Object.fromEntries([
    'nav-today',
    'nav-inventory',
    'nav-shop',
    'nav-recipe',
    'nav-me'
  ].map(id => [id, { id, classList: createClassList() }]));
  const app = {
    rendered: null,
    innerHTML: '',
    replaceChildren(view) {
      this.rendered = view;
    }
  };
  const location = {
    hash: '',
    replacements: [],
    replace(nextHash) {
      this.replacements.push(nextHash);
      this.hash = nextHash;
    }
  };
  const makeView = kind => () => ({ kind });
  const context = {
    app,
    cachedBaseWithCompletion: { kind: 'base-pack' },
    console: { error() {} },
    el: selector => nav[selector.slice(1)] || null,
    els: selector => {
      assert.equal(selector, 'nav a');
      return Object.values(nav);
    },
    getCurrentPack: async () => ({ kind: 'pack' }),
    location,
    migrationError: null,
    renderHome: makeView('today'),
    renderInventoryTab: makeView('inventory'),
    renderRecipeDetail: makeView('recipe-detail'),
    renderRecipeEditor: makeView('recipe-editor'),
    renderRecipes: makeView('recipes'),
    renderSettings: makeView('settings'),
    renderShopping: makeView('shopping')
  };

  vm.createContext(context);
  vm.runInContext(`${getOnRouteSource()}\nglobalThis.__onRoute = onRoute;`, context, {
    filename: 'app-routing-harness.js'
  });
  return { app, location, nav, onRoute: context.__onRoute };
}

function assertOnlyActive(nav, expectedId) {
  for (const [id, item] of Object.entries(nav)) {
    assert.equal(item.classList.contains('active'), id === expectedId, `${id} active state`);
  }
}

test('空 hash 由实际 onRoute 重定向到 #today，并在 hashchange 后渲染今天首页', async () => {
  const harness = createRouteHarness();

  await harness.onRoute();
  assert.deepEqual(harness.location.replacements, ['#today']);
  assert.equal(harness.app.rendered, null, '重定向分支本身不应先渲染旧页面');

  await harness.onRoute(); // 模拟 location.replace 后浏览器触发的下一次路由处理。
  assert.equal(harness.app.rendered.kind, 'today');
  assertOnlyActive(harness.nav, 'nav-today');
});

test('实际 onRoute 为五个稳定入口选择正确视图并同步 Dock active 状态', async t => {
  const cases = [
    ['#today', 'today', 'nav-today'],
    ['#inventory', 'inventory', 'nav-inventory'],
    ['#shopping', 'shopping', 'nav-shop'],
    ['#recipes', 'recipes', 'nav-recipe'],
    ['#settings', 'settings', 'nav-me']
  ];

  for (const [hash, viewKind, activeId] of cases) {
    await t.test(hash, async () => {
      const harness = createRouteHarness();
      harness.location.hash = hash;

      await harness.onRoute();

      assert.equal(harness.app.rendered.kind, viewKind);
      assertOnlyActive(harness.nav, activeId);
    });
  }
});
