# 大众川菜 1979 —— Production Batch 7 Mechanical Remediation Dry-run

生成时间: 2026-08-08

基线: main/origin/main=ac7aebbe79e7c326834a77b11eb548437fbc8c56（Batch 1-6 已正式 promotion，共 27 道；curated=153），remainingNewRecipeCandidateCount=12，applicationReady=False

本轮仅产出 dry-run artifact，不写任何 workspace production 文件，不执行真实 promotion，**不修改 Batch 1-6 frozen dry-run artifacts**，不修改 blocker triage artifact。临时目录中用真实 `scripts/curate-recipes.js` 完整模拟 overlay -> curate 链。

## remediationPolicy = allow-safe-same-for-each

这是本轮唯一实施的机械规则升级，来自 blocker triage 已确认的 mechanical-fix-candidate 结论：

| | legacy（Batch 1-6） | Batch 7 remediated |
| --- | --- | --- |
| `memberQuantityMode === 'same-for-each'` | hard-block（`if (ing.memberQuantityMode) return false;`） | **允许通过**，逐 member 精确继承同一 qty/unit（复用 readiness `ingredientToProductionPlan` 已冻结验证的拆分逻辑，非比例分配/猜测） |
| `memberQuantityMode === 'unallocated-group-total'` | hard-block | **继续 hard-block**（组内总量未分配，拆分即等于猜测） |
| 其余所有 hard gate 条件（sourceQuality/quantityReadiness/methodOnly/confidence/uncertainties/consumed 等） | — | **逐字节相同，未改动** |

代码实现上明确区分两套 policy：`passesHardGatesLegacy`（原样保留、供本文件自身回归测试引用，从未被 Batch 7 选择流程调用，也从未用于重新生成任何历史 artifact）与 `passesHardGatesSameForEachRemediated`（Batch 7 实际使用的 gate）。**Batch 1-6 的 6 个 frozen dry-run 脚本本身未被改动一个字符**，其历史结果保持逐字节不变。

语义示例：「姜、葱各五钱」机械拆成 姜=25g、葱=25g——不做比例分配、不重新解释 source，逐 member 数值来自冻结的 `member.qty`/`member.unit`。

## 候选漏斗（12 -> hard-blocked 8 -> after-hard-gates 4 -> runtime-blocked 2 -> eligible 2 -> selected 2）

- 剩余 not-promoted new-recipe-candidate：**12** 道（39 - Batch 1-6 已 promotion 27）。
- Batch 7 remediated hard gate（same-for-each 放行、unallocated-group-total 继续 block，其余条件不变）阻塞 **8** 道，剩余 **4** 道通过硬性 gate（afterHardGates=12-8=4）：
  - methodOnly conversionWarning：p129 凉拌猪肺、p130 蕃茄丝瓜肉片汤（same-for-each 已不再是它们的独立 blocker，但 methodOnly 仍然拦下）
  - 非精确/mixed 数量（quantityReadiness≠exact-comparable）：p201 炝黄瓜、p203 炝绿豆芽、p207 炝莲花白（same-for-each 已不再是拦截原因，仍因「花椒 十余粒」非精确数量被拦）
  - consumed 双数量语义：p222 酱胡豆、p224 拌鱼香豌豆、p226 蛋酥花仁
  - unique union 去重后为 **8**：p129/p130/p201/p203/p207/p222/p224/p226
- Batch 2-6 已验证 runtime gate（仅 core ingredients，复用 `scripts/dazhong-runtime-compatibility.mjs`，未改动）后：**2** 道 eligible。
  - 被 unresolved-name-match 阻塞：**p137 椒麻鸡块（子公鸡）**、**p161 拌鸡血（鸡血）**（本轮不修，沿用既有结论）
- 机械排序（expected-unit-confirmation 少 -> 特殊结构少 -> ingredient 少 -> method 步骤少 -> entryId 升序）取全部 **2**（eligible=2，selected 严格等于 eligible，未凑数）。

完整漏斗去向核算：hard-blocked 8 + runtime-blocked 2 + eligible 2 = remaining 12。

## 机械入选 2 道

| entryId | productionId | name | tags | core 兼容 | unit-confirmation | same-for-each 拆分 |
| --- | --- | --- | --- | --- | --- | --- |
| dz1979-p211 | dz1979-p211 | 花仁萝卜干 | 川菜 / 蔬菜类 | exact-compatible ×3, unit-confirmation ×1 | 1 | 「酱油、葱白」各五钱 → 酱油=25g、葱白=25g |
| dz1979-p144 | dz1979-p144 | 黄焖鸭子 | 川菜 / 禽蛋鱼类 | exact-compatible ×1, unit-confirmation ×1 | 1 | 「姜、葱」各五钱 → 姜=25g、葱=25g；「绍酒、酱油」各一两 → 绍酒=50g、酱油=50g |

排序结果与 checkpoint 提示的 p144/p211 一致——由本轮重新机械计算得出，未直接采用该线索。

## 专项回归：same-for-each remediation 逐项验证

