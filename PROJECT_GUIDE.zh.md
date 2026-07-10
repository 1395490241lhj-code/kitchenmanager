# PROJECT_GUIDE.zh.md — Kitchen Manager 开发约束与架构指南（中文版）

> 本文件是 [`PROJECT_GUIDE.md`](./PROJECT_GUIDE.md)（英文版）的中文对照版，用于约束后续 AI 辅助开发（Claude Code / Cursor / Copilot 等）。
> 两份内容应保持同步；如有冲突，以代码实际行为为准。**修改代码前必须先读本文件。**
> 基于 `README.md`、`package.json`、`app.js`、`src/storage.js`、`src/views/`、`styles.css`、`server.js` 的真实代码总结，非泛化团队规范。

---

## 0. 一句话技术栈

**无框架、无构建步骤的原生 ES Module PWA**（HTML + CSS + 原生 JS）+ 一个轻量 Express 服务端（`server.js`，仅做静态托管 + AI/抓取代理）。数据**本地优先**，全部存在浏览器 `localStorage`。目标是逐步演进为可上架的 iOS App。

- 运行：`npm install && npm start` → `http://localhost:3000`（全栈，含 `/api/*`）；或 `python -m http.server`（纯静态，无 `/api/*`）。
- 依赖仅 `express` + `axios`。Node ≥ 18。**没有 Webpack/Vite/Babel/TS 编译**——写的就是浏览器直接跑的代码。

---

## 1. 项目定位

- **本地优先（Local-First）的家庭厨房管理工具**：库存（食材管理）、菜谱、购物清单、今日计划、AI 小票识别、AI 菜谱导入、本地备份。
- **隐私第一**：所有用户数据只在本地 `localStorage`；原始菜谱数据只读，用户改动以 Overlay 补丁形式存在，可随时安全重置。
- **移动端优先**：主要场景是手机（iPhone 390px 宽度为基准）。所有 UI 必须先满足窄屏。
- **渐进式演进**：不追求一次性重写，保持现有功能可用，小步快跑。

---

## 2. 核心用户路径（必须始终保持可用）

1. **录入库存** → 食材管理页手动加 / 拍小票 OCR 一键入库。
2. **看推荐 / 排计划** → 首页根据库存推荐菜谱，加入「今日计划」。
3. **做菜结算** → 今日计划点「🍳 做好了 / ✓ 全部做完」→ 弹「主厨校准舱」→ 确认扣减库存。
4. **即兴烹饪** → 首页今日计划行「🍳 即兴烹饪」→ 行内微调零星配料库存 → 记录完成。
5. **补货** → 缺货核心食材自动进购物清单 → 买完「全部入库」回流库存。
6. **常备货架** → 盐/蛋/奶等常备品双态（充足/不足）切换。
7. **菜谱管理** → 浏览/编辑/AI 草稿/链接&截图导入菜谱。
8. **备份** → 设置页导出/导入 `.json`（默认不含 API Key）。

> 改动任一模块时，先确认上述闭环不被破坏（尤其是「做菜→扣库存→补货→入库」这条主链）。

---

## 3. 当前页面结构（Hash 路由，见 `app.js onRoute()`）

| Hash | 视图函数（文件） | 说明 |
| --- | --- | --- |
| 空 hash | 重定向到 `#today` | 默认入口，不直接渲染页面 |
| `#today` | `renderHome` (`views/home-view.js`) | 今天 / 厨房首页：今日计划、推荐、快速操作 |
| `#inventory` | `renderInventoryTab` (`app.js` → `views/inventory-view.js`) | 独立食材库存页，包含新鲜食材与家里常备分段 |
| `#shopping` | `renderShopping` (`views/shopping-view.js`) | 买菜清单：待买、已买和入库确认 |
| `#recipes` | `renderRecipes` (`views/recipes-view.js`) | 菜谱列表 |
| `#recipe:id` | `renderRecipeDetail` (`views/recipe-detail-view.js`) | 菜谱详情（食材/调料双清单 + 做法 + 计划/做完按钮） |
| `#recipe-edit:id` | `renderRecipeEditor` (`views/recipe-editor-view.js`) | 菜谱编辑器（含 AI 草稿、导入） |
| `#settings` | `renderSettings` (`views/settings-view.js`) | 设置：主题、AI Key、菜谱库模式、备份、重置 |

**底部导航 Dock**（`index.html`）：今日(`#today`) / 食材(`#inventory`) / 买菜(`#shopping`) / 菜谱(`#recipes`) / 我的(`#settings`)。

