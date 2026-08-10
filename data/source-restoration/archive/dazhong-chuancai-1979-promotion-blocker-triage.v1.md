# 大众川菜 1979 —— Remaining 12 Blocker Triage

生成时间: 2026-08-08

基线: main/origin/main=5b737cf8bc418a8e8c8cd1b057783a1500302b56（Batch 1-6 已正式 promotion，共 27 道；curated=153），remainingNewRecipeCandidateCount=12，applicationReady=False

本轮**只分析、只分类**，不 promotion 任何菜、不修改任何 production 文件、不新增 alias/unit conversion/schema。所有结论基于已冻结的 canonical (`dazhong-chuancai-1979-recipes.v1.json`)、readiness (`productionIngredientPlan`) 与 runtime (`scripts/dazhong-runtime-compatibility.mjs`，未改动) 三个数据源机械推导。

## Blocker 分组总览（有重叠，非 12 个独立单原因）

| blocker | entryId 集合 |
| --- | --- |
| methodOnly | p129, p130 |
| same-for-each | p130, p144, p201, p207, p211 |
| non-exact-quantity | p201, p203, p207 |
| consumed-dual-quantity | p222, p224, p226 |
| runtime-unresolved-name | p137（子公鸡）, p161（鸡血） |

union 校验：与冻结 Batch 6 dry-run 的 `hardGateExclusions`（10 道）+ `runtimeNameGateBlocked`（2 道）逐条一致，`verificationProblems=[]`。

## 逐道 triage（entryId / 主 blocker / recommendedDisposition）

| entryId | name | blockers | recommendedDisposition |
| --- | --- | --- | --- |
| p129 | 凉拌猪肺 | methodOnly | targeted-review-required |
| p130 | 蕃茄丝瓜肉片汤 | methodOnly + same-for-each | targeted-review-required |
| p137 | 椒麻鸡块 | runtime-unresolved-name（子公鸡） | targeted-review-required |
| p144 | 黄焖鸭子 | same-for-each（仅此一项） | **mechanical-fix-candidate** |
| p161 | 拌鸡血 | runtime-unresolved-name（鸡血） | targeted-review-required |
| p201 | 炝黄瓜 | same-for-each + non-exact-quantity | schema-or-policy-required |
| p203 | 炝绿豆芽 | non-exact-quantity | schema-or-policy-required |
| p207 | 炝莲花白 | same-for-each + non-exact-quantity | schema-or-policy-required |
| p211 | 花仁萝卜干 | same-for-each（仅此一项） | **mechanical-fix-candidate** |
| p222 | 酱胡豆 | consumed-dual-quantity | schema-or-policy-required |
| p224 | 拌鱼香豌豆 | consumed-dual-quantity | schema-or-policy-required |
| p226 | 蛋酥花仁 | consumed-dual-quantity | schema-or-policy-required |

## A. same-for-each 专项分析

现有 readiness 的 `ingredientToProductionPlan` 已含成熟、已验证的 same-for-each 拆分逻辑：`memberQuantityMode==="same-for-each"` 时，把「组名各 X」机械拆成每个 member 各继承相同 qty/unit，**不是猜测分配**（例如「葱节、姜各三钱」→ 葱节=15g、姜=15g）。

当前 Batch 1 hard gate 对 `ing.memberQuantityMode` 做的是**任意值都拒绝**（`if (ing.memberQuantityMode) return false;`），没有区分 same-for-each（安全、精确继承）与 unallocated-group-total（组内总量未分配、拆分即等于猜测）。

区分结果：

- **仅命中 same-for-each，无其他 blocker**：p144（黄焖鸭子）、p211（花仁萝卜干）。这两道若把 hard gate 对 same-for-each 单独放宽（unallocated-group-total 继续 block），即可无损失解锁，且不涉及 source 重新解读——member 拆分规则已存在、已在其它字段验证过正确性。
- **same-for-each 叠加其他 blocker，不能单独解锁**：p130（叠加 methodOnly）、p201/p207（叠加 non-exact-quantity）。这三道即使放宽 same-for-each gate，仍会被其余 blocker 拦下，不构成独立的 mechanical fix。

## B. non-exact-quantity 专项分析

p201/p203/p207 均含「花椒 十余粒」——`normalizedQuantity.kind="approximate-count"`，`qty=null`。readiness 已经拒绝伪造精确值，保留 `displayQuantity="十余粒"`、`inventoryComparable=false`。

问题在于**当前 production curated ingredient schema 只有 `{item, qty, unit}` 三字段**，没有 display-only/近似量字段。如果直接把这类条目原样 promotion：

- 若把 qty/unit 写成 null：忠实（不伪造），但会**静默丢失**「十余粒」这条书面信息，用户界面上完全看不到该食材原有的近似量描述；
- 若强行给「十余粒」赋一个精确数字：违反「不要擅自把十余粒/少许/适量转成精确值」的硬约束，是 source 篡改。

因此这不是 methodOnly 那种「人工确认后可能机械修」的情况，而是**先要做 schema（新增 display-only 字段）或 policy（接受信息损失）决策**，判定为 `schema-or-policy-required`，不建议归入 mechanical-fix-candidate。

## C. methodOnly 专项分析

p129「姜、花椒」（另用开水同煮猪肺）与 p130「胡椒面」（汤内调味）均在 `methodOnlyIngredients` 中标记 `rawQuantityText=null`——**原书方法步骤原文本身就没有给出数量**，不是提取遗漏。

两项在食材栏（`recipe.ingredients`）里均不存在——即当前 readiness 从未把它们纳入 `inventoryIngredients`，`quantityReadiness` 仍算作 `exact-comparable`（因为纳入统计的都是食材栏精确项）。真正的 blocker 来自 hard gate 规则 `plan.methodOnlyAnalysis.some(item => item.conversionWarning)` 命中了 `core-no-quantity` 分类。

