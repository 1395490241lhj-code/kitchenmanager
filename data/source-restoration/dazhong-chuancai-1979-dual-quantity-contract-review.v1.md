# 《大众川菜》1979 consumed-dual quantity production contract review

生成日期：2026-08-09
Baseline：`6f6b94ba9efa5b02bb90f3eef5fec22ff9d3a48b`
状态：Curated 162 / promoted 36 / remaining 3 / `applicationReady=false`

本轮只做架构设计与兼容性证明；没有 promotion、production data、schema、PWA/iOS runtime、ledger 或 readiness 修改。

## 最终选择

选择 **Design B：独立 dual-quantity sidecar**。

- production ingredient 继续只有 `{item, qty, unit}`；`qty/unit` 永远表示 required input / on-hand requirement。
- 新 sidecar 未来使用 `recipes[recipeId].ingredients[exactProductionItem]` 保存 input、consumed、原始数量文字和 provenance。
- 旧 PWA/iOS 不读取 sidecar，行为完全不变。
- 禁止用数组 index 关联。每个 `(recipeId, item)` 必须精确命中一条 base ingredient；重复 item 直接 no-go。

## 三道原文与 canonical 独立复核

| entryId | 原文 | input | consumed | role | 单 qty/unit 的损失 |
| --- | --- | ---: | ---: | --- | --- |
| p222 酱胡豆 | 菜油 一斤耗二两 | 500g | 100g | seasoning / frying medium | 500g 丢实际油耗；100g 低估炸制所需在手量 |
| p224 拌鱼香豌豆 | 菜油 一斤耗二两 | 500g | 100g | seasoning / frying medium | 同上 |
| p226 蛋酥花仁 | 菜油 一斤耗二两 | 500g | 100g | seasoning / frying medium | 同上 |
| p226 蛋酥花仁 | 干豆粉 一斤耗四两 | 500g | 200g | source-significant coating；runtime 为 seasoning | 单值会丢失 working input 或 actual use；当前 missing/shopping 不读取该 seasoning 行 |

主代理逐页查看原 PDF 第 235、237、239 页，扫描文字与 canonical 一致。p226 做法明确将干豆粉三两调入蛋糊，再以剩余干豆粉裹花生，因此 source contract 必须保留它的 500g input 与 200g consumed。当前 runtime 的直接 raw classifier 对“干豆粉”返回 `core/default-core`，但真实消费者先 canonicalize 为“豆粉”，再分类为 `seasoning/starch`，所以有效旧行为是 `totalCore=0`、`missing=[]`。

## luna_worker #1：写入链

- canonical worker/chunk 与 assembler 会保留并校验 `consumed*`。
- `productionIngredientPlan`、promotion dry-run、quantity-review registry 和 `build-recipe-overlay.js` 都会显式重建三字段，因而丢弃 `consumed*`。
- `curate-recipes.js` 对已存在 ingredient object 使用浅复制，不是主要丢失点。
- 结论：embedded fields 需要贯穿修改多条历史 writer/gate；sidecar 不触碰 162 Curated、Full、冻结 artifacts 或历史 promotion。

## luna_worker #2：消费者链

- 对 runtime core ingredient，inventory availability、missing、recommendation coverage 与 shopping quantity 把 `qty/unit` 当 required input。
- 本轮三道 dual rows 均在 canonicalization 后归为 seasoning（菜油/豆粉），不进入当前 core missing/recommendation/shopping；旧行为不因 sidecar 改变。
- 实际库存扣减不能把 500g 当 100g：PWA 当前重量类走人工档位校准；旧精确扣减弹窗若恢复接线会默认取 `qty`。iOS 默认把 required quantity 作为可编辑 consumed quantity 初值，若不改会过扣。
- PWA loader/merge 可容忍未知字段，但若干 projection 会重建字段，runtime-quality 测试也锁定三字段。iOS `RemoteIngredient` 会安全忽略未知字段，但 consumed 信息不会进入模型。
- 结论：sidecar 对旧消费者兼容；未来实际扣减/实际成本/实际营养必须显式读取 consumed。

## A/B/C 正式比较

评分 1 最差、5 最好；migration/churn/testing 分数越高表示成本越低。

