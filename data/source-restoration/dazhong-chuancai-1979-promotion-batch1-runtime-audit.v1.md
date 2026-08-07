# 大众川菜 1979 —— Batch 1 Runtime 兼容性审计

生成时间: 2026-08-07

基线: main/origin/main=4305bcd

只审计不修改：overlay / curated / full / aliases / unit conversion / canonical / readiness / crosswalk / promotion ledger / cache / UI 均未改动。

## 汇总

- 审计 ingredient 总数: **19**（5 道全部 production ingredient，全部带 qty/unit）
- 其中 role=core: **7**
- exact-compatible: **17**
- expected-unit-confirmation: **1**（豆腐）
- unresolved-name-match: **1**（仔母鸡）
- affectedRecipes: **dz1979-p143 当归炖鸡、dz1979-p180 干炒豆腐**

## 真正需要关注的 name 问题

### dz1979-p143 仔母鸡（1 只）→ unresolved-name-match

- canonical(`仔母鸡`) = `仔母鸡`，现有鸡肉 aliases（仔鸡/公鸡/嫩鸡/土鸡/三黄鸡）与 family（鸡肉/鸡脯肉/鸡腿/鸡翅）都无法严格解析该名称。
- 明确失败的 name pairs：**仔母鸡 vs 鸡肉**、**仔母鸡 vs 仔鸡**（以及 老母鸡/土鸡/公鸡/三黄鸡）。
- 仅存在 contains 级脆弱匹配：`仔母鸡` 包含 `母鸡`，`isSmartIngredientMatch` 的 contains 分支会命中，但这是脆弱匹配，严格名称层不成立。
- 这是真正的 name bug：食谱需求名称对用户库存词汇不可见。本轮**不新增 alias**，仅记录；后续应单独评估把 `仔母鸡` 归入鸡肉 alias 或家庭（作为独立 curation 变更）。

## 只是无法安全换算的 unit confirmation

### dz1979-p180 豆腐（6 个）→ expected-unit-confirmation

- 名称可严格解析（豆制品 family 命中），production unit `个` 与常用库存单位 `盒`（`guessKitchenUnit('豆腐')='盒'`）无可安全换算。
- 不是 bug，**禁止新增 个↔盒 换算**；用户需按 `个` 录入库存或人工确认。

## 其余 17 道 exact-compatible

当归 50g、豌豆尖 1000g、苦瓜 500g、青椒 50g、土豆 500g、化猪油 100g、葱 25g、菜油、味精、葱花、醪糟汁及盐类均可在常见名称 + g 单位下 exact 匹配。

### p200 盐 40g 数量来源确认

production `盐 40g` 的来源为 canonical `盐八钱` → exact-mass `40g`（`raw「八钱」→ 40g`），审计记录 provenance note：**未经人工改值**。不因现代常识调整数值。

## 对 Batch 2 gate 的规则建议

1. 新增 gate：new-recipe-candidate 的每个 core/带数量 ingredient 必须先过本审计分类，不得含 `unresolved-name-match` 才可进入 promotion 候选。
2. `unresolved-name-match` 的 item 需要先解决 canonicalization（独立 alias/family curation 提交）后再入选。
3. `expected-unit-confirmation` 不阻塞 promotion，但 promotion ledger 需附注该 unit 差异，提示用户按 production unit 录入库存。
4. 禁止为通过审计新增 `个↔盒` 等无依据换算，禁止为通过测试修改 guessKitchenUnit。

## 验证

- 5 道全部覆盖；19 个 ingredient 每项恰好一个 compatibility 结果
- unresolved-name-match 含具体 name pairs；unit mismatch 未被伪装成 exact
- production 文件 0 diff；JSON parse / node --check / git diff --check 通过
