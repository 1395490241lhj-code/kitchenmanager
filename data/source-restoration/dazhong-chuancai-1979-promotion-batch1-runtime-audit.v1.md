# 大众川菜 1979 —— Batch 1 Runtime 兼容性审计

生成时间: 2026-08-07

基线: main/origin/main=4305bcd

只审计不修改：overlay / curated / full / aliases / unit conversion / canonical / readiness / crosswalk / promotion ledger / cache / UI 均未改动。

## 汇总

- 审计 ingredient 总数: **19**（5 道全部 production ingredient，全部带 qty/unit）
- core（参与库存/推荐匹配）: **7**
- non-core（seasoning/non-stock，仅 quantity provenance）: **12**
- coreCompatibilityCounts（三分类只用于 core）:
  - exact-compatible: **5**
  - expected-unit-confirmation: **1**（豆腐）
  - unresolved-name-match: **1**（仔母鸡）
- affectedRecipes: **dz1979-p143 当归炖鸡、dz1979-p180 干炒豆腐**

exact-compatible 的判定必须有真实证据：名称严格可解析，且存在 production unit 下真实 `getStockCoverageAnalysis=exact` 的 probe；不再仅因 `unit=g` 判定。

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

## 其余 5 道 core exact-compatible

当归 50g、豌豆尖 1000g、苦瓜 500g、青椒 50g、土豆 500g 均在常见名称 + g 单位下存在真实 exact 证据。

### non-core 的 quantity provenance

12 个 seasoning（盐/菜油/味精/葱花/醪糟汁/化猪油/葱等）不进入库存名称三分类，但保留 quantity provenance。例如 p200 `盐 40g` 的来源为 canonical `盐八钱` → exact-mass `40g`，记录 **未经人工改值**；不因现代常识调整数值。

## 对 Batch 2 gate 的规则建议

1. 只检查 candidate 的 **core** ingredients：任何 core `unresolved-name-match` 阻塞 promotion。
2. core `expected-unit-confirmation` 不阻塞，但必须记录（ledger 附注 unit 差异，提示用户按 production unit 录入库存）。
3. seasoning 不参与库存名称兼容 gate，但其 qty/unit 仍受已有 quantity-review 质量门禁约束。
4. `unresolved-name-match` 的 core item 需先解决 canonicalization（独立 alias/family curation 提交）后再入选。
5. 禁止为通过审计新增 `个↔盒` 等无依据换算，禁止为通过测试修改 guessKitchenUnit。

## 验证

- 5 道全部覆盖；19 个 ingredient 每项恰好一个 compatibility 结果
- unresolved-name-match 含具体 name pairs；unit mismatch 未被伪装成 exact
- production 文件 0 diff；JSON parse / node --check / git diff --check 通过
