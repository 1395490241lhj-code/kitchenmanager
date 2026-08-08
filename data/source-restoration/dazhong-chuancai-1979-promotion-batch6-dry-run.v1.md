# 大众川菜 1979 —— Production Batch 6 Dry-run

生成时间: 2026-08-08

基线: main/origin/main=6474ef7e30db4b321faea33aace5152474c55709（Batch 1/2/3/4/5 已正式 promotion，共 25 道；ledger 见 `dazhong-chuancai-1979-production-promotions.v1.json`），applicationReady=False

本轮仅产出 dry-run artifact，不写任何 workspace production 文件，不执行真实 promotion。临时目录中用真实 `scripts/curate-recipes.js` 完整模拟 overlay -> curate 链。

## 候选漏斗（14 -> hard-blocked 10 -> after-hard-gates 4 -> runtime-blocked 2 -> eligible 2 -> selected 2）

- 剩余 not-promoted new-recipe-candidate：**14** 道（39 - Batch 1/2/3/4/5 已 promotion 25）。
- Batch 1 硬性 gate（frozen readiness 规则原样复用）阻塞 **10** 道（unique union，去重后），剩余 **4** 道通过硬性 gate（afterHardGates=14-10=4）：
  - methodOnly conversionWarning：p129 凉拌猪肺、p130 蕃茄丝瓜肉片汤
  - same-for-each 组合数量：p130 蕃茄丝瓜肉片汤、p144 黄焖鸭子、p201 炝黄瓜、p207 炝莲花白、p211 花仁萝卜干
  - 非精确/mixed 数量（quantityReadiness≠exact-comparable）：p201 炝黄瓜、p203 炝绿豆芽、p207 炝莲花白
  - consumed 双数量语义：p222 酱胡豆、p224 拌鱼香豌豆、p226 蛋酥花仁
  - （p130/p201/p207 同时命中多类原因；unique entryId 去重后为 **10**：p129/p130/p144/p201/p203/p207/p211/p222/p224/p226）
- Batch 2/3/4/5 已验证 runtime gate（仅 core ingredients，复用 `scripts/dazhong-runtime-compatibility.mjs`）后：**2** 道 eligible。
  - 被 unresolved-name-match 阻塞：**p137 椒麻鸡块（子公鸡）**、**p161 拌鸡血（鸡血）**（本轮不修，按要求排除在候选之外，与 Batch 2/3/4/5 结论一致）
- 机械排序（expected-unit-confirmation 少 -> 特殊结构少 -> ingredient 少 -> method 步骤少 -> entryId 升序）取全部 **2**（eligible=2，selected 严格等于 eligible，未凑数、未降低 gate）。

完整漏斗去向核算：hard-blocked 10 + runtime-blocked 2 + eligible 2 = remaining 14。

## 机械入选 2 道

| entryId | productionId | name | tags | core 兼容 | unit-confirmation |
| --- | --- | --- | --- | --- | --- |
| dz1979-p159 | dz1979-p159 | 烧鸭血 | 川菜 / 禽蛋鱼类 | exact-compatible ×1, unit-confirmation ×1 | 1 |
| dz1979-p168 | dz1979-p168 | 豆腐鱼 | 川菜 / 禽蛋鱼类 | exact-compatible ×1, unit-confirmation ×1 | 1 |

排序结果与 checkpoint 提示的 p159/p168 一致——由本轮重新机械计算得出，未直接采用该线索。eligible 池仅 2 道，全部入选，无剩余排名。

## Batch 6 runtime gate 说明

- 复用 Batch 2/3/4/5 已验证的 runtime gate 与 `scripts/dazhong-runtime-compatibility.mjs`，本轮不新增/修改任何分类逻辑。
- 只对 role=core 的 production ingredient 做三分类；unresolved-name-match => 阻塞；expected-unit-confirmation => 允许但逐项记录；non-core 不参与 name gate。
- 禁止新增 alias / unit 换算：仅使用现有 `src/ingredients.js` / `src/inventory.js` canonicalization。
- 本轮入选 2 道共 2 条 expected-unit-confirmation：花椒面（p159，缺少真实 coverage=exact 证据）、豆腐（p168，production unit「个」与常用库存单位「盒」无法安全换算）。均仅记录、不阻塞，未做任何 alias/unit 修复。
- 本轮明确不处理 p137 子公鸡、p161 鸡血（沿用 Batch 2/3/4/5 的 unresolved-name-match 阻塞结论，未重新调查 alias）。

## 转换预览要点