> 当前稳定语义为 `#today` 首页、`#inventory` 食材、`#shopping` 买菜；未经产品确认，不要再次交换这些含义。当前实现没有为旧的「`#inventory` 首页」书签新增兼容跳转，后续也不要自行补加行为。

---

## 4. 推荐的未来页面结构（演进方向，不是立即重构）

- **保留五个底部 Tab**（今日 / 食材 / 买菜 / 菜谱 / 我的），这是当前稳定的移动端导航结构。
- 逐步把「今日计划」「即兴烹饪」「AI 灵感」收敛为首页内的稳定区块组件，便于将来抽成原生页面。
- iOS 化时：用 Capacitor / WKWebView 包壳作过渡；**`localStorage` 不可作为长期持久层**（WKWebView 可能清空），需引入持久存储 + 用 `backup.js` 的导出结构作迁移桥。
- 新页面/新区块一律走「`renderX(pack, { onRoute }) → DOM 节点`」模式，禁止引入第二套渲染范式（不要混入框架）。

---

## 5. 当前数据结构与 localStorage Key

**唯一数据入口是 `src/storage.js` 的 `S`**：`S.load(key, default)` / `S.save(key, value)`，key 一律用 `S.keys.*`。**禁止**在别处写裸 `localStorage.getItem/setItem('km_...')` 字符串。

| `S.keys.*` | 实际 key | 内容 |
| --- | --- | --- |
| `inventory` | `km_v19_inventory` | 库存数组（见下「库存项」） |
| `plan` | `km_v19_plan` | 今日/未来计划数组（见下「计划项」） |
| `overlay` | `km_v19_overlay` | 用户菜谱补丁（最高优先级，绝不覆盖原始数据） |
| `settings` | `km_v23_settings` | 设置：`theme` / `apiKey` / `apiUrl` / `model` / `recipeLibraryMode` 等 |
| `shopping_items` | `km_v87_shopping_items` | 购物清单数组（见下「购物项」） |
| `recipe_activity` | `km_v2_recipe_activity` | 烹饪账本 `{[id]:{plannedAt,cookedAt(ISO),cookedCount,lastCookedAt(ms)}}` |
| `favorite_recipes` | `km_v80_favorite_recipes` | 收藏菜谱 id |
| `staples` / `pantry_config` | `km_v1_staples` / `km_v1_pantry_config` | 常备货架状态与配置 |
| `ai_recs` / `local_recs` / `rec_time` / `rec_signature` | `km_v48_*` / `km_v97_*` | 推荐缓存 |
| `recipe_usage` | `km_v95_recipe_usage` | 旧版用量统计（与 `recipe_activity` 并存） |
| `schema_version` | `km_schema_version` | 迁移版本（`migrations.js`） |

**核心对象形状（实际字段，改动需保持兼容）：**

- **库存项（inventory，无 `id` 字段，按 `name + kind` 匹配）**：
  `{ name, qty, unit, buyDate, kind('raw'|'dry'), shelf, isFrozen, stockStatus('ok'|'low'|'empty'|'unknown'), unitType?('GEAR'|'PIECE'), gear?(100/75/50/25/0), outOfStockAt?(ms|null), dryPrep?, cookedCount?, lastCookedAt? }`
  - 双轨制：`GEAR`=油表档位（散装菜/调料），`PIECE`=计件（蛋、盒装等）。判定见 `ingredients.getUnitType`。
  - `outOfStockAt`：断货时间戳，驱动「7 天自蒸发 + 幽灵沉底」（`inventory.js`）。
  - 即兴烹饪会给被消耗食材加 `cookedCount` / `lastCookedAt`（食材级反疲劳）。
  - ✅ `loadInventory()` **保留**未知字段（就地补默认值），所以库存项可安全扩展。
- **计划项（plan）**：`{ id, servings, date('YYYY-MM-DD'), isCooked?, cookedAt?(ms) }`；即兴卡为 `{ id:'adhoc_'+ts, name, isCooked:true, cookedAt:ms, date }`（无对应菜谱，由 `menu-plan` 特判渲染为「已完成」存根，受 48h 自隐藏约束）。
- **购物项（shopping_items）**：`{ id, name, qty, unit, source, done, stockedIn, stockedInAt, remark }`。
  - ⚠️ **重大陷阱（FOOTGUN）**：`shopping.loadShoppingItems()` 会用**固定字段集重建每个对象**。**任何新增字段必须同步加进该重建块，否则刷新后被静默丢弃**（`remark` 字段就踩过这个坑）。这与库存项（保留未知字段）**不对称**，改购物数据结构前务必看 `loadShoppingItems`。
