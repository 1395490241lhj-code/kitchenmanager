# 《大众川菜》1979 final quantity blocker review

生成日期：2026-08-08
Baseline：24c6d4a4a7f4bbcff3feba63e833007bc91602a3
范围：最后 6 道；只读 review，不 promotion。

## 结论

- p201/p203/p207：扫描原文均为“花椒 十余粒”，真实 role=seasoning；只允许逐条 (entryId,花椒) 以 qty=null/unit=null 解锁，不猜数字，不扩 schema。
- p222/p224/p226：“一斤耗二两/四两”同时表达 input 与 consumed。当前单 qty/unit 无法无损承载；本轮继续 hard-block，未来只有明确双量 schema 与 consumer contract 后再处理。
- luna_worker 是辅助独立审计；最终结论由主代理复核 canonical、原扫描和真实下游代码后作出。

## 逐道证据与处置

| entryId | 菜名 | 扫描证据 | blocker | safeToUnlock | schemaExtension | 推荐 |
| --- | --- | --- | --- | ---: | ---: | --- |
| dz1979-p201 | 炝黄瓜 | 花椒 十余粒 | non-exact-quantity | true | false | allow-reviewed-nonexact-null |
| dz1979-p203 | 炝绿豆芽 | 花椒 十余粒 | non-exact-quantity | true | false | allow-reviewed-nonexact-null |
| dz1979-p207 | 炝莲花白 | 花椒 十余粒 | non-exact-quantity | true | false | allow-reviewed-nonexact-null |
| dz1979-p222 | 酱胡豆 | 菜油 一斤耗二两 | consumed-dual-quantity | false | true | continue-blocked-until-dual-quantity-contract |
| dz1979-p224 | 拌鱼香豌豆 | 菜油 一斤耗二两 | consumed-dual-quantity | false | true | continue-blocked-until-dual-quantity-contract |
| dz1979-p226 | 蛋酥花仁 | 菜油 一斤耗二两；干豆粉 一斤耗四两 | consumed-dual-quantity | false | true | continue-blocked-until-dual-quantity-contract |

## 最小 allowlist

- (dz1979-p201, 花椒)
- (dz1979-p203, 花椒)
- (dz1979-p207, 花椒)

## 下游判断

non-exact 花椒经真实 classifier 为 seasoning，不进入核心库存覆盖、缺货、推荐或菜谱缺货购物；null/null 只增加已有 runtime-quality warning。consumed-dual 的 production 单 qty/unit 会被核心库存、缺货、推荐和购物共同当作唯一需求量，不能混用 input 与 consumed。

## 保护

review 生成前 production invariant：curated=159、Full=264、promoted=33、remaining=6、applicationReady=false。generator 只写本 review JSON/MD。
