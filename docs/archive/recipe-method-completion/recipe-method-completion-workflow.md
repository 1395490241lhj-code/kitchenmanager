# 菜谱做法补全工作流（Recipe Method Completion Workflow）

本工作流用于**安全地**为缺少做法的菜谱补全「家庭版简明做法」。核心原则：先生成候选与报告，人工审核后再合并，全程不动原始数据。

## 重要原则

1. **不复制书中原文。** 候选做法**完全由本地模板基于「菜名 / 食材 / 标签 + 川菜通用技法」算法生成**，不读取、不抄录任何 PDF / 书中原文。`大众川菜` PDF 仅作人工参考目录，**不进仓库**（`data/reference/` 已在 `.gitignore` 忽略）。
2. **不直接改原始菜谱 JSON。** `data/sichuan-recipes.json` / `data/sichuan-recipes.curated.json` 永不被脚本修改。
3. **不覆盖已有做法。** 合并只写入附加层 `data/recipe-completion-overlay.json`，且运行时仅在 base 无做法时才填入。
4. **不碰 localStorage、不改 localStorage key。** 全流程是构建期 Node 脚本，与浏览器存储无关。
5. **候选全部 `needsReview: true` / `approved: false`，** 必须人工审核改为 `approved: true` 后才会被合并。

## 数据来源与「是否已有做法」判定

审计会综合以下所有做法来源，任一命中即视为「已有做法」，不再生成候选：

- base 菜谱的 `method` / `staticMethod`
- `data/recipe-completion-overlay.json` 的 `recipes[id].method`（按 id）与 `newRecipes`（按菜名）
- `data/recipe-methods.js`（`window.RECIPE_METHODS`，按菜名）
- `data/hoc-recipes.js`（`window.HOC_DATA`，按菜名）

## 产物文件

| 文件 | 说明 |
| --- | --- |
| `data/missing-methods-report.json` | 机器可读缺失报告（总数 / 明细） |
| `data/missing-methods-report.md` | 人类可读缺失报告（按菜型分组表格） |
| `data/recipe-method-candidates.json` | 自动生成的候选做法，全部 `needsReview:true` |

候选条目结构：

```json
{
  "candidates": {
    "<recipeId>": {
      "name": "菜名",
      "method": ["步骤一", "步骤二", "步骤三"],
      "type": "炒菜",
      "source": "generated-from-ingredients",
      "reference": "大众川菜目录/川菜通用技法参考",
      "needsReview": true,
      "approved": false,
      "confidence": "medium"
    }
  }
}
```

> `method` 是分步**数组**；合并时会自动编号拼成 `1. …\n2. …` 字符串（与应用内既有做法格式一致）。

## 步骤一：扫描 + 生成候选

```bash
node scripts/audit-missing-methods.js            # 扫描精简库（默认）
node scripts/audit-missing-methods.js --lib=full # 扫描完整库
```

会重新生成上述三个产物文件。**重跑安全**：候选文件中已 `approved: true` 的条目会被原样保留，不会被覆盖（人工审核结果不丢）。

## 步骤二：人工审核

打开 `data/recipe-method-candidates.json`，逐条检查 `candidates[id]`：

1. 核对菜型 `type` 是否合理（模板按关键词猜测，可能有偏差，例如甜品「冰糖银耳」会被默认归到炒菜）。
2. 修订 `method` 数组为合理的家庭版步骤（短句、3–6 步）。
3. 确认无误后，把该条目的 `approved` 改为 `true`（或把 `needsReview` 改为 `false`）。
4. 未审核 / 不采用的条目保持 `approved:false`，它们不会被合并。

生成器使用的通用川菜流程：处理食材 → 爆香（葱姜蒜 / 豆瓣 / 花椒辣椒）→ 下主料 → 调味 → 烧/炒/煮/收汁 → 出锅；并按菜型（炒菜 / 烧菜红烧 / 凉菜 / 汤羹 / 蒸菜 / 干锅 / 水煮）套用不同模板。

## 步骤三：合并已审核做法

```bash
node scripts/apply-reviewed-methods.js --dry-run  # 先预览将合并哪些
node scripts/apply-reviewed-methods.js            # 实际合并
```

合并行为：

- 只合并 `approved:true` 或 `needsReview:false` 的候选。
- 写入 `data/recipe-completion-overlay.json` 的 `recipes[id].method`。
- 若该 id 在 overlay 已有 `method`，**跳过不覆盖**。
- 不修改任何原始菜谱 JSON、不碰 localStorage。

合并后刷新应用（completion overlay 在运行时由 `src/recipe-completion.js` 自动加载并仅填补无做法的菜）即可看到新做法。

## 回滚

- **撤销一次合并**：用 git 还原 `data/recipe-completion-overlay.json` 即可（`git checkout -- data/recipe-completion-overlay.json` 或 revert 对应提交）。
- **撤销候选/报告**：直接删除或还原 `data/recipe-method-candidates.json` / `data/missing-methods-report.*`，再重跑审计脚本重建。
- 因为做法只写在附加 overlay、且运行时不覆盖已有做法，回滚不会影响原始菜谱与用户数据。

## 不会发生的事

- 不提交 PDF、不提交 OCR 临时文件、不提交 `data/reference/`。
- 不改 `localStorage` key，不改原始菜谱 JSON 结构。
- 不在未审核的情况下把候选写入正式数据。