- **菜谱 Overlay（overlay）**：`{ version, recipes, recipe_ingredients, deletes }`，用户编辑只进这里，绝不写 `data/*.json`。
- **常备货架配置（pantry_config）**：`{ hidden, overrides, custom }`。

**数据规则：**
- 新增持久化字段：在本文件登记，并接进 `backup.js` 导出/恢复。
- 新增 key：必须加进 `S.keys`。
- 破坏性结构变更：升 `schema_version` 并在 `migrations.js` 加迁移；**迁移失败绝不清空数据**（`app.js` 已有「升级未完成、原数据未清空」保护卡片）。
- 导入/恢复尽量「全有或全无」；无法避免部分恢复时要明确警告。

**已知注意点：**
- 动备份/恢复时，确保把自定义常备货架配置 `km_v1_pantry_config` 与 `km_v1_staples` 一并包含。
- 给购物项加字段时，**务必同步加进 `loadShoppingItems()` 的重建块**（见上方陷阱），否则刷新即丢。

> 数据写入后若需别处生效：调用链里传下来的 `onRoute()` 触发整页重渲染（从存储重新读取，所以必须先 `S.save` 再 `onRoute`）。

---

## 6. 前端模块划分规则

**分层清晰，禁止越层把业务逻辑写进 DOM 操作里。**

- **数据/领域层（`src/*.js`，纯逻辑、不碰 DOM）**
  - `storage.js`：`S`（唯一存储入口）。
  - `ingredients.js`：名称归一化、别名、`SEASONINGS`/`isSeasoning`、`UNIT_TYPE`/`getUnitType`、单位/保质期猜测。
  - `inventory.js`：库存模型、双轨制、做菜扣减（`computeCookDeductions` → `applyCookCalibration`）、TTL（`outOfStockAt` / `syncOutOfStockTimestamp` / `OUT_OF_STOCK_TTL_MS`）。
  - `recommendations.js`：推荐打分、缺货计算、`recipe_activity` 账本（`markRecipeCooked*`）、AI 反疲劳数据。
  - `shopping.js` / `staples.js`：购物清单（合并/分组/来源）、常备货架。
  - `ai.js`：`callCloudAI`（组 prompt + 反疲劳过滤）、小票 OCR、菜谱导入（走 `/api/*`）、`validate*`。
  - `backup.js` / `migrations.js` / `recipe-completion.js` / `theme.js` / `onboarding.js` / `config.js`。
  - `utils/recipe-sanitizer.js`：调料分类器（`SEASONING_REGEX` + `isSeasoningName` + `splitIngredients`）。
- **视图层（`src/views/*.js`）**：每个导出 `renderX(pack, { onRoute, ... }) → HTMLElement`。组织 DOM、绑事件、调领域层。**不在视图里重复领域逻辑**。
- **组件层（`src/components/*.js`）**：可复用片段——`menu-plan`（今日计划 + 做菜流）、`modal`（校准舱/小票确认）、`recipe-card`、`pantry-shelf`、`status`（`escapeHtml`/`escapeOptionAttr`/`setInlineStatus`/`brieflyConfirmButton`）。
- **`dom.js`**：`el(sel)` / `els(sel)` 选择器助手。

**规则：**
1. 新业务规则放领域层/组件，视图只负责「取数据 → 渲染 → 绑事件 → 回写并 `onRoute`」。
2. 复用优先：判定调料用 `recipe-sanitizer`/`ingredients.isSeasoning`，不重写正则；档位逻辑用 `inventory` 现成函数。
3. 视图渲染函数必须返回单个 DOM 节点，由 `app.js` 的 `app.replaceChildren(view)` 挂载。
4. 跨页/异步副作用通过 `onRoute()` 收口，不手动操作其他视图的 DOM。

**不经明确批准不得引入：** React/Vue/Svelte/Angular 等框架；Vite/Webpack/Rollup 等打包器；TypeScript 迁移；CSS 框架/外部 UI 库；大型新依赖。

**版本/缓存规则：**
- 改了被浏览器 import 的 JS/CSS 后，运行 `node scripts/stamp-version.js` 统一改 `?v=<数字>`。
- 若发布需让 Service Worker 缓存也失效，**另外**手动 bump `sw.v18.js` 的 `CACHE_NAME`（`?v=` 戳不会重命名 SW 缓存）。
- 不要手动逐个改版本查询参数，除非改动极小且范围明确。