- method 仅由 canonical `methodSummary.steps` 拼接，不补写、不现代化扩写。
- ingredients 直接复用 readiness 已审核 `productionIngredientPlan`，qty/unit 不重新推算。
- source 原始信息（bookPage/pdfPage/characteristicsSummary/uncertainties/confirmedReadings）只进 `provenanceRecord`，production recipe 仅含 schema 支持字段。
- 每道均含 proposedOverlayRecipe / proposedOverlayIngredients / proposedCuratedRecipe / proposedCuratedIngredients / provenanceRecord / sourceToProductionTransformNotes / quantityReviewPreview 条目 / coreRuntimeCompatibility。

## Quantity review preview

- 24 条记录（2 道全部带 qty/unit 条目），逐条来自 readiness audited productionIngredientPlan；raw/normalized 数量取自 canonical source。
- unit 分布：g ×23、个 ×1，全部在白名单（g|ml|个|只|…|根|…），normalizedQuantity.kind 全部 exact-mass/exact-count，normalizeIngredientAmount finite 全部通过；不伪造任何非精确量。
- 真实 promotion 时另行生成正式 quantity-review artifact（与 Batch 1/2/3/4/5 同构）。

## 临时目录模拟结果

向 temp overlay 追加 2 道（newRecipes + newRecipeIngredients，`recipeIngredientOverrides` 原样保留），运行真实 curate：

- HEAD curated **151** -> 模拟 **153**：严格 current + 2；新增 2 个 ingredient map
- existing recipe delete: **0**，recipe object modify: **0**，ingredient map modify: **0**
- `data/sichuan-recipes.json`（Full 库）：**0 变化**
- 2 道均有完整 method + tags；2 个新 ingredient map 均完整（>=2 项）

## 辅助生成文件预期变化

- `recipe-curation-removed.json`: **不变**（2 道均有 method，不进 removed）
- `recipes-needing-completion.json`: **不变**
- `recipe-curation-summary.md`: 仅统计计数变化：
  - 有效集 347 -> 349；overlay 净增 83 -> 85；curated 保留 151 -> 153
  - 有做法直接保留 130 -> 132；补全 method 130 -> 132；补全 ingredients 93 -> 95

本轮不写真实 production 文件；真实 production git diff = 0。

## PWA 发布可见性（只读检查）

- overlay 与基包均以 `cache: 'no-store'` fetch；`sw.v18.js` 对 `data/*.json` 走 **networkFirst**。
- 结论：真实 promotion 后在线用户立即获得新数据，不需要同步更新 cache-bust/version/service-worker 版本。

## iOS 解码兼容

生成后的 curated 结构 `recipes[]{id,name,method?,tags?}` + `recipe_ingredients[id][{item,qty?,unit?}]` 可直接被 `RecipeService.RemoteRecipe/RemoteIngredient` 解码（batch6 兼容性校验通过）。

## 本轮不修（沿用 Batch 2/3/4/5 结论）

- p137 子公鸡：unresolved-name-match，未重新调查 alias/crosswalk。
- p161 鸡血：unresolved-name-match，未重新调查 alias/crosswalk。

## 只读分类：若 p159/p168 正式 promotion，剩余 12 道分别因何 gate 被阻塞

以下为**只读分类**，本轮不修复、不重新调查任何 candidate：

| entryId | name | 阻塞 gate | 具体原因 |
| --- | --- | --- | --- |
| dz1979-p129 | 凉拌猪肺 | hard gate | methodOnly conversionWarning |
| dz1979-p130 | 蕃茄丝瓜肉片汤 | hard gate | methodOnly conversionWarning + same-for-each 组合数量 |
| dz1979-p137 | 椒麻鸡块 | runtime name gate | unresolved-name-match（子公鸡） |
| dz1979-p144 | 黄焖鸭子 | hard gate | same-for-each 组合数量 |
| dz1979-p161 | 拌鸡血 | runtime name gate | unresolved-name-match（鸡血） |
| dz1979-p201 | 炝黄瓜 | hard gate | same-for-each 组合数量 + 非精确数量 |
| dz1979-p203 | 炝绿豆芽 | hard gate | 非精确数量 |
| dz1979-p207 | 炝莲花白 | hard gate | same-for-each 组合数量 + 非精确数量 |
| dz1979-p211 | 花仁萝卜干 | hard gate | same-for-each 组合数量 |
| dz1979-p222 | 酱胡豆 | hard gate | consumed 双数量语义 |
| dz1979-p224 | 拌鱼香豌豆 | hard gate | consumed 双数量语义 |
| dz1979-p226 | 蛋酥花仁 | hard gate | consumed 双数量语义 |

算术核对：hard gate 10 + runtime name gate 2 = 12 = 14 - 2（本轮 selected）。

## 停止点

本轮仅完成 Batch 6 dry-run 与相关测试；不执行真实 promotion，不修改 ledger、不修改 Batch 1/2/3/4/5 冻结产物。
