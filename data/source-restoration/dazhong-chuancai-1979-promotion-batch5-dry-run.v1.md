# 大众川菜 1979 —— Production Batch 5 Dry-run

生成时间: 2026-08-07

基线: main/origin/main=af6a9e80a60610fb094bf55531f6532f512f27e2（Batch 1/2/3/4 已正式 promotion，共 20 道；ledger 见 `dazhong-chuancai-1979-production-promotions.v1.json`），applicationReady=False

本轮仅产出 dry-run artifact，不写任何 workspace production 文件，不执行真实 promotion。临时目录中用真实 `scripts/curate-recipes.js` 完整模拟 overlay -> curate 链。

## 候选漏斗（19 -> 9 -> 7 -> 5）

- 剩余 not-promoted new-recipe-candidate：**19** 道（39 - Batch 1/2/3/4 已 promotion 20）。
- Batch 1 硬性 gate（frozen readiness 规则原样复用）后：**9** 道。
  - methodOnly conversionWarning：p129 凉拌猪肺、p130 蕃茄丝瓜肉片汤
  - same-for-each 组合数量：p130 蕃茄丝瓜肉片汤、p144 黄焖鸭子、p201 炝黄瓜、p207 炝莲花白、p211 花仁萝卜干
  - 非精确/mixed 数量（quantityReadiness≠exact-comparable）：p201 炝黄瓜、p203 炝绿豆芽、p207 炝莲花白
  - consumed 双数量语义：p222 酱胡豆、p224 拌鱼香豌豆、p226 蛋酥花仁
  - （p130/p201/p207 同时命中多类原因）
- Batch 2/3/4 已验证 runtime gate（仅 core ingredients，复用 `scripts/dazhong-runtime-compatibility.mjs`）后：**7** 道 eligible。
  - 被 unresolved-name-match 阻塞：**p137 椒麻鸡块（子公鸡）**、**p161 拌鸡血（鸡血）**（本轮不修，按要求排除在候选之外，与 Batch 2/3/4 结论一致）
- 机械排序（expected-unit-confirmation 少 -> 特殊结构少 -> ingredient 少 -> method 步骤少 -> entryId 升序）取前 **5**（eligible=7，充足，无需降低 gate）。

## 机械入选 5 道

| entryId | productionId | name | tags | core 兼容 | unit-confirmation |
| --- | --- | --- | --- | --- | --- |
| dz1979-p162 | dz1979-p162 | 豆瓣鱼 | 川菜 / 禽蛋鱼类 | exact-compatible ×1 | 0 |
| dz1979-p186 | dz1979-p186 | 蒜泥拌黄瓜 | 川菜 / 蔬菜类 | exact-compatible ×2, unit-confirmation ×1 | 1 |
| dz1979-p185 | dz1979-p185 | 麻酱青笋尖 | 川菜 / 蔬菜类 | exact-compatible ×2, unit-confirmation ×1 | 1 |
| dz1979-p219 | dz1979-p219 | 过浆豆花 | 川菜 / 蔬菜类 | exact-compatible ×3, unit-confirmation ×1 | 1 |
| dz1979-p213 | dz1979-p213 | 青笋拌折耳根 | 川菜 / 蔬菜类 | exact-compatible ×3, unit-confirmation ×1 | 1 |

排序结果与 checkpoint 提示的 p162/p186/p185/p219/p213 一致——由本轮重新机械计算得出，未直接采用该线索。eligible 池中排名 6/7 为 p159、p168（未入选，供下一轮参考）。

## Batch 5 runtime gate 说明

- 复用 Batch 2/3/4 已验证的 runtime gate 与 `scripts/dazhong-runtime-compatibility.mjs`，本轮不新增/修改任何分类逻辑。
- 只对 role=core 的 production ingredient 做三分类；unresolved-name-match => 阻塞；expected-unit-confirmation => 允许但逐项记录；non-core 不参与 name gate。
- 禁止新增 alias / unit 换算：仅使用现有 `src/ingredients.js` / `src/inventory.js` canonicalization。
- 本轮入选 5 道共 4 条 expected-unit-confirmation：花椒面（p186/p185/p219，均缺少真实 coverage=exact 证据）、泡红辣椒（p213，production unit「根」与库存单位「份」无法安全换算）。均仅记录、不阻塞，未做任何 alias/unit 修复。
- 本轮明确不处理 p137 子公鸡、p161 鸡血（沿用 Batch 2/3/4 的 unresolved-name-match 阻塞结论，未重新调查 alias）。

