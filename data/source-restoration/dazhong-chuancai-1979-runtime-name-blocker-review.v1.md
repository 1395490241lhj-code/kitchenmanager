# 《大众川菜》1979 runtime-name blocker targeted review

生成日期：2026-08-08
baseline：06b2324a4aeca3db915d3c223e758ffa13eff890
范围：p137 子公鸡、p161 鸡血；当前 promoted=31、remaining=8、applicationReady=false。

本轮只读：不 promotion，不修改 production/ledger/readiness，不新增 alias/canonical/unit conversion。原始 PDF：/Users/lianghongjing/Documents/大众川菜 (刘建成等编) (Z-Library).pdf

## 结论

- **p137 椒麻鸡块 / 子公鸡**：推荐精确 alias 子公鸡 -> 鸡肉。这依赖既有仔鸡、公鸡等明确 alias 约定，不是按“含鸡”自动扩 family；不改 chicken family broad/members。修复后仍需保留只与份的 unit confirmation 语义。
- **p161 拌鸡血 / 鸡血**：推荐独立 canonical 鸡血 + 窄 runtime recognition。不得映射鸡肉，也不得映射鸭血；鸡血库存与鸭血库存必须保持 exact species boundary。
- 两条只有在各自最小修复和回归测试完成后才安全解锁；本轮不实施，当前仍 blocked。

## Source / runtime / downstream evidence

## dz1979-p137 椒麻鸡块

- 原扫描：书页 137 / PDF page 150；子公鸡一只（约三斤）
- 方法证据：选子公鸡杀后去毛及内脏……煮至刚熟时，捞起晾冷。
- 当前 canonical：子公鸡；alias：无；family：无；role：core
- 当前 runtime：unresolved-name-match；未严格解析 probe：鸡肉、仔鸡、母鸡、老母鸡、土鸡、公鸡、三黄鸡
- 推荐：**exact-alias-to-鸡肉**。
- 最小代码改动：只加一个精确 alias，并补 matcher/inventory/recommendation/shopping 回归；不新增 family member、不做 contains heuristic、不改 unit conversion。

### 方案判断

| 方案 | 结论 | 影响 |
| --- | --- | --- |
| exact alias | recommended | getStockCoverageAnalysis 会让鸡肉/仔鸡/公鸡/土鸡库存满足该 recipe；推荐目标会沿现有鸡肉 family 展开；购物清单会把子公鸡 canonicalize 为鸡肉，丢失“幼公鸡”标签。 |
| 独立 canonical | lower-compatibility | 保留子公鸡独立，库存/推荐/购物清单只精确识别子公鸡，避免鸡肉 family 的宽匹配；但用户已有鸡肉/仔鸡库存不会满足 recipe。 |
| 保持 blocked | safe-now | 不改变任何运行时行为，但保留已确认的词汇缺口。 |

## dz1979-p161 拌鸡血

- 原扫描：书页 161 / PDF page 174；鸡血一斤
- 方法证据：将鸡血（或鸭血）切成四分见方的丁……
- 当前 canonical：鸡血；alias：无；family：无；role：core
- 当前 runtime：unresolved-name-match；未严格解析 probe：鸡肉、仔鸡、母鸡、老母鸡、土鸡、公鸡、三黄鸡
- 推荐：**new-independent-canonical-鸡血**。
- 最小代码改动：新增独立鸡血 canonical/runtime 分类路径，并补 exact 鸡血、拒绝鸭血/鸡肉的 inventory/recommendation/shopping 回归；不新增 alias 到任何既有 canonical。

### 方案判断

| 方案 | 结论 | 影响 |
| --- | --- | --- |
| exact alias | rejected | 不存在安全的现有 canonical alias 目标；映射鸡肉或鸭血都会造成跨组织/跨物种库存、推荐和购物清单污染。 |
| 独立 canonical | recommended | 鸡血库存可满足 p161；鸭血、鸡肉均不能满足；推荐与购物清单保留鸡血名称，不跨物种合并。 |
| 保持 blocked | safe-now | 不改变任何运行时行为，继续阻止 promotion，避免错误映射。 |

## 未改动保护

当前 production/ledger/readiness invariant：

- curated=157，promoted=31，remaining=8，applicationReady=false
- p137/p161 不在 curated、Full 或 promoted ledger，readiness state 均为 not-promoted
- review generator 只写 review JSON/MD 两个输出，不写 production、ledger、readiness、alias 或 canonical 文件

## 风险

- p137 alias 会把购物清单中的“子公鸡”规范显示为“鸡肉”，并复用现有 chicken family sibling match；这是可接受但必须明确记录的产品语义取舍。
- p161 若误用鸡肉/鸭血 alias，会分别造成跨组织或跨物种库存、推荐、购物清单误匹配；因此只能走独立 canonical 路径。
- 两条都不应借 runtime-name review 顺便修改单位换算、family 定义或其他 8 道 blocker。