机械 converter 无法解决这个问题：不能凭空推断「姜、花椒」或「胡椒面」的用量。唯一安全路径是人工确认原书确实无量，然后决定 policy（要么允许 core-no-quantity 项以 qty=null/unit=null 形式进入 production ingredients，要么维持现状——完全不进入 production，如今日）。判定为 `targeted-review-required`（有限范围的人工确认任务，不是纯代码修复）。

## D. consumed-dual-quantity 专项分析

p222/p224/p226 的「菜油 一斤耗二两」（p226 另有「干豆粉 一斤耗四两」）均已在 canonical `normalizedQuantity` 中正确记录两个数字：`qty`（购入/备料量，如 500g）与 `consumedQty`（实际耗用量，如 100g）。

当前 production ingredient schema **单一 `{item, qty, unit}` 字段**无法同时表达这两个数字：

- 若 qty 取 500（购入量）：会让库存扣减/推荐逻辑按 500g 计算实际消耗，**高估** 5 倍实际耗用；
- 若 qty 取 100（耗用量）：会让用户误以为只需备 100g 菜油，**低估**实际需要购买/准备的量。

两个数字都是书中明确给出的事实，选择其一冒充完整语义都是信息损失/误导。**必须先做 schema（新增 consumedQty 字段）或 policy（明确规定 qty 字段代表输入量还是耗用量，并在 provenance 中记录被舍弃的另一个数字）决策**，才能无损 promotion 这一类食材。判定为 `schema-or-policy-required`。

## E. runtime unresolved-name 专项分析（p137 子公鸡 / p161 鸡血）

对两项均只做了**潜在安全修复评估**，未实际新增任何 alias：

- **子公鸡**（p137）：`getIngredientFamilyKey("子公鸡")` 返回空，且严格匹配现有 `POULTRY_PROBES`（鸡肉/仔鸡/母鸡/老母鸡/土鸡/公鸡/三黄鸡）全部失败（连 contains 级软匹配也不命中）。子公鸡是「小公鸡」这一更具体品类，不属于现有任何 family member 的同义词范围。若把它并入「鸡肉」family，需要人工确认这是否是用户实际使用的库存词汇习惯，以及是否会让「子公鸡」被过宽匹配到不相关的鸡肉库存项。
- **鸡血**（p161）：`getIngredientFamilyKey("鸡血")` 同样为空。鸡血是与所有鸡肉/家禽 family member 完全不同的产品类别（血制品 vs 肉），强行并入鸡肉 family 存在**血制品与肉制品互相误判**的真实安全风险——这正是该 runtime gate 存在的目的（防止「宽匹配污染」）。

两者的最低风险解锁方式都是：**新增各自独立的 canonical/family 条目**（不与既有鸡肉 family 合并），这样不会引入交叉匹配风险，但仍然是 alias/canonicalization 变更，需要人工在食材词汇层面确认，属于 `targeted-review-required`，本轮不实施。

## 总体优先级

1. **mechanical-fix-candidate（最值得优先）**：p144、p211 —— 仅需放宽 hard gate 对 same-for-each 的处理（unallocated-group-total 继续 block），复用已验证的拆分逻辑，无 source 重新解读、无信息损失、无需 alias/schema 变更。
2. **targeted-review-required**：p129、p130、p137、p161 —— 需要人工在有限范围内做决策（method-only 数量 policy 或 alias 归类），范围明确但不是代码可独立完成的。
3. **schema-or-policy-required**：p201、p203、p207、p222、p224、p226 —— 现有单值 qty/unit schema 无法无损表达近似量或双数量语义，必须先做 schema/policy 决策。
4. **keep-blocked**：无——12 道全部至少落在上述某个可分析类别，没有「无法归类、只能维持 blocked」的项。

## 下一轮潜在「mechanical remediation」批次

若后续要做一次纯机械放宽（不改变任何标准）：

- 候选：**p144（黄焖鸭子）、p211（花仁萝卜干）**
- 需要改的代码/规则：`scripts/build-dazhong-chuancai-promotion-batch*-dry-run.mjs`（以及未来 batch7 脚本）里的 hard gate 判断，把 `if (ing.memberQuantityMode) return false;` 改为只在 `memberQuantityMode==="unallocated-group-total"` 时拒绝，`same-for-each` 放行；同时 readiness 的 `passesHardGates`（如适用）需同步。
- 风险：需要新增/更新测试确认「仅 same-for-each 放行、unallocated-group-total 继续拒绝」这条边界没有被放宽超出预期，并重新核对完整 12 道漏斗（不能误放 p130/p201/p207，因为它们叠加了其他 blocker）。
- 需要新增的测试：至少一个用例验证 unallocated-group-total 仍然 100% 拒绝、一个验证 same-for-each 单独存在时通过、一个回归验证 p130/p201/p207 仍因叠加 blocker 被拒。

## 必须继续 blocked 的组

- targeted-review-required（p129/p130/p137/p161）与 schema-or-policy-required（p201/p203/p207/p222/p224/p226）共 10 道，在对应决策（alias 归类 / method-only policy / schema 扩展 / 双数量 policy）落地前，继续保持 blocked 是正确状态，不应强行降标准解锁。

## 如果什么都不改

12 道全部维持 blocked **仍是当前唯一正确状态**：每一道都命中至少一个真实存在、已验证的语义完整性风险或未解决的 runtime name gate；hard gate 与 runtime gate 均未误判。本轮的 union 校验（`verificationProblems=[]`）确认了这一点。

## 停止点

本轮仅完成只读 triage 与相关测试；未实施任何 remediation，未 promotion，未新增 alias/unit conversion/schema，未修改任何已有 27 道 production 数据。
