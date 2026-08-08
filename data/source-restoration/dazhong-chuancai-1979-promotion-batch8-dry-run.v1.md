# 大众川菜 1979 —— Production Batch 8 methodOnly-null Remediation Dry-run

生成时间: 2026-08-08

基线: main/origin/main=e9101fe990309f263c6cd1cdb249656d24ab6d61（Batch 1-7 已正式 promotion，共 29 道；curated=155），remainingNewRecipeCandidateCount=10，applicationReady=False

本轮仅产出 dry-run artifact，不写任何 workspace production 文件，不执行真实 promotion，**不修改 Batch 1-7 frozen dry-run artifacts**，不修改任何已冻结 review artifact。

## remediationPolicy = allow-safe-same-for-each + allow-reviewed-methodonly-null

本轮在 Batch 7 已验证的 `allow-safe-same-for-each` 之上，新增第二条、且仅有的这一条规则：

| | Batch 7 gate | Batch 8 gate（本轮新增） |
| --- | --- | --- |
| `memberQuantityMode` | same-for-each 放行，unallocated-group-total 继续 block | 不变，原样继承 |
| methodOnly core-no-quantity | 任意此类项一律 hard-block | **仅** `reviewedMethodOnlyNullAllowlist` 中逐条确认的 3 个 (entryId, item) 组合放行，其余继续 hard-block |

`reviewedMethodOnlyNullAllowlist`：

```json
{
  "dz1979-p129": ["姜", "花椒"],
  "dz1979-p130": ["胡椒面"]
}
```

严格来自已冻结、扫描确认的 `data/source-restoration/dazhong-chuancai-1979-methodonly-remediation-review.v1.json`（`safetyAnalysis.conclusion=safe-to-allow-...`）。本轮生成时机械核对该 artifact 的 `verificationProblems=[]` 与结论未变；若该 review artifact 被改成非安全结论，本 dry-run 会立即报 `methodonly-review-no-longer-confirms-safe` 而失败，不会静默继续。

**不做全局放行**：任何不在这 3 个 (entryId, item) 精确组合内的 methodOnly core-no-quantity 条目继续 hard-block（见下方回归验证）。

## 候选漏斗（10 -> hard-blocked 6 -> after-hard-gates 4 -> runtime-blocked 2 -> eligible 2 -> selected 2）

- 剩余 not-promoted new-recipe-candidate：**10** 道（39 - Batch 1-7 已 promotion 29）。
- hard gate（same-for-each remediated + methodOnly-null remediated）阻塞 **6** 道，剩余 **4** 道：
  - 非精确/mixed 数量：p201 炝黄瓜、p203 炝绿豆芽、p207 炝莲花白（花椒「十余粒」approximate-count，本轮未处理）
  - consumed 双数量语义：p222 酱胡豆、p224 拌鱼香豌豆、p226 蛋酥花仁（本轮未处理）
  - unique union 去重后为 **6**：p201/p203/p207/p222/p224/p226
- runtime gate（未改动，沿用 Batch 2-7）后：**2** 道 eligible。
  - 被 unresolved-name-match 阻塞：**p137 椒麻鸡块（子公鸡）**、**p161 拌鸡血（鸡血）**（本轮不修）
- 机械排序取全部 **2**（eligible=2，selected 严格等于 eligible，未凑数）。

完整漏斗去向核算：hard-blocked 6 + runtime-blocked 2 + eligible 2 = remaining 10。

## 机械入选 2 道

| entryId | productionId | name | methodOnly-null 项 | core 兼容 | unit-confirmation |
| --- | --- | --- | --- | --- | --- |
| dz1979-p129 | dz1979-p129 | 凉拌猪肺 | 姜(null), 花椒(null) | exact-compatible ×3 | 0 |
| dz1979-p130 | dz1979-p130 | 蕃茄丝瓜肉片汤 | 胡椒面(null) | exact-compatible ×3, unit-confirmation ×1 | 1 |

