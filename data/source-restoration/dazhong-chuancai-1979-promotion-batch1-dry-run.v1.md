# 大众川菜 1979 —— Production Batch 1 Dry-run

生成时间: 2026-08-07

基线: main/origin/main=0ffd35d, applicationReady=False

本轮仅产出 dry-run artifact，不写任何 workspace production 文件，不执行真实 promotion。临时目录中用真实 `scripts/curate-recipes.js` 完整模拟 overlay -> curate 链。

## 机械入选 5 道

从 39 道 new-recipe-candidate 机械筛选，合格池 **29 道**，按复杂度排序取前 5：

| entryId | productionId | name | tags |
| --- | --- | --- | --- |
| dz1979-p143 | dz1979-p143 | 当归炖鸡 | 川菜 / 禽蛋鱼类 |
| dz1979-p204 | dz1979-p204 | 炒豌豆尖 | 川菜 / 蔬菜类 |
| dz1979-p195 | dz1979-p195 | 干煸苦瓜 | 川菜 / 蔬菜类 |
| dz1979-p200 | dz1979-p200 | 炒土豆泥 | 川菜 / 蔬菜类 |
| dz1979-p180 | dz1979-p180 | 干炒豆腐 | 川菜 / 蔬菜类 |

与上轮结果完全一致（p143/p204/p195/p200/p180），复用同一筛选规则与排序，本轮未硬编码。

## 排除的特殊风险类型

- methodOnly conversionWarning: dz1979-p129 凉拌猪肺、p130 蕃茄丝瓜肉片汤
- 非精确/mixed 数量: p201 炝黄瓜、p203 炝绿豆芽、p207 炝莲花白
- consumed 双数量语义: p222 酱胡豆、p224 拌鱼香豌豆、p226 蛋酥花仁
- same-for-each 组合数量: p144 黄焖鸭子、p211 花仁萝卜干

## 转换预览要点

- method 仅由 canonical `methodSummary.steps` 拼接（全部 2 步），不补写、不现代化扩写。
- ingredients 直接复用 readiness 已审核 `productionIngredientPlan`，qty/unit 不重新推算（exact-mass -> 数字字符串+g；exact-count -> 数字字符串+计数单位）。
- source 原始信息（bookPage/pdfPage/characteristicsSummary/uncertainties/confirmedReadings）只进 `provenanceRecord`，production recipe 仅含 schema 支持字段。
- 每道均含 proposedOverlayRecipe / proposedOverlayIngredients / proposedCuratedRecipe / proposedCuratedIngredients / provenanceRecord / sourceToProductionTransformNotes。

## 临时目录模拟结果

向 temp overlay 追加 5 道（newRecipes + newRecipeIngredients，`recipeIngredientOverrides` 9 项原样保留），运行真实 curate：

- HEAD curated **126** -> 模拟 **131**：严格 current + 5
- 新增 5 道: dz1979-p143 / p180 / p195 / p200 / p204
- existing recipe delete: **0**，recipe object modify: **0**，ingredient map modify: **0**
- 5 道均有完整 method + tags；5 个新 ingredient map 均完整（>=2 项）

## 辅助生成文件预期变化

- `recipe-curation-removed.json`: **不变**（5 道均有 method，不进 removed）
- `recipes-needing-completion.json`: **不变**
- `recipe-curation-summary.md`: 仅统计计数变化：
  - 有效集 322 -> 327；overlay 净增 58 -> 63；curated 保留 126 -> 131
  - 有做法直接保留 105 -> 110；补全 method 105 -> 110；补全 ingredients 68 -> 73

本轮不写真实 production 文件。

## PWA 发布可见性（只读检查）

- overlay 与基包均以 `cache: 'no-store'` fetch；`sw.v18.js` 对 `data/*.json` 走 **networkFirst**（在线总是最新，离线回退缓存）。
- 结论：真实 promotion 后在线用户立即获得新数据，**不需要**同步更新 cache-bust/version/service-worker 版本；只有 JS/CSS/SW 资产改动才需发布版本更新。

## iOS 解码兼容

生成后的 curated 结构 `recipes[]{id,name,method?,tags?}` + `recipe_ingredients[id][{item,qty?,unit?}]` 可直接被 `RecipeService.RemoteRecipe/RemoteIngredient` 解码（batch1 兼容性校验通过）。

## 验证

- 5 道全部满足 gate（见 selection.criteria）；生产真实文件 git diff = 0
- canonical / crosswalk / readiness 0 变化
- temp curate = current curated + exactly 5，existing 0 semantic drift
- JSON parse、`node --check`、batch1 tests、recipe curation reproducibility tests、related runtime/iOS decode tests、source-restoration tests、`git diff --check`
