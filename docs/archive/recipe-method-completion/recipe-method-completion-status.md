# Recipe Method Completion Status

> 菜谱做法补全工作的阶段性状态快照（生成于 commit `1cc4d11` 之后）。
> 本文件仅为状态记录，不改任何 candidates / overlay / 原始菜谱 JSON / 脚本。

## 当前结论

- **curated 库缺做法已全部补齐**（0 道缺失）。
- **full 库仅补齐「家常可控子集」**（23 道），其余保持留空。
- **C 组与复杂 B 组建议保持留空或逐道人工处理**，不套用通用模板。

## 当前数据状态

| 指标 | 数值 |
| --- | --- |
| overlay recipes 总数 | 53 |
| curated 总数 | 109 |
| curated 缺做法 | 0 |
| full 总数 | 264 |
| full 已有做法 | 141 |
| full 缺做法 | 123 |
| curated candidates approved | 22 / 22 |
| full candidates approved | 23 / 146 |
| full 未审核 | 123 |

> 审计口径说明：`scripts/audit-missing-methods.js` 的 `hasMethod` **计入 completion-overlay**，因此以上 curated 缺做法=0、full 缺做法=123 均为「**含 overlay**」口径，不是 base-only。
> overlay 账目：53 = 8（原始 completion 自带）+ 22（curated 合并）+ 23（full 合并）。

## 已完成批次（按提交记录）

### 工具与审核文档
| commit | 内容 |
| --- | --- |
| `dd70b1f` | 离线做法补全工作流（audit / apply 脚本 + 初版报告/候选） |
| `68857c7` | 菜型识别与模板优化（甜羹/鱼类细分/干煸/宫保/虾仁等） |
| `6ad56ee` | curated 剩余 13 道候选审核清单（docs） |
| `da2c89c` | full 完整库家常可补全筛选 A/B/C（docs） |

### curated 库（共 22 道）
| commit | 批次 | 道数 |
| --- | --- | --- |
| `a973a6c` | 首批（reviewed method candidates） | 9 |
| `5bc1600` | A 组 | 6 |
| `21db29a` | B 组 | 6 |
| `8f4097a` | C 组（葱酥鱼，cong su yu） | 1 |

### full 库（共 23 道）
| commit | 批次 | 道数 |
| --- | --- | --- |
| `6be6359` | A 组（A-group） | 8 |
| `cd150fd` | 第二批稳定（second-batch stable） | 5 |
| `2aef5c4` | 第三批重写（third-batch reviewed） | 8 |
| `787bf91` | 双色豆腐淖（doufu nao） | 1 |
| `1cc4d11` | 酿萝卜（niang luobo） | 1 |

合计：curated 22 + full 23 = **45 道**（另加 8 道原始 completion = overlay 53 条）。

## 保护边界

- **原始菜谱 JSON 未改**：`data/sichuan-recipes.json`、`data/sichuan-recipes.curated.json` 全程零改动。
- **recipe_ingredients 未改**：补全只写 `overlay.recipes[id].method`，从未新增/修改用料表；`overlay.recipe_ingredients` 仍是原始 completion 自带的 8 个键。
- **localStorage key 未改**：`src/storage.js` 的 `km_v*` key 全部不变。
- **overlay 只补 method**：每条补全条目仅含 `method` 字段，无其它异常字段。
- **不覆盖 base 已有做法**：`applyCompletionOverlay` 仅在 base 无做法时填入；`apply-reviewed-methods.js` 对 overlay 中已有 method 的 id 一律跳过。
- **酿萝卜（`ex--514e3fd8`）**：肉馅只写在 **method 文本**（「另备少量猪肉馅」），**没有改食材表**，原始 `recipe_ingredients` 仍为 `[{"item":"白萝卜"}]`，不影响库存匹配/扣减。

## 后续建议

- **目前可以阶段性收尾**：curated 已补齐，full 家常子集已补齐，数据结构与账目自洽。
- **full 剩余 123 道不建议用通用模板自动补**。
- **C 组建议跳过**：鱼翅、鱼肚、海参、甲鱼、野味（鹿/麂等）、复杂传统甜点（玫瑰锅炸/糖粘羊尾/网油枣卷等）。
- **如继续**：只能从 B 组每批挑 5–10 道，走「人工审核 → `--dry-run` → apply」流程，逐批小步推进。

## 手动验收清单

在 App 中验收以下 10 道（均为 full 库菜，需切到**完整库 / full** 模式）：

- 酿萝卜
- 双色豆腐淖
- 清烩虾仁
- 软炸口蘑
- 酿冬菇
- 芹黄鱼丝
- 白汁豆腐饼
- 软炸虾糕
- 翡翠虾仁
- 酸辣虾羹汤

每道测试点：

- **full 模式下能搜索到**（开启「只看有做法」仍出现）。
- **快速详情弹窗显示做法**（做法摘要区有文字，非「暂无做法」）。
- **完整详情页显示做法**（制作方法 Method 区显示完整分步）。
- **步骤换行正常**（`\n` 渲染为多行，步骤 1/2/3/4 各自成行）。
- **不覆盖原始已有做法**（打开本就有做法的菜，内容与原来一致；切回精简库这些菜不出现）。

---

_快照生成：基于 `main` @ `1cc4d11`。后续如有新批次，请追加对应 commit 并更新数据状态表。_
