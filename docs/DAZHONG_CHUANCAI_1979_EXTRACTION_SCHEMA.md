# 《大众川菜》1979 来源恢复提取结构

本结构只用于 `applicationReady=false` 的来源恢复中间数据。页面图像是事实依据；
OCR 只能辅助定位，不得覆盖视觉读法。不得修改生产 Curated/Full、Overlay、缓存戳、
UI 或生产 schema。

## 批次输出

每个批次临时输出一个 JSON 对象：

```json
{
  "batchId": "dz1979-b01",
  "applicationReady": false,
  "recipes": [],
  "batchReview": {
    "workerVisualReview": true,
    "ocrUsedAsAuthority": false,
    "renderedPdfPages": [],
    "unresolved": []
  }
}
```

## 菜谱对象

每道菜包含以下字段：

```json
{
  "entryId": "dz1979-p027",
  "batchId": "dz1979-b01",
  "bookName": "回锅肉",
  "category": "肉食类",
  "source": {
    "pdfStartPage": 40,
    "pdfEndPage": 41,
    "bookStartPage": 27,
    "bookEndPage": 28
  },
  "titleVisualCheck": {
    "observedText": "回锅肉",
    "matchesCatalog": true,
    "confidence": "high",
    "notes": null
  },
  "ingredients": [],
  "methodSummary": {
    "steps": [],
    "dialectOrOldTerms": [],
    "confidence": "high"
  },
  "characteristicsSummary": "",
  "methodOnlyIngredients": [],
  "nonIngredientMaterials": {
    "tools": [],
    "containers": [],
    "fuels": [],
    "cleaningMaterials": [],
    "nonEdiblePackaging": []
  },
  "confirmedReadings": [],
  "uncertainties": [],
  "projectMatch": {
    "classification": "exact-name",
    "projectName": "回锅肉",
    "projectIds": [],
    "candidateProjectName": null,
    "reviewRequired": false
  },
  "confidence": {
    "recognition": "high",
    "conversion": "high"
  }
}
```

- `source` 覆盖该菜从标题页到下一道菜标题前一页。PDF 与书内页均从 1 开始。
- `titleVisualCheck` 必须直接查看标题图像后填写，不能从目录或项目名复制后默认通过。
- `methodSummary.steps` 必须为 2–6 步，只摘要关键技法、顺序、火候和状态判断，
  不逐字抄录整段做法。
- `characteristicsSummary` 忠实概括原书“特点”；原书没有明确特点时写明未见独立特点段。
- `dialectOrOldTerms` 每项记录 `raw`、`modernSummary`（可为 null）、`confidence`、
  `notes`，不能擅自解释不清术语。
- `confirmedReadings` 保留经视觉确认且需要防止后续误改的原词或句子；5 道已批准
  试点中的确认读法必须原样保留。

## 原料与数量

`ingredients` 只放原料栏印出的项目。每项至少包含：

```json
{
  "rawItemText": "味精、胡椒",
  "rawQuantityText": "各三分",
  "normalizedQuantity": {
    "kind": "exact-mass",
    "qty": 1.5,
    "unit": "g",
    "appliesTo": "each-item",
    "qualifier": null
  },
  "memberQuantityMode": "same-for-each",
  "members": [
    { "item": "味精", "qty": 1.5, "unit": "g" },
    { "item": "胡椒", "qty": 1.5, "unit": "g" }
  ],
  "conversionBasis": "原文有‘各’；每项 3 × 0.5g",
  "confidence": {
    "recognition": "high",
    "conversion": "high"
  }
}
```

允许的 `normalizedQuantity.kind`：

- `exact-mass`：可证明的精确质量，单位为 `g`。
- `exact-count`：精确计数，保留 `个、只、根、粒、张、副、段、方、把、头、块` 等单位。
- `range-mass` / `range-count`：`qty` 为 null，另存 `minQty`、`maxQty`、`unit`。
- `approximate-mass` / `approximate-count`：`qty` 为 null，可存 `referenceQty`，并保留
  `qualifier`，不得把约数当精确值。
- `qualitative-amount`：少许、适量等，`qty` 为 null。
- `unresolved`：表达或末级单位不能证明，`qty/unit` 均为 null；候选只能放在
  `conversionCandidate` 且 `accepted=false`。

换算固定为：`1斤=500g`、`1两=50g`、`1钱=5g`、`1分=0.5g`。
液体按原书质量转换成 g，不猜 ml；做法中的寸、分等长度不做质量换算。

“一斤耗二两”一类同时给出投料量和明确耗用量的表达，仍属于可证明的精确质量：
`qty/unit` 保存投料量，并以 `consumedQty/consumedUnit` 保存“耗”后的等值质量；两者都必须
写入 `conversionBasis`，不得只保留其中一个值。

若“耗”后的数量带“约”等约数词（例如“一斤五两耗油约一两八钱”），`qty/unit`
仍保存可证明的精确投料量；耗用量必须以 `consumedReferenceQty/consumedUnit` 和
`consumedQualifier` 保存，不能写成 `consumedQty`，也不能把约数当成精确值。

并列原料：

- 有“各”：`memberQuantityMode="same-for-each"`，每个 member 获得相同 qty/unit。
- 无“各”：`memberQuantityMode="unallocated-group-total"`，保存 `groupTotal`，每个
  member 的 qty/unit 必须为 null。
- 始终保留 `rawItemText` 和 `rawQuantityText`。

## 方法中出现的内容

- 原料栏未列、只在做法中出现的可食用内容放 `methodOnlyIngredients`，记录原词、
  数量原文（没有则为 null）、用途、置信度和数量处理；不得混入 `ingredients`。
- 方法中用于煮、焖、兑汁而原料栏未列的水也按上述规则记录；仅用于冲洗、浸发后弃去的水
  记录在 `cleaningMaterials`，避免把清洗材料伪装成成菜原料。
- 纯工具、容器、燃料、清洗材料和不可食包装分别放入
  `nonIngredientMaterials` 对应数组。
- 可食且构成菜体的包裹、绑扎或外围食材保留为食材；是否来自原料栏仍按上述边界区分。

## 不确定项

`uncertainties` 每项包含：

- `location`：标题、原料、做法或特点的具体位置；
- `type`：`unclear-glyph`、`unresolved-quantity`、`allocation-unknown`、
  `old-term` 或 `page-boundary`；
- `rawText`：能够确认的原文片段；
- `candidates`：可为空数组；
- `treatment`：说明为何未转换或未解释。

遇到不清内容应记录并继续处理其他菜谱，不得猜测。

## 项目名称映射

从当前 `dazhong-chuancai-1979-name-matches.v1.json` 读取名称候选，并转换为本任务分类：

- `exact_name` -> `exact-name`
- `clear_alias` -> `confirmed-alias`
- `suspected_match` -> `probable-match-needs-review`
- `book_only` -> `book-only`

`exact-name` 与 `confirmed-alias` 记录 Curated/Full 中所有对应 ID。
`probable-match-needs-review` 不绑定项目 ID：`projectName` 为 null、`projectIds=[]`，
只在 `candidateProjectName` 保存候选名称。

内容一致性（原料、做法、候选用途）在最终 crosswalk 阶段统一计算，提取批次不得覆盖生产数据。