---

## 7. UI 设计规范

- **移动优先，390px 基准**：任何新 UI 先在 iPhone 390px 宽下验证（不溢出、可点、不挤压）。触控目标 ≥ 32px。
- **iOS 液态玻璃风**：毛玻璃（`backdrop-filter` + glass tokens）、大圆角、柔和阴影；`--primary` 蓝 / `--accent` 绿 / `--warning` 橙 / `--danger` 红。
- **深浅色**：由 `<html data-theme="light|dark">` 驱动（`theme.js applyTheme` 用 `setAttribute` 整体切换）。**不要用 `classList.add('dark')` 那套**，也没有 Tailwind。
- **就地编辑优于弹窗**：能行内改的（库存档位/件数、购物备注、即兴配料）就行内改，减少弹窗层级。
- **高密度但透气**：列表用紧凑网格/行配合合理 padding；状态用药丸/圆点/进度条等微型控件。
- **⚠️ 关于 Tailwind**：本项目**不使用 Tailwind**。若任务描述给了 `class="grid grid-cols-3 bg-slate-50 dark:bg-zinc-900/50 ..."` 这类 Tailwind 串，**视为设计规格**，用项目自有的语义 CSS 类 + `:root` token 等价实现，并补 `html[data-theme="dark"]` 深色覆盖。**不要把 Tailwind 原子类直接写进 HTML**（不会生效）。

---

## 8. CSS 命名与设计 Token 规则

- **单文件 `styles.css`**（约 5k 行）。新样式追加到相关区块附近，写中文注释分隔块。
- **命名**：kebab-case 语义类，按「模块前缀-元素-修饰」组织，例如 `inv-card-v2`、`shopping-remark-input`、`km-tray-grid`、`km-gear-dot.is-active`。状态用 `.is-xxx`（`.is-active`/`.is-collapsed`/`.is-cooked`）。`km-` 前缀通常表示通用浮层/液态组件。
- **必须用 `:root` 设计 token，禁止硬编码主题色**：
  - 颜色：`--primary` `--accent` `--warning` `--danger` `--text-main` `--text-secondary` `--separator` `--bg-card` `--bg-input`。
  - 状态：`--status-{ok|warn|bad|info|draft}-{bg|text|border}`。
  - 玻璃：`--glass-*`、`--glass-blur-*`、`--glass-{hero|panel|cell|control|nav}-fill`。
  - 圆角：`--radius-{s|m|l|nav}`；阴影：`--shadow-{sm|card|float|hero|nav}`。
  - 允许例外：彩色按钮/渐变上的前景白色（`#fff`）、档位/品牌强调色等设计强约束值可字面化，但要就近注释。
- **深色模式**：凡手写浅色字面色的元素，必须补 `html[data-theme="dark"] .xxx {}` 覆盖；优先用 token（自动适配）避免双写。
- **响应式**：用 `@media (min-width: ...)` 渐进增强（如网格列数 3 升 4）。不要假设宽屏。

---

## 9. 数据安全与隐私原则

1. **本地优先**：用户数据只进 `localStorage`，不上传第三方（AI 调用只发必要的菜名/库存名/文案/图片，且由用户主动触发）。
2. **API Key 三不**：不内置（`config.js` 默认空）、**不写进备份**（`backup.js` 导出剥离 `apiKey`）、不打印日志。改备份/导出逻辑必须保持剥离。
3. **原始数据只读**：菜谱原始 JSON 与补全包不可写；用户改动只进 `overlay`。任何「重置」都应能回到「基础 + 补全」默认态。
4. **就地重建 ≠ 丢字段**：扩展会被 `load*` 重建的结构（如 `shopping_items`）时，务必同步重建块（见 §5 陷阱）。
5. **迁移防丢**：动 `localStorage` 结构/key 走 `migrations.js`；迁移失败已有保护，不要绕过它直接清库。
6. **XSS 防护**：所有进 `innerHTML` 的动态内容必须 `escapeHtml()`（属性值用 `escapeOptionAttr()`）。新增模板拼接一律转义。

---

## 10. AI 功能边界