- **p144 可通过结构 gate**：`memberQuantityMode="same-for-each"` 出现两次（姜、葱 / 绍酒、酱油），均非 unallocated-group-total，`passesHardGatesSameForEachRemediated` 放行；`passesHardGatesLegacy` 仍拒绝（对照见测试）。
- **p211 可通过结构 gate**：`memberQuantityMode="same-for-each"` 出现一次（酱油、葱白），remediated gate 放行，legacy gate 拒绝。
- **p130 仍因 methodOnly 失败**：即使其 same-for-each（葱节、姜）已不再是独立 blocker，`methodOnlyAnalysis` 中「胡椒面」的 `core-no-quantity` conversionWarning 仍命中，remediated gate 依然拒绝。
- **p201/p207 仍因 non-exact 失败**：即使各自的 same-for-each 组合（白糖、酱油 / 酱油、醋）已放行，「花椒 十余粒」的 `approximate-count` 仍使 `quantityReadiness≠exact-comparable`，remediated gate 依然拒绝。
- **unallocated-group-total 继续失败**：本轮未发现任何剩余 12 道候选带 unallocated-group-total（该模式仅存在于已 blocked-source-review 等不参与本轮候选池的条目中）；`passesHardGatesSameForEachRemediated` 中该分支逻辑本身通过独立测试用例验证（构造一个假设 unallocated-group-total 场景，确认返回 false）。
- **p137/p161 仍被 runtime 阻塞**：runtime gate 完全未改动，子公鸡/鸡血继续 unresolved-name-match。

## Batch 7 runtime gate 说明（未改动，沿用 Batch 2-6）

- 仅对 role=core 的 production ingredient 做三分类；unresolved-name-match => 阻塞；expected-unit-confirmation => 允许但逐项记录；non-core 不参与 name gate。
- 禁止新增 alias / unit 换算：仅使用现有 `src/ingredients.js` / `src/inventory.js` canonicalization，未做任何改动。
- 本轮入选 2 道共 2 条 expected-unit-confirmation：花椒面（p211，缺少真实 coverage=exact 证据）、水盆鸭（p144，production unit「只」与库存单位「份」无法安全换算）。均仅记录、不阻塞，未做任何 alias/unit 修复。

## Quantity review preview

- 20 条记录（2 道全部带 qty/unit 条目），逐条来自 readiness audited productionIngredientPlan；same-for-each member 的 raw/normalized 数量追溯到其所属组的 canonical 记录，不重新计算。
- unit 分布：g ×19、只 ×1，全部在白名单，normalizedQuantity.kind 全部 exact-mass/exact-count，finite 全部通过；不伪造任何非精确量。

## 临时目录模拟结果

向 temp overlay 追加 2 道（newRecipes + newRecipeIngredients，`recipeIngredientOverrides` 原样保留），运行真实 curate：

- HEAD curated **153** -> 模拟 **155**：严格 current + 2；新增 2 个 ingredient map
- existing recipe delete: **0**，recipe object modify: **0**，ingredient map modify: **0**
- `data/sichuan-recipes.json`（Full 库）：**0 变化**
- 2 道均有完整 method + tags；2 个新 ingredient map 均完整（>=2 项）

## 辅助生成文件预期变化

- `recipe-curation-removed.json`: **不变**（2 道均有 method，不进 removed）
- `recipes-needing-completion.json`: **不变**
- `recipe-curation-summary.md`: 仅统计计数变化：
  - 有效集 349 -> 351；overlay 净增 85 -> 87；curated 保留 153 -> 155
  - 有做法直接保留 132 -> 134；补全 method 132 -> 134；补全 ingredients 95 -> 97

本轮不写真实 production 文件；真实 production git diff = 0。

## PWA 发布可见性（只读检查，未改动结论）

- overlay 与基包均以 `cache: 'no-store'` fetch；`sw.v18.js` 对 `data/*.json` 走 **networkFirst**。
- 结论：真实 promotion 后在线用户立即获得新数据，不需要同步更新 cache-bust/version/service-worker 版本。

## iOS 解码兼容

生成后的 curated 结构 `recipes[]{id,name,method?,tags?}` + `recipe_ingredients[id][{item,qty?,unit?}]` 可直接被 `RecipeService.RemoteRecipe/RemoteIngredient` 解码（batch7 兼容性校验通过）。

## 本轮不修

- p137 子公鸡、p161 鸡血：unresolved-name-match，未重新调查 alias/crosswalk。
- p129/p130（methodOnly）、p201/p203/p207（non-exact）、p222/p224/p226（consumed dual quantity）：均维持 blocked，本轮只实施 same-for-each 这一项机械规则升级，未顺手处理其他 blocker。

## 对 Batch 1-6 frozen artifacts 的影响

**无影响。** `scripts/build-dazhong-chuancai-promotion-batch1-dry-run.mjs` 至 `...batch6-dry-run.mjs` 六个脚本文件本身未被改动、未重新执行、未重新生成任何输出；其对应的 `dazhong-chuancai-1979-promotion-batch{1..6}-dry-run.v1.json`/`.md`/quantity-review artifacts 保持逐字节不变（byte-identical，见测试）。blocker triage artifact（`dazhong-chuancai-1979-promotion-blocker-triage.v1.json`）同样未被修改。

## 停止点

本轮仅完成 Batch 7 dry-run 与相关测试；不执行真实 promotion，不修改 ledger、不修改 Batch 1-6 frozen 产物，不处理剩余 10 道 blocked candidate。
