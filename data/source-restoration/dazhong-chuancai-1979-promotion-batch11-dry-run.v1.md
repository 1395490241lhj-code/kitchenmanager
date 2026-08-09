# 《大众川菜》1979 Production Batch 11 dry-run

Baseline: c4d2a7b74090bdbee70e1e3fa81d749e786739bd

## 结论

- Design B executable validation: passed (4 exact recipeId+item joins; no array index).
- Funnel: 3 -> 3 -> 0 -> 0 -> 3 -> 3.
- Mechanical order: dz1979-p222 -> dz1979-p226 -> dz1979-p224.
- Temp Curated: 162 -> 165; existing recipe/map drift 0.
- Proposed sidecar: p222 菜油 500/100g; p226 菜油 500/100g; p226 干豆粉 500/200g; p224 菜油 500/100g.
- Quantity review: 21 base-input records; units {"g":20,"个":1}; no consumed fields.
- Production/ledger/readiness/runtime writes: none. applicationReady=false.

本轮不创建 data/recipe-quantity-semantics.json，不正式 promotion Batch11。