- **AI 产出一律是「草稿」**，必须经校验/清洗后才落库：
  - 菜谱导入：前端 `ai.validateImportedRecipe` + 后端 `server.js sanitizeRecipe`（双保险：常备品过滤、`qty` 必为数字字符串、`method` 剥序号前缀、食材/调料双数组）。
  - 推荐：`callCloudAI` 返回经 `validateRecommendationResult` 校验；菜名应来自菜谱库候选池。
- **AI 绝不自动改库存**：做菜扣减必须经用户在「主厨校准舱」确认；小票识别必须经确认弹窗再入库。
- **反疲劳**：`callCloudAI` 喂 prompt 前做硬过滤（近 72h 做过的菜移出候选）+ 软降权（`cookedCount` Top5 追加避让规则）。新加 AI 约束走 prompt，不散落在视图里。
- **密钥与模型在后端**：链接抓取 `/api/xhs-extract`、解析 `/api/ai-parse` 走 `server.js`，密钥来自环境变量（`OPENAI_API_KEY` / `OPENAI_BASE_URL` / `OPENAI_MODEL`）。前端走后端代理，避免 CORS 与泄露。
- **优雅降级**：纯静态模式无 `/api/*` 时，链接导入要提示改用文字/截图；AI 不可用要回退本地推荐，不能白屏。

---

## 11. 禁止事项

1. ❌ **推倒重写 / 一次性大改多页**。小步、可回滚。
2. ❌ 引入框架、打包器、TypeScript、CSS 框架（含 Tailwind 运行时）、新重依赖——本项目以「零构建、原生」为约束。
3. ❌ 裸用 `localStorage.getItem/setItem('km_...')`；一律走 `S` + `S.keys`。
4. ❌ 把领域逻辑（判定/扣减/分类/打分）写死在视图 DOM 操作里；应放领域层并复用。
5. ❌ 删除或悄悄改语义已有功能/字段，除非在交付说明里给出迁移方案。
6. ❌ 改 hash 路由值（`#inventory`/`#shopping` 等）或现有 `S.keys` 字符串值（破坏已有用户数据/书签）。
7. ❌ 把 Tailwind 原子类直接塞进 HTML（不生效）。
8. ❌ 未转义就把动态内容拼进 `innerHTML`。
9. ❌ 把 API Key 写进备份/日志/前端常量。
10. ❌ **手动逐个改 `?v=NNN` 版本号**——必须用 `node scripts/stamp-version.js`（见 §12）。
11. ❌ 在 `migrations` 之外直接清空/重写 `localStorage`。

---

## 12. 每次开发前后检查清单

### 开发前（Before）
- [ ] 读本文件相关章节 + 目标功能的**调用链**（视图 → 组件 → 领域层 → 存储）。
- [ ] 确认改动属于哪一层（§6），避免越层。
- [ ] 若动数据结构：确认是否经 `load*` 重建（购物项陷阱 §5）、是否需 `migrations.js`、是否影响 `backup.js` 导出。
- [ ] 复用现有能力（调料分类、档位、扣减、转义、token），不重复造轮子。
- [ ] 先识别潜在 bug / 数据丢失风险并说明。

### 开发后（After）
- [ ] **本地验证**：起服务跑一遍受影响的主用户路径（§2），尤其「做菜→扣库存→补货→入库」闭环；浏览器无 JS 报错。
- [ ] **390px 移动端**自查：无横向溢出、控件可点、深浅色都正常（切 `data-theme` 验证）。
- [ ] **数据安全**：刷新后新增字段不丢；备份导出不含 `apiKey`；动态内容已转义。
- [ ] **不回归**：未删除/破坏既有功能；hash 与 `S.keys` 未变。
- [ ] **缓存版本号**：若改了任何前端文件，发布前运行
      `node scripts/stamp-version.js`（自动 +1）或 `node scripts/stamp-version.js <号>`，
      并按需 bump `sw.v18.js` 的 `CACHE_NAME`。
- [ ] **交付说明**：列出「改了哪些文件 / 为什么 / 风险点 / 是否需迁移」。

---

### 附：发布缓存破坏（Cache Busting）速记
前端用 `?v=<数字>` 查询参数跳过强缓存，分散在几十处。**永远用脚本统一改**：
```bash
node scripts/stamp-version.js        # 在当前最大值 +1
node scripts/stamp-version.js 207    # 指定版本号
```
脚本只改 `?v=<数字>`，不动文件名里的版本（如 `sw.v18.js`）和运行时数据包版本。Service Worker 的缓存清理另由 `sw.v18.js` 的 `CACHE_NAME` 控制——发布大改时一并 +1。
