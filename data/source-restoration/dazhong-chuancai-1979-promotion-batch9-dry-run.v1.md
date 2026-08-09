# 大众川菜 1979 — Production Batch 9 Runtime-name Remediation Dry-run

生成日期：2026-08-08

真实 baseline：`0e7e1d5de768cdd4be19f042f5d861087577f8e7`（runtime-name fix commit）

状态：curated=157，promoted=31，remaining=8，applicationReady=false

## 冻结规则

- 继承 Batch 7 `allow-safe-same-for-each`；`unallocated-group-total` 继续阻塞。
- 继承 Batch 8 exact reviewed methodOnly-null allowlist：仅 p129 姜/花椒、p130 胡椒面。
- Batch 9 不新增或扩大 quantity、methodOnly、alias、family、canonical、schema、unit conversion policy。
- runtime gate 仅检查 core ingredient；`unresolved-name-match` 阻塞，`expected-unit-confirmation` 记录但不阻塞。

## 机械漏斗

`8 remaining -> hard-blocked 6 -> after-hard 2 -> runtime-blocked 0 -> eligible 2 -> selected 2`

机械排序结果：

| 顺位 | entry | 菜名 | source production item | runtime core | quantity review |
| --- | --- | --- | --- | --- | --- |
| 1 | dz1979-p161 | 拌鸡血 | 鸡血 500g | exact 2 / unit-confirmation 1 / unresolved 0 | 10 |
| 2 | dz1979-p137 | 椒麻鸡块 | 子公鸡 1只 | exact 1 / unit-confirmation 2 / unresolved 0 | 8 |

- p137 proposed ingredient 仍为“子公鸡”；runtime canonical 为“鸡肉”；`只/份` 仅保留 expected-unit-confirmation，不阻塞。
- p161 proposed ingredient 与 runtime canonical 均为独立“鸡血”；不映射鸡肉或鸭血。
- quantity-review 共 18 条，仅登记真实非 null qty/unit；单位分布为 `g:17`、`只:1`。

## 临时 promotion 链验证

- temp curated：157 -> 159；exactly +2 recipes / +2 ingredient maps。
- existing recipe objects、ingredient maps、deleted recipes：0 drift。
- Full、recipe-curation-removed、recipes-needing-completion：0 semantic change。
- 两次 temp curate byte-identical；PWA merge 与 iOS decode shape 通过。
- workspace production、ledger、readiness、canonical source、crosswalk、name-matches：相对 runtime-fix baseline 0 diff。
- Batch 1-8 frozen artifacts 与 runtime-name review JSON/MD：byte-identical。

## 继续阻塞

- non-exact quantity：p201、p203、p207。
- consumed-dual quantity：p222、p224、p226。

本 artifact 只记录 Batch 9 dry-run；不执行正式 promotion，不修改 production/ledger/readiness，不处理剩余 quantity blockers。
