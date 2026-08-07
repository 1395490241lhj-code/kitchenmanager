# 大众川菜 1979 —— Production Promotion Readiness

生成时间: 2026-08-07

基线: main/origin/main=132434e, applicationReady=False

本轮只制定可执行的 promotion 候选清单与转换预览，不修改任何生产数据，不做 production promotion，不读 PDF，不调用视觉模型。

## 汇总

- 总条目: **147**（147/147 覆盖，无重复）
- promotionDisposition 数量:
  - existing-project-match: **50**
  - new-recipe-candidate: **39**
  - blocked-source-review: **45**
  - blocked-alternate-source: **12**
  - blocked-crosswalk: **1**
- 判定优先级: alternate-source > source-review > crosswalk > existing/new
- confirmed project mappings: **81**（全部为 existing-project-match 或受 source 层阻塞，不生成重复新 recipe）
- new-recipe-candidate 由 **book-only ∩ sourceQuality=ready** 机械计算，恰好 39 道

## 判定规则

- existing-project-match: exact-name / confirmed-alias，已有真实 project ID，复用现有 recipe，不创建重复；未来 source-enrichment 候选另行记录。
- new-recipe-candidate: book-only 且 sourceQuality=ready，无现有绑定，是后续真正可能新增到 production 的集合。
- blocked-source-review: sourceQuality=needs-source-review 且非 alternate，来源保真问题未解决（其中 28 道已有 confirmed 映射，17 道 book-only）。
- blocked-alternate-source: sourceQuality=alternate-source-required，B 类 12 道，需替代来源。
- blocked-crosswalk: probable-match-needs-review，当前仅 dz1979-p173（干煸鳝鱼丝）；即使 sourceQuality=ready 也不得 promotion。

## New-recipe-candidate（39）

dz1979-p129 凉拌猪肺、p130 蕃茄丝瓜肉片汤、p137 椒麻鸡块、p143 当归炖鸡、p144 黄焖鸭子、p153 绍子蒸蛋、p159 烧鸭血、p161 拌鸡血、p162 豆瓣鱼、p168 豆腐鱼、p180 干炒豆腐、p183 酱烧苦瓜、p185 麻酱青笋尖、p186 蒜泥拌黄瓜、p187 糖醋子姜、p188 姜汁蕹菜、p195 干煸苦瓜、p196 醋熘白菜、p198 酱烧茄子、p200 炒土豆泥、p201 炝黄瓜、p202 白油鲜笋、p203 炝绿豆芽、p204 炒豌豆尖、p205 青椒炒大头菜、p206 烧拌莴笋、p207 炝莲花白、p209 拌素三丝、p211 花仁萝卜干、p212 糖醋萝卜丝、p213 青笋拌折耳根、p216 拌盐白菜、p218 酸菜豆瓣汤、p219 过浆豆花、p221 蒜泥蚕豆、p222 酱胡豆、p223 熏豆腐干、p224 拌鱼香豌豆、p226 蛋酥花仁

每项均含转换预览：proposedName、proposedTags、proposedIdStrategy（`dz1979-p<bookPage>`）、ingredientTarget、methodTarget、provenanceStrategy、schemaGapNotes，以及 methodPreview / ingredientPreview。

## 转换预览规则

- production name: 使用 catalog bookName。
- proposed tags: 机械映射 `['川菜', category]` + 主料关键词（如 猪肉/牛肉/鸡肉/鱼/豆腐/蛋）+ 蔬菜类追加 `素菜`。
- stable ID: `dz1979-p<bookPage>`（如 dz1979-p212），与 entryId 同源、不撞现有 ex-/fam-/comp-/static-/hoc- 前缀。
- ingredients: 写入 `recipe_ingredients[id]`，`item=rawItemText`、`qty=rawQuantityText` 字符串、`unit=null`；不得写入 normalized 数值。
- method: 由 `methodSummary.steps` 拼接 `"order. summary"` 换行文本（methodPreview），经 completion overlay `recipes{id:{method}}` 或 curated JSON `recipe.method` 落地。
- provenance: 新建独立 provenance 侧文件（productionId -> entryId/bookPage/pdfPage/characteristicsSummary/uncertainties/confidence），production schema 无对应字段。

## Production 数据链调查结论

- recipe 实体: `data/sichuan-recipes.{curated,full}.json` 顶层 `recipes[]`，字段 `id/name/tags`（curated 另含 `method`；full 无）。
- ingredients: 顶层 `recipe_ingredients[id]`，形状 `[{item, qty?, unit?}]`，qty/unit 为字符串或 null。
- method 实际存储: curated `recipe.method`；`data/recipe-methods.js`（按菜名）；`data/recipe-completion-overlay.json`（recipes{id:{method}} + newRecipes）。
- PWA 消费: `app.js` → `src/recipe-library.js`（mergeRecipeSources → applyCompletionOverlay → mergeRecipeMethods）→ 用户 localStorage overlay。
- iOS 消费: `RecipeService.fetchRecipes` 直接拉取 `sichuan-recipes.{curated,full}.json`，只解码 recipes(id,name,method?,tags)+recipe_ingredients，不应用 completion overlay；因此新菜需在基 JSON 或 curated 物化中可见。
- ID 惯例: full `ex--<8-hex>`、家常 `fam-<slug>`、overlay 新菜 `comp-<8-hex>`、static/hoc 派生前缀。

## Schema 扩展结论

基本菜谱（`{id,name,tags,method}` + `recipe_ingredients`）可直接容纳 new-recipe-candidate，**无需扩展 production schema**。不可直接承载的 source 字段：characteristicsSummary、uncertainties、confirmedReadings、confidence、sourceQuality、normalized 数值数量（production 仅字符串 qty/unit）、书页 provenance —— 这些应保留在独立 provenance 侧文件，不改现有 schema。

## 下一步建议

建议最小 promotion batch 为 **5-8 道** new-recipe-candidate，逐批人工复核后先经 completion overlay 链落地，再物化 curated JSON（复刻 curate-recipes.js 合并逻辑），确保 PWA 与 iOS 同时可见。B 类 12 道与 blocked-source-review 45 道不进入任何 batch。

## 验证

- 147/147 覆盖且无重复、disposition 总数=147：通过
- new-recipe-candidate=book-only∩ready（39）：通过
- 81 confirmed 映射全部不进入 new-recipe-candidate：通过
- p173=blocked-crosswalk：通过
- alternate 12 道全部 blocked-alternate-source：通过
- needs-source-review 不进入 new-recipe-candidate：通过
- 无 dangling project ID、applicationReady=false：通过
- 未修改 Curated/Full/HOC、production recipe 数据、UI/cache、canonical source、name-matches、adjudication audit
