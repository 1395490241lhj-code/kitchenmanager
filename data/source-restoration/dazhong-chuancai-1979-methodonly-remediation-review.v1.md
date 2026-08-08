# 大众川菜 1979 —— methodOnly Blocker Targeted Review (p129 / p130)

生成时间: 2026-08-08

基线: main/origin/main=759d617a32039ead44a18fd469ba48e1434e0cb0（promoted=29, remaining=10, applicationReady=false）

本轮**只读研究**，不 promotion、不修改 production/ledger/readiness、不新增 alias/unit conversion/schema、不猜测数量、不处理其他 8 道 blocker。

## 范围

- p129 凉拌猪肺：methodOnly「姜、花椒」
- p130 蕃茄丝瓜肉片汤：methodOnly「胡椒面」（same-for-each 已在 Batch 7 解决，不再是本条的独立 blocker）

## 1. Canonical source-restoration 核对

两条 methodOnly 记录均来自已冻结的 `dazhong-chuancai-1979-recipes.v1.json`：

- p129「姜、花椒」：`rawQuantityText=null`，`quantityHandling="做法第1步出现；原料栏未列，无数量"`，`confidence=high`。
- p130「胡椒面」：`rawQuantityText=null`，`quantityHandling="做法第3步出现；原料栏未列，无数量"`，`confidence=high`。

## 2. 原始扫描页 / 本地 PDF

`data/reference/dazhong-chuancai.pdf` 及对应 `tmp/pdfs/dazhong-full` 渲染页在本地不含 pdfPage 142/143（已渲染页范围止于 b04=page-111）。**2026-08-08 补做人工像素级复核**：在真实原始扫描件 `/Users/lianghongjing/Documents/大众川菜 (刘建成等编) (Z-Library).pdf` 上用 `pdftoppm -png -r 200 -f 142 -l 143` 渲染第 142/143 页并目视核对，结论如下：

- **第142页（书页129）**：原料栏仅列猪肺二斤、葱花一两、酱油一两五钱、冬菜一两、味精二分、熟油辣椒一两二钱——**无姜、无花椒**。作法第1步原文："...然后另用开水加葱、姜、花椒煮熟..."，姜、花椒**确实只出现在作法文字**，原料栏与作法文字均**未给出数量**。
- **第143页（书页130）**：原料栏列有猪肉五两、丝瓜二两、绍酒五钱、味精三分、蕃茄三两、葱节·姜各三钱、盐八分、水豆粉一两、酱油四钱——**无胡椒面**。作法第2步末尾原文："汤内下胡椒面、酱油、味精调匀，待锅内汤沸，起锅即成。"，胡椒面**确实只出现在作法文字**，原料栏与作法文字均**未给出数量**。

**两页扫描均与冻结 canonical source-restoration 数据完全一致，未发现任何冲突。**

## 3. 方法文字是否真的提到这些 ingredient

逐字核对 `methodSummary.steps`：

- p129 step 1：「猪肺洗净，在开水锅中"出水"，然后另用开水加葱、姜、花椒煮熟...」——**确实提及「姜」「花椒」**。
- p130 step 3：「汤内下胡椒面、酱油、味精调匀，待锅内汤沸，起锅即成。」——**确实提及「胡椒面」**。

两者均通过机械字符串匹配确认在方法文本中真实出现，非猜测。

## 4. 原书是否确实完全没有 quantity

两条记录的 canonical `rawQuantityText` 均为 `null`，`quantityHandling` 明确注明"原料栏未列，无数量"——这是 source-restoration 阶段已完成的判断，不是本轮重新推断。本轮未重新解读 source，仅核对该判断的既有证据链完整、`confidence=high`。

## 5. 是否属于 core

用**未修改**的真实 `classifyRecipeIngredient()` 逐个拆分子项分类：

| item | role |
| --- | --- |
| 姜 | seasoning |
| 花椒 | seasoning |
| 胡椒面 | seasoning |

三项**全部为 seasoning，非 core**。readiness 自己的 `core-no-quantity` 标签只是命名启发式（未匹配 cooking-medium/optional-alternative 正则时的默认分支），并未调用真实 role 分类器——这是本轮发现的一个术语误导，但不影响安全性结论：真实 role 分类证明这些项从不会进入库存/推荐匹配逻辑。

## 6. qty=null/unit=null 是否能忠实保留且不污染 inventory/recommendation/runtime