## 转换预览要点

- method 仅由 canonical `methodSummary.steps` 拼接，不补写、不现代化扩写。
- ingredients 直接复用 readiness 已审核 `productionIngredientPlan`，qty/unit 不重新推算。
- source 原始信息（bookPage/pdfPage/characteristicsSummary/uncertainties/confirmedReadings）只进 `provenanceRecord`，production recipe 仅含 schema 支持字段。
- 每道均含 proposedOverlayRecipe / proposedOverlayIngredients / proposedCuratedRecipe / proposedCuratedIngredients / provenanceRecord / sourceToProductionTransformNotes / quantityReviewPreview 条目 / coreRuntimeCompatibility。

## Quantity review preview

- 47 条记录（5 道全部带 qty/unit 条目），逐条来自 readiness audited productionIngredientPlan；raw/normalized 数量取自 canonical source。
- unit 分布：g ×46、根 ×1，全部在白名单（g|ml|个|只|…|根|…），normalizedQuantity.kind 全部 exact-mass/exact-count，normalizeIngredientAmount finite 全部通过；不伪造任何非精确量。
- 真实 promotion 时另行生成正式 quantity-review artifact（与 Batch 1/2/3/4 同构）。

## 临时目录模拟结果

向 temp overlay 追加 5 道（newRecipes + newRecipeIngredients，`recipeIngredientOverrides` 原样保留），运行真实 curate：

- HEAD curated **146** -> 模拟 **151**：严格 current + 5；新增 5 个 ingredient map
- existing recipe delete: **0**，recipe object modify: **0**，ingredient map modify: **0**
- `data/sichuan-recipes.json`（Full 库）：**0 变化**
- 5 道均有完整 method + tags；5 个新 ingredient map 均完整（>=2 项）

## 辅助生成文件预期变化

- `recipe-curation-removed.json`: **不变**（5 道均有 method，不进 removed）
- `recipes-needing-completion.json`: **不变**
- `recipe-curation-summary.md`: 仅统计计数变化：
  - 有效集 342 -> 347；overlay 净增 78 -> 83；curated 保留 146 -> 151
  - 有做法直接保留 125 -> 130；补全 method 125 -> 130；补全 ingredients 88 -> 93

本轮不写真实 production 文件；真实 production git diff = 0。

## PWA 发布可见性（只读检查）

- overlay 与基包均以 `cache: 'no-store'` fetch；`sw.v18.js` 对 `data/*.json` 走 **networkFirst**。
- 结论：真实 promotion 后在线用户立即获得新数据，不需要同步更新 cache-bust/version/service-worker 版本。

## iOS 解码兼容

生成后的 curated 结构 `recipes[]{id,name,method?,tags?}` + `recipe_ingredients[id][{item,qty?,unit?}]` 可直接被 `RecipeService.RemoteRecipe/RemoteIngredient` 解码（batch5 兼容性校验通过）。

## 本轮不修（沿用 Batch 2/3/4 结论）

- p137 子公鸡：unresolved-name-match，未重新调查 alias/crosswalk。
- p161 鸡血：unresolved-name-match，未重新调查 alias/crosswalk。

## Batch 5 之后剩余安全 candidate 预告

- 本轮 eligible 池共 7 道，取 5，剩余 **2** 道（p159、p168）已通过现有全部 gate（hard gate + runtime gate），可直接作为下一轮（Batch 6）安全候选，但结果需 Batch 6 重新机械计算，不得直接沿用。
- 19 道剩余 candidate 的完整去向：9 道被 Batch 1 硬性 gate 阻塞（methodOnly warning / same-for-each / 非精确数量 / consumed 双数量等），2 道被 runtime name gate 阻塞（p137/p161，本轮沿用不处理），7 道 eligible（本轮取 5，剩 2）。

## 停止点

本轮仅完成 Batch 5 dry-run 与相关测试；不执行真实 promotion，不修改 ledger、不修改 Batch 1/2/3/4 冻结产物。
