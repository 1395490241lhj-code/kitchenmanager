# 大众川菜 1979 —— Production Batch 2 Dry-run

生成时间: 2026-08-07

基线: main/origin/main=b047f62（Batch 1 已正式 promotion，ledger 5 道），applicationReady=False

本轮仅产出 dry-run artifact，不写任何 workspace production 文件，不执行真实 promotion。临时目录中用真实 `scripts/curate-recipes.js` 完整模拟 overlay -> curate 链。

## 候选漏斗（34 -> 24 -> 22 -> 5）

- 剩余 not-promoted new-recipe-candidate：**34** 道（39 - Batch 1 已 promotion 5）。
- Batch 1 硬性 gate（frozen readiness 规则原样复用）后：**24** 道。
  - methodOnly conversionWarning：p129 凉拌猪肺、p130 蕃茄丝瓜肉片汤
  - 非精确/mixed 数量（quantityReadiness≠exact-comparable）：p201 炝黄瓜、p203 炝绿豆芽、p207 炝莲花白
  - consumed 双数量语义：p222 酱胡豆、p224 拌鱼香豌豆、p226 蛋酥花仁
  - same-for-each 组合数量：p130 蕃茄丝瓜肉片汤、p144 黄焖鸭子、p201 炝黄瓜、p207 炝莲花白、p211 花仁萝卜干
  - （p130/p201/p207 同时命中多类原因；本轮 34 道候选中无 unallocated-group-total 命中，该 memberQuantityMode 值只出现在候选池外的条目中）
- Batch 2 runtime gate（仅 core ingredients）后：**22** 道 eligible。
  - 被 unresolved-name-match 阻塞：**p137 椒麻鸡块（子公鸡）**、**p161 拌鸡血（鸡血）**
- 机械排序（expected-unit-confirmation 少 -> 特殊结构少 -> ingredient 少 -> method 步骤少 -> entryId 升序）取前 **5**。

## 机械入选 5 道

| entryId | name | tags | core 兼容 | unit-confirmation |
| --- | --- | --- | --- | --- |
| dz1979-p187 | 糖醋子姜 | 川菜 / 蔬菜类 | exact-compatible ×1 | 0 |
| dz1979-p202 | 白油鲜笋 | 川菜 / 蔬菜类 | exact-compatible ×1 | 0 |
| dz1979-p205 | 青椒炒大头菜 | 川菜 / 蔬菜类 | exact-compatible ×2 | 0 |
| dz1979-p188 | 姜汁蕹菜 | 川菜 / 蔬菜类 | exact-compatible ×1 | 0 |
| dz1979-p196 | 醋熘白菜 | 川菜 / 蔬菜类 | exact-compatible ×1 | 0 |

5 道全部 unit-confirmation=0，排序前 5 与机械结果一致；未硬编码。

## Batch 2 runtime gate 说明

- 只对 role=core 的 production ingredient 做三分类（复用 Batch 1 runtime audit 已验证逻辑，抽取为 `scripts/dazhong-runtime-compatibility.mjs`）。
- unresolved-name-match => 阻塞；expected-unit-confirmation => 允许但逐项记录；non-core 不参与 name gate。
- 禁止新增 alias / unit 换算：仅使用现有 `src/ingredients.js` / `src/inventory.js` canonicalization。
- 本轮入选 5 道无 expected-unit-confirmation 条目（unitConfirmationDetails 均为空）。

## 转换预览要点

- method 仅由 canonical `methodSummary.steps` 拼接，不补写、不现代化扩写。
- ingredients 直接复用 readiness 已审核 `productionIngredientPlan`，qty/unit 不重新推算。
- source 原始信息（bookPage/pdfPage/characteristicsSummary/uncertainties/confirmedReadings）只进 `provenanceRecord`，production recipe 仅含 schema 支持字段。
- 每道均含 proposedOverlayRecipe / proposedOverlayIngredients / proposedCuratedRecipe / proposedCuratedIngredients / provenanceRecord / sourceToProductionTransformNotes / quantityReviewPreview 条目 / coreRuntimeCompatibility。

## Quantity review preview

- 29 条记录（5 道全部带 qty/unit 条目），逐条来自 readiness audited productionIngredientPlan；raw/normalized 数量取自 canonical source。
- unit 全部在白名单（g|ml|个|只|…），normalizedQuantity.kind 全部 exact-mass/exact-count，normalizeIngredientAmount finite 全部通过；不伪造任何非精确量。
- 真实 promotion 时另行生成正式 quantity-review artifact（与 Batch 1 同构）。

## 临时目录模拟结果

向 temp overlay 追加 5 道（newRecipes + newRecipeIngredients，`recipeIngredientOverrides` 原样保留），运行真实 curate：

- HEAD curated **131** -> 模拟 **136**：严格 current + 5；新增 5 个 ingredient map
- existing recipe delete: **0**，recipe object modify: **0**，ingredient map modify: **0**
- `data/sichuan-recipes.json`（Full 库）：**0 变化**
- 5 道均有完整 method + tags；5 个新 ingredient map 均完整（>=2 项）

## 辅助生成文件预期变化

- `recipe-curation-removed.json`: **不变**（5 道均有 method，不进 removed）
- `recipes-needing-completion.json`: **不变**
- `recipe-curation-summary.md`: 仅统计计数变化：
  - 有效集 327 -> 332；overlay 净增 63 -> 68；curated 保留 131 -> 136
  - 有做法直接保留 110 -> 115；补全 method 110 -> 115；补全 ingredients 73 -> 78

本轮不写真实 production 文件；真实 production git diff = 0。

## PWA 发布可见性（只读检查）

- overlay 与基包均以 `cache: 'no-store'` fetch；`sw.v18.js` 对 `data/*.json` 走 **networkFirst**。
- 结论：真实 promotion 后在线用户立即获得新数据，不需要同步更新 cache-bust/version/service-worker 版本。

## iOS 解码兼容

生成后的 curated 结构 `recipes[]{id,name,method?,tags?}` + `recipe_ingredients[id][{item,qty?,unit?}]` 可直接被 `RecipeService.RemoteRecipe/RemoteIngredient` 解码（batch2 兼容性校验通过）。

## 验证

- 5 道全部满足硬性 gate + runtime gate（unresolved=0）；生产真实文件 git diff = 0
- canonical / crosswalk / readiness / Batch 1 dry-run / quantity-review / ledger / runtime-audit 0 变化（frozen）
- temp curate = current curated + exactly 5，existing 0 semantic drift
- PWA runtime（模拟 overlay）每道恰好出现一次；Full 基包 0 变化
- JSON parse、`node --check`、batch2 tests、batch1 frozen tests、recipe curation reproducibility tests、related runtime/source-restoration tests、`git diff --check`