- **Schema 层**：当前 curated production 已存在 **607** 条 `qty=null, unit=null` 的 ingredient 记录（多为 seasoning），证明这一 shape 已是现有 schema 的一等公民，非本轮新引入，`normalizeIngredientAmount` 对此有明确处理（返回空字符串，不抛异常）。
- **推荐/库存层**：`src/recommendations.js`（105/500 行）与 `src/ai.js`（946/1118/1563/1725 行）的库存覆盖率、缺货判断、购物清单推荐**均只对 `role==="core"` 的 ingredient 做匹配**。姜/花椒/胡椒面经真实分类均为 `seasoning`，因此无论 qty 是否为 null，这些项**从不参与**上述任何下游逻辑——不会误判缺货，不会污染购物清单，不会影响推荐排序。
- **runtime quality 层**：`recipe-runtime-quality.mjs` 把 `missing-qty-unit` 列为 **warning**（非 error）类别，且当前 curated 已有该 warning 类别非零计数；新增两条不会产生新 error，不会打破 strict 模式判定。

## 重点回答

1. **是否安全允许"source 明确出现但无数量"的 methodOnly ingredient 进入 production（qty=null/unit=null）**：**是，对这两个已逐条确认的具体条目安全**。三项前提全部满足：方法文本确实提及、canonical 确实无数量、真实分类均为 non-core。
2. **该 policy 是否应仅适用于已人工确认的 methodOnly 项，而非全局自动放行**：**是，应严格限定为逐条 targeted-review 确认后的具体 (entryId, item) 组合**，不应做成对所有未来 `core-no-quantity` 项的全局自动放行规则。理由：尚未经人工核对的新 methodOnly 项，其 `rawQuantityText=null` 有可能是**提取遗漏**（extraction gap）而非原书真书面缺失，全局自动放行会绕开这一关键区分，存在误放行"实际有数量但提取时漏掉"的条目的风险。
3. **p129/p130 能否因此解锁**：**结构上可以**——两者的 methodOnly 项均满足安全前提。但本轮**不实施** remediation（按任务要求），仅确认可行性并给出最小实施计划。
4. **对 inventory coverage/recommendation/runtime 的影响**：**无负面影响**。因三项均为 seasoning，不参与任何库存/推荐匹配；runtime quality 仅新增 warning 计数，无新 error。
5. **需要哪些测试**：见下方"最小实施计划"中的测试清单。

## 最小实施计划（若后续决定实施，本轮不执行）

1. 在 readiness `productionIngredientPlan` 中为 p129「姜、花椒」与 p130「胡椒面」新增两条**已确认**的 `inventoryIngredients` 记录：`qty=null, unit=null, displayQuantity=null`（与现有 null-shape 条目结构一致），仅限这两个具体条目，不做全局 `core-no-quantity` 自动转换规则。
2. 在后续机械批次的 hard gate 中新增一个**极窄的例外名单**（如 `CONFIRMED_METHODONLY_NULL_ITEMS = {p129: ["姜","花椒"], p130: ["胡椒面"]}`），只对这两条命中时跳过 `methodOnlyConversionWarning` 阻塞，其余 `core-no-quantity` 条目继续 hard-block。
3. 复用现有 `curate-recipes.js` / quantity-review 生成器逻辑，无需新增 converter 或 schema 字段。

**风险与需要新增的测试**：

- 例外名单需严格限定 entryId+item 组合，测试需断言例外名单外的所有 `core-no-quantity` 条目仍然 hard-block（防止误扩大）。
- 需新增测试验证 p129/p130 放行后通过 hard gate。
- 需新增测试验证 qty=null 的姜/花椒/胡椒面条目不出现在任何 inventory coverage / recommendation / missing-ingredient 结果中（复用现有 `role=seasoning` 过滤逻辑）。
- 需新增测试验证 `recipe-runtime-quality` strict 模式下 `missing-qty-unit` warning 计数按预期 +N，不产生新 error。

## 结论

**安全（safeToAllow=true），已通过人工原始扫描复核确认，无冲突。** p129/p130 的 methodOnly blocker 在满足上述逐条确认前提下可以解锁，但本轮仅完成分析，不实施 remediation、不 promotion、不修改任何 production/ledger/readiness 文件。

## 停止点

本轮仅完成 methodOnly targeted review 与相关测试；未 promotion，未修改 production/ledger/readiness，未新增 alias/unit conversion/schema，未处理其余 8 道 blocker（p137/p161/p201/p203/p207/p222/p224/p226）。