排序结果与预计的 p129/p130 一致——由本轮重新机械计算得出。

## 结构化 quantity review 未因 null 项增加

- p129 proposedCuratedIngredients 共 8 项：6 项来自 readiness productionIngredientPlan（qty/unit 均为精确数值），另加 2 项 methodOnly-null（姜、花椒，qty=null/unit=null）。
- p130 proposedCuratedIngredients 共 11 项：10 项来自 readiness productionIngredientPlan，另加 1 项 methodOnly-null（胡椒面，qty=null/unit=null）。
- **quantityReviewPreview / Batch 8 quantity-review artifact 均为 16 条记录，全部来自既有精确项**——3 个 null 项因 qty=null 被 quantity-review 生成逻辑自动过滤，未产生任何新的 structured reviewed 记录。dry-run 生成器内置断言：若任一 null 项意外出现在 quantityReviewRecords 中，`verificationProblems` 会立即报错。

## null 项不参与 inventory coverage / recommendation（专项验证）

姜、花椒、胡椒面经真实（未修改）`classifyRecipeIngredient()` 分类均为 `role=seasoning`；`src/recommendations.js`、`src/ai.js` 的库存覆盖率/缺货判断/购物清单推荐逻辑只对 `role=core` 的 ingredient 做匹配。因此这 3 个 null 项无论 qty 是否为 null，均**从不参与**任何下游库存/推荐逻辑，与已冻结的 methodOnly review 结论完全一致。

## runtime gate 安全性（未改动，沿用 Batch 2-7）

- p129：3 个 core ingredient 全部 exact-compatible，0 unresolved-name-match，0 expected-unit-confirmation。
- p130：4 个 core ingredient 中 3 个 exact-compatible、1 个 expected-unit-confirmation（葱节：production unit「g」与常用库存单位「把」缺少真实 coverage=exact 证据），0 unresolved-name-match。
- 两道 gatePassed=true，运行时逻辑未新增任何 error。

## 临时目录模拟结果

向 temp overlay 追加 2 道（newRecipes + newRecipeIngredients，`recipeIngredientOverrides` 原样保留），运行真实 curate：

- HEAD curated **155** -> 模拟 **157**：严格 current + 2；新增 2 个 ingredient map（各含对应 null 项）
- existing recipe delete: **0**，recipe object modify: **0**，ingredient map modify: **0**
- `data/sichuan-recipes.json`（Full 库）：**0 变化**
- 2 道均有完整 method + tags；2 个新 ingredient map 均完整（含 null 项在内 >=2 项）

## 辅助生成文件预期变化

- `recipe-curation-removed.json`: **不变**
- `recipes-needing-completion.json`: **不变**
- `recipe-curation-summary.md`: 仅统计计数变化：
  - 有效集 351 -> 353；overlay 净增 87 -> 89；curated 保留 155 -> 157
  - 有做法直接保留 134 -> 136；补全 method 134 -> 136；补全 ingredients 97 -> 99

本轮不写真实 production 文件；真实 production git diff = 0。

## 本轮不修（继续 blocked，未处理的 8 道）

- p137 子公鸡、p161 鸡血：runtime unresolved-name-match（未沿用/未重新调查）。
- p201/p203/p207：non-exact-quantity（花椒「十余粒」approximate-count，需 schema/policy 决策）。
- p222/p224/p226：consumed-dual-quantity（菜油/干豆粉「耗」双数量，需 schema/policy 决策）。

## 对 Batch 1-7 frozen artifacts 与既有 review artifact 的影响

**无影响。** Batch 1-7 六个 promotion 脚本与其对应 dry-run/quantity-review artifacts 均未被改动、未重新执行。`dazhong-chuancai-1979-methodonly-remediation-review.v1.json` 同样未被修改，本轮只读取并核对其结论。

## 停止点

本轮仅完成 Batch 8 methodOnly-null 机械 remediation dry-run 与相关测试；不执行真实 promotion，不修改 ledger/readiness/production，不处理剩余 8 道 blocked candidate。