| 维度 | A embedded fields | B sidecar | C 永久 blocked |
| --- | ---: | ---: | ---: |
| source fidelity | 5 | 5 | 5 |
| backward compatibility | 3 | 5 | 5 |
| PWA impact | 3 | 5 | 5 |
| iOS impact | 3 | 5 | 5 |
| inventory correctness | 5 | 5 | 1 |
| recommendation correctness | 5 | 5 | 1 |
| shopping correctness | 5 | 5 | 1 |
| display fidelity | 5 | 4 | 1 |
| migration cost | 1 | 4 | 5 |
| future maintainability | 3 | 4 | 2 |
| historical data churn | 3 | 5 | 5 |
| testing burden | 1 | 4 | 5 |

A 理论上无损，但当前 writer/projection 与质量门禁要求广泛协调修改；“JSON 未知字段可容忍”不能证明字段会全链保留。C 是当前安全临时状态，不是长期 production contract。B 是唯一同时满足 source fidelity、旧消费者零变化、历史数据零 churn 的方案；其主要价值是未来实际消耗、成本、营养与库存扣减语义，不是伪造当前 missing/shopping 行为。

## 推荐 contract shape

```json
{
  "schema": "kitchenmanager.recipe-quantity-semantics.v1",
  "recipes": {
    "dz1979-p226": {
      "ingredients": {
        "干豆粉": {
          "input": { "qty": 500, "unit": "g" },
          "consumed": {
            "qty": 200,
            "unit": "g",
            "referenceQty": null,
            "qualifier": null
          },
          "rawQuantityText": "一斤耗四两",
          "provenance": {
            "sourceId": "dazhong-chuancai-1979",
            "entryId": "dz1979-p226",
            "pdfPage": 239,
            "bookPage": 226
          }
        }
      }
    }
  }
}
```

精确 consumed 使用 `qty`，并要求 `referenceQty/qualifier=null`；近似 consumed 使用 `qty=null + referenceQty + qualifier`。sidecar 的 input 必须与 base ingredient 的 `qty/unit` 数值归一化后完全一致。

## 消费者语义矩阵

| 消费者 | 使用量 |
| --- | --- |
| availability / missing / recommendation / shopping | runtime core 使用 input；本轮 dual seasoning rows 当前不参与 |
| 旧 recipe display | input；安全但 source-incomplete |
| 新 dual-aware display | input + consumed + raw text |
| actual inventory decrement | confirmed actual consumed，sidecar 只提供默认/证据 |
| purchase cash outlay | acquired/input |
| dish cost / loss / actual nutrition / absorption / oil use / yield | consumed |
| theoretical recipe nutrition | input + 独立 yield model |

sidecar 缺失时，actual-consumption 功能必须显式降级或要求用户确认，禁止静默回退为 input。

## 迁移与兼容计划

1. 本轮保持三道 blocked、`applicationReady=false`，不创建 production sidecar。
2. 经明确批准后新增 `data/recipe-quantity-semantics.json`，先验证 identity 唯一与 input/base 一致。
3. 未来 promotion 原子写入：base ingredient 保存 required input；sidecar 保存 consumed/raw/provenance。
4. 旧 PWA/iOS 不新增 fetch/decoder，继续只读三字段。
5. 只有具体 display/actual-consumption 功能获批时，才让对应消费者显式读取 sidecar。
6. 若同一 recipe 出现重复 item，先设计稳定 ingredient id；不得改用数组 index。

未来 promotion 会涉及 sidecar、completion overlay、generated Curated、readiness、ledger、未来 batch11 dry-run/quantity-review/apply/ledger 脚本及其测试；Full 与 batch1-batch10 历史 artifacts 保持不变。本轮没有生成 Batch11。

## Compatibility proof

`test/dazhong-dual-quantity-contract-review.test.mjs` 证明：

- 普通旧 ingredient 与 p222/p224/p226 base ingredient 在 sidecar round-trip 前后 byte-stable；
- input 和 consumed 不互相覆盖，JSON round-trip 无损；
- 每条 metadata 只按 recipeId+item 命中唯一 ingredient，不依赖 index；
- 真实 recommendation inventory analysis 在有/无 sidecar 属性时完全一致；
- production、overlay、ledger、readiness 与 baseline commit 字节一致。

## Go / no-go

Go：identity 唯一、input/base 相等、exact/approx 校验通过、旧 PWA/iOS 与冻结历史测试全绿、actual-consumption 不做 input 静默回退。
No-go：duplicate item、依赖 index、历史 artifact 非预期变化、旧消费者把 input 当实际 consumed，或提前将 `applicationReady` 设为 true。

本 review 的 `applicationReady` 仍为 **false**。
