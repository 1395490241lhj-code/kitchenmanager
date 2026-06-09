# 菜谱库日常化精简 · 报告

> 由 `scripts/curate-recipes.js` 自动生成。原始数据未被修改。

## 数量总览

| 指标 | 数量 |
| --- | ---: |
| 原始菜谱（base + overlay 合并后的有效集） | 322 |
| ├ 其中原始 base | 264 |
| └ 其中 overlay 新增/补全后净增 | 58 |
| **curated 保留** | **126** |
| ├ 从有效集保留（有做法直接保留） | 105 |
| ├ 无做法但日常、值得补全（仍保留） | 13 |
| └ 家庭常用强制补入（新增） | 8 |
| **移出** | **204** |
| **待补全（needing-completion）** | **13** |
| 从 overlay 补全 method 的菜 | 105 |
| 从 overlay 补全 ingredients 的菜 | 66 |
| 移出中的重复菜 | 4 |

## 移出原因分类

- 无做法且不日常（宴席/罕见/工艺/菜名不清）：200
- 重复菜（已有更优版本）：4

## 待补全分布

- 高优先（high）：2
- 中优先（medium）：7
- 低优先（low）：4

## 重复菜处理

- 移出「干煵肉丝」→ 保留「干煸肉丝」
- 移出「罐烧肉（东坡肉）」→ 保留「东坡肉」
- 移出「旱蒸回锅肉」→ 保留「回锅肉」
- 移出「鱼香肉片」→ 保留「鱼香肉丝」

## 强制保留的家庭常用菜

以下 8 道为日常家庭厨房高频菜，**必须存在于 curated**，不进待补全、不移出。
它们不依赖《大众川菜》PDF 是否收录——原始 base / overlay 未收录的，作为
“家庭常用补充菜谱”新增（现代家庭做法，做法简洁、食材拆分清楚）：

1. 麻婆豆腐（id: `fam-mapo-tofu`，tags: 家常菜/豆腐/川菜/麻辣）
2. 番茄炒蛋（id: `fam-tomato-egg`，tags: 家常菜/鸡蛋/快炒）
3. 土豆丝（id: `fam-potato-shreds`，tags: 家常菜/素菜/快炒）
4. 家常豆腐（id: `fam-homestyle-tofu`，tags: 家常菜/豆腐/川菜）
5. 鱼香茄子（id: `fam-yuxiang-eggplant`，tags: 家常菜/素菜/鱼香/川菜）
6. 土豆烧牛肉（id: `fam-potato-beef`，tags: 家常菜/牛肉/红烧）
7. 青椒皮蛋（id: `fam-pepper-century-egg`，tags: 家常菜/凉菜/开胃）
8. 干煸豆角（id: `fam-dry-fried-beans`，tags: 家常菜/素菜/川菜/麻辣）

- 强制全新补入：8
- 已存在仅补全 method/ingredients：0

## 关于《大众川菜》PDF 的使用

`data/reference/dazhong-chuancai.pdf` 为**纯扫描件**（492 张图片，0 字体 / 0 ToUnicode / 无文本层），
无法稳定提取文字。按需求要求“OCR 失败不应中断任务”，本次**未对整本 PDF 做 OCR**：

- 所有做法（method）与细化食材（ingredients）一律以
  `data/recipe-completion-overlay.json` 为权威来源；
- PDF 仅作为概念性核对——确认这些菜名确实出自《大众川菜》，
  并据此判断“日常家常菜 vs 山海味/鸽蛋/田鸡/花式工艺等宴席菜”，
  未逐字抄录 PDF 原文。

## 说明 / 注意事项

- 本脚本只读输入文件，**未修改** `data/sichuan-recipes.json`、用户 localStorage overlay 或任何自定义菜谱。
- 移出判定保守：日常但暂无做法的菜放入待补全而非删除；不确定时倾向保留/待补全。
- 原始 base 菜谱本身不含 method 字段，故“保留的有做法菜”全部来自 overlay 的日常家常菜整理。
- 用户常见但本书未收录的 8 道家庭常用菜，已作为家庭常用补充菜谱加入 curated，不依赖 PDF 收录。
