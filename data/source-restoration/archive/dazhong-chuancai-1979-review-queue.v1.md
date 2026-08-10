# 大众川菜 1979 来源恢复 —— 人工复核队列

生成时间: 2026-08-07T02:12:03Z

基线: assembled=data/source-restoration/dazhong-chuancai-1979-recipes.v1.json, commit=63e6701, applicationReady=False

## 汇总

- 去重后需复核菜谱总数: **59**
- high: 46　medium: 13　low: 0
- 需要重新查看扫描页: 25
- 仅需crosswalk阶段处理: 34

说明：本队列不解决任何疑难项，不重新解释旧词，不修改147道来源数据。标记为 contentMissing / scan-page-blank 的条目仅表示当前PDF扫描件对应页面无正文，不对是否为原书印刷缺页作出判断。

## High (46)

### dz1979-p038 「鱼香碎滑肉」 — dz1979-b01

- 页码: PDF 51-52 / 书内 38-39
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - 整体confidence.recognition或confidence.conversion未达high
- 当前可确认事实:
  - 标题经视觉核对为「鱼香碎滑肉」，与目录一致（confidence=high）
  - 原料栏已记录 13 项
  - 特点栏文字已保留
  - projectMatch=exact-name，已匹配「鱼香碎滑肉」
- 尚未确认的问题:
  - 整体confidence={'recognition': 'medium', 'conversion': 'high'}

### dz1979-p041 「花椒肉」 — dz1979-b01

- 页码: PDF 54 / 书内 41
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - 整体confidence.recognition或confidence.conversion未达high
- 当前可确认事实:
  - 标题经视觉核对为「花椒肉」，与目录一致（confidence=high）
  - 原料栏已记录 9 项
  - 特点栏文字已保留
  - projectMatch=exact-name，已匹配「花椒肉」
- 尚未确认的问题:
  - 整体confidence={'recognition': 'medium', 'conversion': 'high'}

### dz1979-p042 「东坡肉」 — dz1979-b01

- 页码: PDF 55-56 / 书内 42-43
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - 整体confidence.recognition或confidence.conversion未达high
- 当前可确认事实:
  - 标题经视觉核对为「东坡肉」，与目录一致（confidence=high）
  - 原料栏已记录 10 项
  - 特点栏文字已保留
  - 已确认读法：做法第3步及附注 — 「下垫篾巴」
  - projectMatch=exact-name，已匹配「东坡肉」
- 尚未确认的问题:
  - 整体confidence={'recognition': 'medium', 'conversion': 'high'}

### dz1979-p049 「红枣煨肘」 — dz1979-b02

- 页码: PDF 62 / 书内 49
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
- 当前可确认事实:
  - 标题经视觉核对为「红枣煨肘」，与目录一致（confidence=high）
  - 原料栏已记录 4 项
  - 特点栏文字已保留
  - projectMatch=exact-name，已匹配「红枣煨肘」
- 尚未确认的问题:
  - [allocation-unknown（用量在原料栏与做法间的归属未确认）] 做法第2–3步：一两冰糖炒成糖汁；再放冰糖

### dz1979-p050 「板栗烧肉」 — dz1979-b02

- 页码: PDF 63 / 书内 50
- 是否需重新查看扫描页: 是
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
- 当前可确认事实:
  - 标题经视觉核对为「板栗烧肉」，与目录一致（confidence=high）
  - 原料栏已记录 8 项
  - 特点栏文字已保留
  - projectMatch=exact-name，已匹配「板栗烧肉」
- 尚未确认的问题:
  - [unclear-glyph（字形无法稳定判定）] 做法第2步：然后□入锅内
  - [allocation-unknown（用量在原料栏与做法间的归属未确认）] 做法第1–2步：锅内下菜油一两；加入五钱冰糖

### dz1979-p051 「红烧狮子头」 — dz1979-b02

- 页码: PDF 64-65 / 书内 51-52
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - 整体confidence.recognition或confidence.conversion未达high
  - 至少一项原料confidence.recognition或confidence.conversion未达high
- 当前可确认事实:
  - 标题经视觉核对为「红烧狮子头」，与目录一致（confidence=high）
  - 原料栏已记录 14 项
  - 特点栏文字已保留
  - projectMatch=exact-name，已匹配「红烧狮子头」
- 尚未确认的问题:
  - [allocation-unknown（用量在原料栏与做法间的归属未确认）] 做法第2、4步：酱油（二钱）；加酱油
  - 原料「化猪油 一斤半二两」置信度未达high（{'recognition': 'high', 'conversion': 'medium'}）：1斤 + 半斤 + 2两 = 500g + 250g + 100g
  - 整体confidence={'recognition': 'high', 'conversion': 'medium'}

### dz1979-p066 「炖酥肉」 — dz1979-b03

- 页码: PDF 79-80 / 书内 66-67
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - 整体confidence.recognition或confidence.conversion未达high
  - 至少一项原料confidence.recognition或confidence.conversion未达high
- 当前可确认事实:
  - 标题经视觉核对为「炖酥肉」，与目录一致（confidence=high）
  - 原料栏已记录 10 项
  - 特点栏文字已保留
  - 已确认读法：做法 — 「泡泡肉」
  - 已确认读法：做法 — 「豆分」
  - 已确认读法：原料栏 — 「菜油 二斤耗二两」
  - projectMatch=exact-name，已匹配「炖酥肉」
- 尚未确认的问题:
  - 原料「菜油 二斤耗二两」置信度未达high（{'recognition': 'high', 'conversion': 'low'}）：原文“二斤耗二两”：投入二斤=1000g，实际耗用二两=100g，总投入与耗用分别保存
  - 整体confidence={'recognition': 'high', 'conversion': 'low'}

### dz1979-p079 「锅粑肉片」 — dz1979-b03

- 页码: PDF 92-93 / 书内 79-80
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - 整体confidence.recognition或confidence.conversion未达high
  - 至少一项原料confidence.recognition或confidence.conversion未达high
- 当前可确认事实:
  - 标题经视觉核对为「锅粑肉片」，与目录一致（confidence=high）
  - 原料栏已记录 16 项
  - 特点栏文字已保留
  - 已确认读法：做法 — 「锅粑」
  - 已确认读法：做法 — 「马耳朵节子」
  - 已确认读法：做法 — 「散籽」
  - 已确认读法：原料栏 — 「菜油 一斤五两耗油约一两八钱」
- 尚未确认的问题:
  - 原料「菜油 一斤五两耗油约一两八钱」置信度未达high（{'recognition': 'high', 'conversion': 'low'}）：原文“一斤五两耗油约一两八钱”：投入一斤五两=750g，约耗一两八钱=约90g，总投入与约耗分别保存
  - 整体confidence={'recognition': 'high', 'conversion': 'low'}

### dz1979-p082 「青椒肉丝」 — dz1979-b03

- 页码: PDF 95 / 书内 82
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
- 当前可确认事实:
  - 标题经视觉核对为「青椒肉丝」，与目录一致（confidence=high）
  - 原料栏已记录 8 项
  - 特点栏文字已保留
  - 已确认读法：做法 — 「二粗丝」
  - 已确认读法：做法 — 「出新不久」
  - projectMatch=exact-name，已匹配「青椒肉丝」
- 尚未确认的问题:
  - [old-term（旧词/方言用语，字形已确认但词义未证实或未现代化改写）] 附注：出新不久的青辣椒
  - [allocation-unknown（用量在原料栏与做法间的归属未确认）] 原料与做法：水豆粉一两五钱

### dz1979-p086 「家常肉丝干豇」 — dz1979-b04

- 页码: PDF 99 / 书内 86
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - 整体confidence.recognition或confidence.conversion未达high
- 当前可确认事实:
  - 标题经视觉核对为「家常肉丝干豇」，与目录一致（confidence=high）
  - 原料栏已记录 7 项
  - 特点栏文字已保留
  - 已确认读法：标题 — 「家常肉丝干豇」
  - projectMatch=exact-name，已匹配「家常肉丝干豇」
- 尚未确认的问题:
  - [old-term（旧词/方言用语，字形已确认但词义未证实或未现代化改写）] 标题：干豇
  - 整体confidence={'recognition': 'medium', 'conversion': 'high'}

### dz1979-p093 「红烧丸子」 — dz1979-b04

- 页码: PDF 106-107 / 书内 93-94
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - 至少一项原料confidence.recognition或confidence.conversion未达high
- 当前可确认事实:
  - 标题经视觉核对为「红烧丸子」，与目录一致（confidence=high）
  - 原料栏已记录 13 项
  - 特点栏文字已保留
  - 已确认读法：原料栏 — 「菜油 一斤耗二两」
  - projectMatch=exact-name，已匹配「红烧丸子」
- 尚未确认的问题:
  - 原料「菜油 一斤耗二两」置信度未达high（{'recognition': 'high', 'conversion': 'low'}）：原文"一斤耗二两"：投入一斤=500g，实际耗用二两=100g，总投入与耗用分别保存

### dz1979-p100 「豆芽肉饼汤」 — dz1979-b05

- 页码: PDF 113 / 书内 100
- 是否需重新查看扫描页: 是
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - methodSummary.confidence未达high
  - dialectOrOldTerms中至少一项confidence未达high或缺失confidence字段
- 当前可确认事实:
  - 标题经视觉核对为「豆芽肉饼汤」，与目录一致（confidence=high）
  - 原料栏已记录 9 项
  - 特点栏文字已保留
  - 已确认读法：做法第1步 — 「肥二瘦八」
  - 已确认读法：做法第2步 — 「豆芽掐足洗净」
- 尚未确认的问题:
  - [page-boundary（页边界/印刷缺失）] 特点：页面在做法第2步“加盐、酱油、胡椒等调味）。”后留白结束
  - [allocation-unknown（用量在原料栏与做法间的归属未确认）] 做法与原料栏：盐、酱油分别在肉饼调制和汤内调味中出现
  - methodSummary整体confidence=medium
  - 旧词/方言用语「赶入盘中」confidence=medium（字形确认；该时代用语语义未作现代化改写。）
  - 旧词/方言用语「掐足」confidence=medium（字形确认，语义保留原词。）

### dz1979-p101 「酸菜肉丝汤」 — dz1979-b05

- 页码: PDF 114 / 书内 101
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
- 当前可确认事实:
  - 标题经视觉核对为「酸菜肉丝汤」，与目录一致（confidence=high）
  - 原料栏已记录 7 项
  - 特点栏文字已保留
  - 已确认读法：做法第1步 — 「切成二粗丝」
  - 已确认读法：做法第2步 — 「烧至汤内有泡青菜味」
- 尚未确认的问题:
  - [allocation-unknown（用量在原料栏与做法间的归属未确认）] 原料与做法：盐三分分别用于汤内调味和肉丝码味
  - [old-term（旧词/方言用语，字形已确认但词义未证实或未现代化改写）] 做法第1步：鸡蛋用蛋清和干豆粉调成蛋清豆粉

### dz1979-p102 「粉蒸排骨」 — dz1979-b05

- 页码: PDF 115-116 / 书内 102-103
- 是否需重新查看扫描页: 是
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - 至少一项原料confidence.recognition或confidence.conversion未达high
- 当前可确认事实:
  - 标题经视觉核对为「粉蒸排骨」，与目录一致（confidence=high）
  - 原料栏已记录 12 项
  - 特点栏文字已保留
  - 已确认读法：做法第1步 — 「砍成长约一寸二节子」
  - 已确认读法：做法第2步 — 「合铡成细末」
  - 已确认读法：做法第4步 — 「用旺火沸水将肉蒸至酥烂」
  - projectMatch=exact-name，已匹配「粉蒸排骨」
- 尚未确认的问题:
  - [unclear-glyph（字形无法稳定判定）] 原料栏与做法第3步：原料栏“甜椒 三钱”与做法“甜酱”
  - [unclear-glyph（字形无法稳定判定）] 原料栏：醪糟汁 五钱
  - [unresolved-quantity（数量表述未能精确折算）] 原料栏：花椒 二十余粒
  - 原料「花椒 二十余粒」置信度未达high（{'recognition': 'high', 'conversion': 'medium'}）：“二十余粒”为约数计数，保留参考值20粒和“余”限定，不作为精确值，也不换算为质量
  - 原料「甜椒 三钱」置信度未达high（{'recognition': 'medium', 'conversion': 'high'}）：三钱 × 5g = 15g
  - 原料「醪糟汁 五钱」置信度未达high（{'recognition': 'medium', 'conversion': 'high'}）：五钱 × 5g = 25g；按原书质量单位保存为g，不推测毫升

### dz1979-p104 「鱼香排骨」 — dz1979-b05

- 页码: PDF 117 / 书内 104
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
- 当前可确认事实:
  - 标题经视觉核对为「鱼香排骨」，与目录一致（confidence=high）
  - 原料栏已记录 10 项
  - 特点栏文字已保留
  - 已确认读法：做法第2步 — 「煸干水汽（除血腥味）」
  - 已确认读法：做法第2步 — 「葱花（用一半）同炒」
  - 已确认读法：做法第2步 — 「肉松散能与骨脱离」
  - projectMatch=exact-name，已匹配「鱼香排骨」
- 尚未确认的问题:
  - [allocation-unknown（用量在原料栏与做法间的归属未确认）] 原料与做法：蒜米、葱花各一两；做法“蒜和葱花（用一半）同炒”，起锅再加葱花
  - [old-term（旧词/方言用语，字形已确认但词义未证实或未现代化改写）] 做法第2步：锅内放油

### dz1979-p105 「糖醋排骨」 — dz1979-b05

- 页码: PDF 118 / 书内 105
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - 至少一项原料confidence.recognition或confidence.conversion未达high
- 当前可确认事实:
  - 标题经视觉核对为「糖醋排骨」，与目录一致（confidence=high）
  - 原料栏已记录 11 项
  - 特点栏文字已保留
  - 已确认读法：做法第2步 — 「下排骨煸干水气」
  - 已确认读法：做法第2步 — 「如有绍酒可加绍酒一两」
  - 已确认读法：做法第3步 — 「视排骨入味肉软时」
  - projectMatch=exact-name，已匹配「糖醋排骨」
- 尚未确认的问题:
  - [unresolved-quantity（数量表述未能精确折算）] 原料栏：醋 一两二
  - [allocation-unknown（用量在原料栏与做法间的归属未确认）] 原料栏：姜、蒜片 五钱
  - 原料「醋 一两二」置信度未达high（{'recognition': 'high', 'conversion': 'medium'}）：“一两二”按一两二钱读，50g + 2 × 5g = 60g；末级单位省略，转换置信度记为medium

### dz1979-p106 「家常排骨」 — dz1979-b05

- 页码: PDF 119 / 书内 106
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - 至少一项原料confidence.recognition或confidence.conversion未达high
  - dialectOrOldTerms中至少一项confidence未达high或缺失confidence字段
- 当前可确认事实:
  - 标题经视觉核对为「家常排骨」，与目录一致（confidence=high）
  - 原料栏已记录 10 项
  - 特点栏文字已保留
  - 已确认读法：做法第1步 — 「宽厚八分的块子」
  - 已确认读法：做法第2步 — 「下排骨煸干水汽」
  - 已确认读法：做法第2步 — 「到肉㸆、菜熟时」
  - projectMatch=exact-name，已匹配「家常排骨」
- 尚未确认的问题:
  - [unresolved-quantity（数量表述未能精确折算）] 原料栏：花椒 十余粒
  - [allocation-unknown（用量在原料栏与做法间的归属未确认）] 原料栏：葱姜 六钱
  - [old-term（旧词/方言用语，字形已确认但词义未证实或未现代化改写）] 做法第2步：到肉㸆、菜熟时
  - 原料「花椒 十余粒」置信度未达high（{'recognition': 'high', 'conversion': 'medium'}）：“十余粒”为约数计数，保留参考值10粒和“余”限定，不作为精确值，也不换算为质量
  - 旧词/方言用语「肉㸆」confidence=medium（字形可辨但该时代用语语义未作现代化改写。）

### dz1979-p107 「苤蓝烧牛肉」 — dz1979-b05

- 页码: PDF 120-121 / 书内 107-108
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - 至少一项原料confidence.recognition或confidence.conversion未达high
  - dialectOrOldTerms中至少一项confidence未达high或缺失confidence字段
- 当前可确认事实:
  - 标题经视觉核对为「苤蓝烧牛肉」，与目录一致（confidence=high）
  - 原料栏已记录 11 项
  - 特点栏文字已保留
  - 已确认读法：做法第1步 — 「将牛的肋条肉洗净，宰成七分大小的块子」
  - 已确认读法：做法第2步 — 「水以淹没牛肉一寸左右为宜」
  - 已确认读法：做法第2步 — 「沥去豆瓣渣不用，只将豆瓣汁水倒入」
  - projectMatch=exact-name，已匹配「苤蓝烧牛肉」
- 尚未确认的问题:
  - [unresolved-quantity（数量表述未能精确折算）] 原料栏：花椒 十余粒
  - [allocation-unknown（用量在原料栏与做法间的归属未确认）] 原料栏：葱姜 五钱
  - [old-term（旧词/方言用语，字形已确认但词义未证实或未现代化改写）] 做法第2步：放在小火上㸆至七成㸆时
  - [allocation-unknown（用量在原料栏与做法间的归属未确认）] 做法第2步：做法统称“香料”
  - 原料「花椒 十余粒」置信度未达high（{'recognition': 'high', 'conversion': 'medium'}）：“十余粒”为约数计数，保留参考值10粒和“余”限定，不作为精确值，也不换算为质量
  - 旧词/方言用语「㸆」confidence=medium（川菜火候用语，字形可辨；语义未作现代化改写。）

### dz1979-p109 「干拌牛肉」 — dz1979-b05

- 页码: PDF 122 / 书内 109
- 是否需重新查看扫描页: 是
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - 至少一项原料confidence.recognition或confidence.conversion未达high
- 当前可确认事实:
  - 标题经视觉核对为「干拌牛肉」，与目录一致（confidence=high）
  - 原料栏已记录 9 项
  - 特点栏文字已保留
  - 已确认读法：做法第1步 — 「捞起晾冷后切成片」
  - 已确认读法：做法第1步 — 「葱切八分节」
  - projectMatch=exact-name，已匹配「干拌牛肉」
- 尚未确认的问题:
  - [unclear-glyph（字形无法稳定判定）] 原料栏：炒花生米 十余颗
  - [unresolved-quantity（数量表述未能精确折算）] 原料栏：炒花生米 十余颗
  - 原料「炒花生米 十余颗」置信度未达high（{'recognition': 'medium', 'conversion': 'medium'}）：“十余颗”为约数计数，保留参考值10颗和“余”限定，不作为精确值，也不换算为质量

### dz1979-p110 「麻辣牛肉干」 — dz1979-b05

- 页码: PDF 123 / 书内 110
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - dialectOrOldTerms中至少一项confidence未达high或缺失confidence字段
- 当前可确认事实:
  - 标题经视觉核对为「麻辣牛肉干」，与目录一致（confidence=high）
  - 原料栏已记录 9 项
  - 特点栏文字已保留
  - 已确认读法：原料栏 — 「菜油 一斤耗二两」
  - 已确认读法：做法第2步 — 「油炸进皮则滗去大部分炸油」
  - 已确认读法：做法第2步 — 「汤干亮油」
  - projectMatch=exact-name，已匹配「麻辣牛肉干」
- 尚未确认的问题:
  - [allocation-unknown（用量在原料栏与做法间的归属未确认）] 原料栏：酱油、葱姜 各六钱
  - [old-term（旧词/方言用语，字形已确认但词义未证实或未现代化改写）] 做法第2步：油炸进皮则滗去大部分炸油
  - 旧词/方言用语「油炸进皮」confidence=medium（字形可辨；该时代炸制程度用语，语义未作现代化改写。）

### dz1979-p111 「水煮牛肉」 — dz1979-b05

- 页码: PDF 124-125 / 书内 111-112
- 是否需重新查看扫描页: 是
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - 至少一项原料confidence.recognition或confidence.conversion未达high
- 当前可确认事实:
  - 标题经视觉核对为「水煮牛肉」，与目录一致（confidence=high）
  - 原料栏已记录 13 项
  - 特点栏文字已保留
  - 已确认读法：做法第1步 — 「在锅里炕脆」
  - 已确认读法：做法第1步 — 「在菜板上铡细」
  - 已确认读法：做法第2步 — 「用筷子轻轻拨散」
  - projectMatch=exact-name，已匹配「水煮牛肉」
- 尚未确认的问题:
  - [unresolved-quantity（数量表述未能精确折算）] 原料栏：花椒 十余粒
  - [allocation-unknown（用量在原料栏与做法间的归属未确认）] 原料与做法：菜油二两分三次使用：炕辣椒“少许”、煸蔬菜“少许”、烧豆瓣及最后淋油“少许”
  - [page-boundary（页边界/印刷缺失）] 做法第2步：掺汤烧开
  - 原料「花椒 十余粒」置信度未达high（{'recognition': 'high', 'conversion': 'medium'}）：“十余粒”为约数计数，保留参考值10粒和“余”限定，不作为精确值，也不换算为质量

### dz1979-p113 「牛肉末炒芹菜花」 — dz1979-b05

- 页码: PDF 126-127 / 书内 113-114
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
- 当前可确认事实:
  - 标题经视觉核对为「牛肉末炒芹菜花」，与目录一致（confidence=high）
  - 原料栏已记录 11 项
  - 特点栏文字已保留
  - 已确认读法：做法第1步 — 「切成约一分长的颗子」
  - 已确认读法：做法第2步 — 「剔去白筋，剁成细粒」
  - 已确认读法：做法第3步 — 「烧至干酥时」
  - projectMatch=exact-name，已匹配「牛肉末炒芹菜花」
- 尚未确认的问题:
  - [allocation-unknown（用量在原料栏与做法间的归属未确认）] 原料与做法：盐二分；做法第1步“用少许盐拌匀”，第3步再加盐

### dz1979-p115 「粉蒸牛肉」 — dz1979-b06

- 页码: PDF 128-129 / 书内 115-116
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - 至少一项原料confidence.recognition或confidence.conversion未达high
- 当前可确认事实:
  - 标题经视觉核对为「粉蒸牛肉」，与目录一致（confidence=high）
  - 原料栏已记录 10 项
  - 特点栏文字已保留
  - 已确认读法：做法第1步 — 「切成长约一寸二、宽约八分的片子」
  - 已确认读法：做法第2步 — 「铡成细末」
  - 已确认读法：做法第4步 — 「用旺火沸水蒸炬」
  - projectMatch=exact-name，已匹配「粉蒸牛肉」
- 尚未确认的问题:
  - 原料「花椒 十余粒」置信度未达high（{'recognition': 'high', 'conversion': 'medium'}）：“十余粒”为约数计数，保留参考值10粒和“余”限定，不作为精确值，也不换算为质量

### dz1979-p121 「豌豆肥肠汤」 — dz1979-b06

- 页码: PDF 134 / 书内 121
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - 至少一项原料confidence.recognition或confidence.conversion未达high
- 当前可确认事实:
  - 标题经视觉核对为「豌豆肥肠汤」，与目录一致（confidence=high）
  - 原料栏已记录 6 项
  - 特点栏文字已保留
  - 已确认读法：原料栏 — 「味精、胡椒 各三分」
  - 已确认读法：做法第3步 — 「炖至七成炬时，捞起肥肠」
  - projectMatch=exact-name，已匹配「豌豆肥肠汤」
- 尚未确认的问题:
  - 原料「花椒 十余粒」置信度未达high（{'recognition': 'high', 'conversion': 'medium'}）：“十余粒”为约数计数，保留参考值10粒和“余”限定，不作为精确值，也不换算为质量

### dz1979-p122 「蒜烧肚条」 — dz1979-b06

- 页码: PDF 135 / 书内 122
- 是否需重新查看扫描页: 是
- 复核原因:
  - contentMissing=true（本页在扫描件中完全无正文）
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - 整体confidence.recognition或confidence.conversion未达high
  - methodSummary.confidence未达high
- 当前可确认事实:
  - 标题经视觉核对为「蒜烧肚条」，与目录一致（confidence=high）
  - 已确认读法：页面标题（PDF第135页/书内第122页） — 「蒜烧肚条」
- 尚未确认的问题:
  - [page-boundary（页边界/印刷缺失）] 整页：PDF第135页仅印有标题“蒜烧肚条”，标题下方及全页其余区域经像素级复核（200dpi与600dpi两次渲染，全页扫描无任何字迹墨点，仅有边角散布的扫描噪点，尺寸2-4像素、位置与文字笔画不符）确认无正文印刷内容
  - methodSummary整体confidence=None

### dz1979-p123 「清蒸杂烩」 — dz1979-b06

- 页码: PDF 136-137 / 书内 123-124
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - 至少一项原料confidence.recognition或confidence.conversion未达high
  - dialectOrOldTerms中至少一项confidence未达high或缺失confidence字段
- 当前可确认事实:
  - 标题经视觉核对为「清蒸杂烩」，与目录一致（confidence=high）
  - 原料栏已记录 16 项
  - 特点栏文字已保留
  - 已确认读法：正文标题（PDF第136页/书内第123页） — 「清蒸杂烩」
  - 已确认读法：原料栏 — 「菜油 一斤五两耗一两」
  - 已确认读法：做法第7步 — 「上笼蒸至酥肉泡发，翻倒入碗内灌汤」
  - projectMatch=exact-name，已匹配「清蒸杂烩」
- 尚未确认的问题:
  - 原料「花椒 十余粒」置信度未达high（{'recognition': 'high', 'conversion': 'medium'}）：“十余粒”为约数计数，保留参考值10粒和“余”限定，不作为精确值，也不换算为质量
  - 旧词/方言用语「泡泡肉」confidence=medium（字形确认，语义按上下文推断保留原词）
  - 旧词/方言用语「渣渣肉」confidence=medium（字形确认，语义按上下文推断保留原词）

### dz1979-p127 「大蒜烧肥肠」 — dz1979-b06

- 页码: PDF 140-141 / 书内 127-128
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - 至少一项原料confidence.recognition或confidence.conversion未达high
- 当前可确认事实:
  - 标题经视觉核对为「大蒜烧肥肠」，与目录一致（confidence=high）
  - 原料栏已记录 10 项
  - 特点栏文字已保留
  - 已确认读法：做法第3步 — 「白糖炒化，掺水少许，炒成不深不浅的糖汁」
  - 已确认读法：做法第4步 — 「用小火煨至七成炬时加大蒜，直至全炬后加味精」
- 尚未确认的问题:
  - 原料「花椒 十余粒」置信度未达high（{'recognition': 'high', 'conversion': 'medium'}）：“十余粒”为约数计数，保留参考值10粒和“余”限定，不作为精确值，也不换算为质量

### dz1979-p131 「麻辣兔丁」 — dz1979-b06

- 页码: PDF 144 / 书内 131
- 是否需重新查看扫描页: 是
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - 整体confidence.recognition或confidence.conversion未达high
- 当前可确认事实:
  - 标题经视觉核对为「麻辣兔丁」，与目录一致（confidence=high）
  - 原料栏已记录 8 项
  - 特点栏文字已保留
  - 已确认读法：做法第1步 — 「砍成五分见方的兔丁」
  - 已确认读法：做法第1步 — 「豆豉在菜板上用力压成豆豉酱」
  - 已确认读法：三 特点 — 「麻辣味匝，酒饭皆宜」
- 尚未确认的问题:
  - [unclear-glyph（字形无法稳定判定）] 三 特点：麻辣味匝，酒饭皆宜
  - 整体confidence={'recognition': 'medium', 'conversion': 'high'}

### dz1979-p135 「盐水仔鸡」 — dz1979-b07

- 页码: PDF 148 / 书内 135
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - 至少一项原料confidence.recognition或confidence.conversion未达high
- 当前可确认事实:
  - 标题经视觉核对为「盐水仔鸡」，与目录一致（confidence=high）
  - 原料栏已记录 7 项
  - 特点栏文字已保留
  - 已确认读法：做法第1步 — 「用盐和花椒在鸡的里外抹匀」
  - 已确认读法：做法第2步 — 「上笼蒸三小时」
- 尚未确认的问题:
  - 原料「花椒 十余粒」置信度未达high（{'recognition': 'high', 'conversion': 'medium'}）：“十余粒”为约数计数，保留参考值10粒和“余”限定，不作为精确值，也不换算为质量

### dz1979-p138 「红油鸡块」 — dz1979-b07

- 页码: PDF 151 / 书内 138
- 是否需重新查看扫描页: 是
- 复核原因:
  - contentMissing=true（本页在扫描件中完全无正文）
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - 整体confidence.recognition或confidence.conversion未达high
  - methodSummary.confidence未达high
  - titleVisualCheck.confidence未达high
- 当前可确认事实:
  - 标题经视觉核对为「（页面无可见标题）按目录页序归位为红油鸡块」，与目录一致（confidence=medium）
- 尚未确认的问题:
  - [page-boundary（页边界/印刷缺失）] 整页：PDF第151页经220dpi与600dpi两次渲染确认全页无任何可见印刷内容（标题、原料栏、做法栏、特点栏均未印出）
  - methodSummary整体confidence=None
  - 标题视觉核对confidence=medium：PDF第151页经220dpi与600dpi两次渲染确认全页空白，无任何标题文字；本条目归属仅依据目录页序（书内第138页），非页面可见标题。

### dz1979-p141 「热味姜汁鸡」 — dz1979-b07

- 页码: PDF 154 / 书内 141
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - projectMatch.reviewRequired=true（项目匹配待人工确认）
- 当前可确认事实:
  - 标题经视觉核对为「热味姜汁鸡」，与目录一致（confidence=high）
  - 原料栏已记录 7 项
  - 特点栏文字已保留
  - 已确认读法：做法第1步 — 「姜剁成细米，葱切细花」
  - 已确认读法：做法第2步 — 「临起锅时下醋及葱花合匀入盘即成」
- 尚未确认的问题:
  - projectMatch候选「热窝姜汁鸡」（classification=probable-match-needs-review）尚待人工确认是否为同一项目

### dz1979-p142 「香菌烧鸡」 — dz1979-b07

- 页码: PDF 155 / 书内 142
- 是否需重新查看扫描页: 是
- 复核原因:
  - projectMatch.reviewRequired=true（项目匹配待人工确认）
  - contentIncomplete=true（正文在扫描件中中途截断/缺失部分栏目）
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - methodSummary.confidence未达high
- 当前可确认事实:
  - 标题经视觉核对为「香菌烧鸡」，与目录一致（confidence=high）
  - 原料栏已记录 9 项
  - 已确认读法：做法第1步 — 「香菌用温热水泡胀洗净」
  - 已确认读法：原料栏 — 「汤 二斤五两」
- 尚未确认的问题:
  - [page-boundary（页边界/印刷缺失）] 做法第2步起及特点栏：当前扫描件PDF第155页正文在做法第1步后结束，页面底部为空白；其后PDF第156页为下一条目“当归炖鸡”的起始页，无本条目连续正文
  - projectMatch classification=book-only，尚无匹配项目，待人工确认（book-only 或需补建）
  - methodSummary整体confidence=medium

### dz1979-p145 「蘑芋烧鸭」 — dz1979-b07

- 页码: PDF 158-159 / 书内 145-146
- 是否需重新查看扫描页: 是
- 复核原因:
  - projectMatch.reviewRequired=true（项目匹配待人工确认）
  - contentIncomplete=true（正文在扫描件中中途截断/缺失部分栏目）
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - 整体confidence.recognition或confidence.conversion未达high
  - methodSummary.confidence未达high
  - titleVisualCheck.confidence未达high
- 当前可确认事实:
  - 标题经视觉核对为「（起始页无可见标题）按目录页序归位为蘑芋烧鸭」，与目录一致（confidence=medium）
  - 特点栏文字已保留
  - 已确认读法：做法第2步（续存正文） — 「烧至七成粑」
  - 已确认读法：特点栏 — 「色泽红亮，味浓而鲜」
- 尚未确认的问题:
  - [page-boundary（页边界/印刷缺失）] 标题、原料栏、做法起始（含第1步前半）：PDF第158页经220dpi与600dpi两次渲染确认全页空白；PDF第159页仅存本条目的连续正文尾部（第1步后半起）、特点与附注
  - projectMatch classification=confirmed-alias，尚无匹配项目，待人工确认（book-only 或需补建）
  - methodSummary整体confidence=medium
  - 标题视觉核对confidence=medium：PDF第158页经220dpi与600dpi两次渲染确认全页空白，标题、原料栏与做法起始均未印出；本条目归属仅依据目录页序（书内第145页）及PDF第159页的连续正文推断。

### dz1979-p147 「芋儿烧鸭」 — dz1979-b07

- 页码: PDF 160-161 / 书内 147-148
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - 至少一项原料confidence.recognition或confidence.conversion未达high
- 当前可确认事实:
  - 标题经视觉核对为「芋儿烧鸭」，与目录一致（confidence=high）
  - 原料栏已记录 11 项
  - 特点栏文字已保留
  - 已确认读法：做法第2步 — 「撇去浮沫，移小火上加盖煨起」
  - 已确认读法：做法第3步 — 「烧至全粑，即拈去姜、葱不用」
- 尚未确认的问题:
  - 原料「花椒 十余粒」置信度未达high（{'recognition': 'high', 'conversion': 'medium'}）：“十余粒”为约数计数，保留参考值10粒和“余”限定，不作为精确值，也不换算为质量

### dz1979-p149 「青豆焖鸭条」 — dz1979-b07

- 页码: PDF 162-163 / 书内 149-150
- 是否需重新查看扫描页: 是
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - 至少一项原料confidence.recognition或confidence.conversion未达high
  - dialectOrOldTerms中至少一项confidence未达high或缺失confidence字段
- 当前可确认事实:
  - 标题经视觉核对为「青豆焖鸭条」，与目录一致（confidence=high）
  - 原料栏已记录 12 项
  - 特点栏文字已保留
  - 已确认读法：做法第1步 — 「内脏整理后，可加葱、姜、蒜、泡红辣椒等，用油炒成鸭什件」
  - 已确认读法：附注 — 「如不喜欢吃辣味的，可稍加泡红辣椒短节，不用豆瓣」
- 尚未确认的问题:
  - [unclear-glyph（字形无法稳定判定）] 做法第3步（五成炬/全炬）：炬
  - 原料「花椒 十余粒」置信度未达high（{'recognition': 'high', 'conversion': 'medium'}）：“十余粒”为约数计数，保留参考值10粒和“余”限定，不作为精确值，也不换算为质量
  - 旧词/方言用语「炬」confidence=medium（字形较模糊，无法完全确认是否为“炬”“焐”或其他近似字；字形与语义均未得到来源独立佐证，不作语义推断）

### dz1979-p152 「番茄炒蛋」 — dz1979-b07

- 页码: PDF 165 / 书内 152
- 是否需重新查看扫描页: 是
- 复核原因:
  - contentMissing=true（本页在扫描件中完全无正文）
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - 整体confidence.recognition或confidence.conversion未达high
  - methodSummary.confidence未达high
  - titleVisualCheck.confidence未达high
- 当前可确认事实:
  - 标题经视觉核对为「（页面无可见标题）按目录页序归位为番茄炒蛋」，与目录一致（confidence=medium）
  - projectMatch=exact-name，已匹配「番茄炒蛋」
- 尚未确认的问题:
  - [page-boundary（页边界/印刷缺失）] 整页：PDF第165页经220dpi与600dpi两次渲染确认全页无任何可见印刷内容（标题、原料栏、做法栏、特点栏均未印出）
  - methodSummary整体confidence=None
  - 标题视觉核对confidence=medium：PDF第165页经220dpi与600dpi两次渲染确认全页空白，无任何标题文字；本条目归属仅依据目录页序（书内第152页），非页面可见标题。PDF第166页为下一批次条目“绍子蒸蛋”的起始页，无本条目内容。

### dz1979-p155 「芹黄炒什件」 — dz1979-b08

- 页码: PDF 168-169 / 书内 155-156
- 是否需重新查看扫描页: 是
- 复核原因:
  - projectMatch.reviewRequired=true（项目匹配待人工确认）
  - contentIncomplete=true（正文在扫描件中中途截断/缺失部分栏目）
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
- 当前可确认事实:
  - 标题经视觉核对为「芹黄炒什件」，与目录一致（confidence=high）
  - 原料栏已记录 12 项
  - 已确认读法：做法第2步 — 「葱和泡红辣椒切“马耳朵”节」
  - 已确认读法：做法第4步（正文中断处逐字保留） — 「炒锅内油烧至六成热时，把盐、剩下的水豆粉跟鸡」
- 尚未确认的问题:
  - [page-boundary（页边界/印刷缺失）] 做法第4步及以后、特点栏：PDF第168页做法第4步在“把盐、剩下的水豆粉跟鸡”后行末中断；PDF第169页仅存本条目做法第3-4步的延续正文（与168页第3-4步重复对应，无更多新内容），该页下方大片空白，其后PDF第170页为下一条目“炒鸭肝”的起始页，无本条目连续正文
  - projectMatch classification=book-only，尚无匹配项目，待人工确认（book-only 或需补建）

### dz1979-p157 「炒鸭肝」 — dz1979-b08

- 页码: PDF 170-171 / 书内 157-158
- 是否需重新查看扫描页: 是
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - 整体confidence.recognition或confidence.conversion未达high
  - 至少一项原料confidence.recognition或confidence.conversion未达high
  - dialectOrOldTerms中至少一项confidence未达high或缺失confidence字段
- 当前可确认事实:
  - 标题经视觉核对为「炒鸭肝」，与目录一致（confidence=high）
  - 原料栏已记录 14 项
  - 特点栏文字已保留
  - 已确认读法：做法第1步 — 「注意不要片烂」
  - 已确认读法：做法第3步 — 「烹时调料要搅匀」
- 尚未确认的问题:
  - [unclear-glyph（字形无法稳定判定）] 原料栏：姜二钱、蒜二钱
  - 原料「姜 二钱」置信度未达high（{'recognition': 'medium', 'conversion': 'high'}）：二钱 × 5g = 10g
  - 原料「蒜 二钱」置信度未达high（{'recognition': 'medium', 'conversion': 'high'}）：二钱 × 5g = 10g
  - 旧词/方言用语「散籽」confidence=medium（）
  - 整体confidence={'recognition': 'medium', 'conversion': 'high'}

### dz1979-p168 「豆腐鱼」 — dz1979-b08

- 页码: PDF 181-182 / 书内 168-169
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - projectMatch.reviewRequired=true（项目匹配待人工确认）
- 当前可确认事实:
  - 标题经视觉核对为「豆腐鱼」，与目录一致（confidence=high）
  - 原料栏已记录 12 项
  - 特点栏文字已保留
  - 已确认读法：做法第3步 — 「用原油将豆瓣煵酥」
- 尚未确认的问题:
  - projectMatch候选「豆腐鲫鱼」（classification=probable-match-needs-review）尚待人工确认是否为同一项目

### dz1979-p171 「大蒜烧鳝鱼」 — dz1979-b08

- 页码: PDF 184-185 / 书内 171-172
- 是否需重新查看扫描页: 是
- 复核原因:
  - projectMatch.reviewRequired=true（项目匹配待人工确认）
  - contentIncomplete=true（正文在扫描件中中途截断/缺失部分栏目）
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
- 当前可确认事实:
  - 标题经视觉核对为「大蒜烧鳝鱼」，与目录一致（confidence=high）
  - 原料栏已记录 12 项
  - 已确认读法：做法第2步 — 「煵至鳝鱼不粘锅、吐油时铲起」
- 尚未确认的问题:
  - [page-boundary（页边界/印刷缺失）] 特点栏：PDF第185页做法第3步结束于“撒上花椒面即可。”句后，页面下方约三分之二为大片空白，未见“三 特点”标题及正文；其后PDF第186页为下一条目“干煸鳝鱼丝”的起始页，无本条目连续正文
  - projectMatch classification=book-only，尚无匹配项目，待人工确认（book-only 或需补建）

### dz1979-p173 「干煸鳝鱼丝」 — dz1979-b08

- 页码: PDF 186-189 / 书内 173-176
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - projectMatch.reviewRequired=true（项目匹配待人工确认）
- 当前可确认事实:
  - 标题经视觉核对为「干煸鳝鱼丝」，与目录一致（confidence=high）
  - 原料栏已记录 12 项
  - 特点栏文字已保留
  - 已确认读法：做法第2步 — 「以煸干水汽，鳝鱼吐油为度」
- 尚未确认的问题:
  - projectMatch候选「干煸鳝鱼」（classification=probable-match-needs-review）尚待人工确认是否为同一项目

### dz1979-p177 「麻辣豆腐」 — dz1979-b09

- 页码: PDF 190-191 / 书内 177-178
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - projectMatch.reviewRequired=true（项目匹配待人工确认）
- 当前可确认事实:
  - 标题经视觉核对为「麻辣豆腐」，与目录一致（confidence=high）
  - 原料栏已记录 12 项
  - 特点栏文字已保留
  - 已确认读法：特点栏后附注 — 「附注：若有牛、羊肉，按上述作法做成的豆腐也很可口。」
- 尚未确认的问题:
  - projectMatch候选「麻婆豆腐」（classification=probable-match-needs-review）尚待人工确认是否为同一项目

### dz1979-p181 「鱼香油菜苔」 — dz1979-b09

- 页码: PDF 194-195 / 书内 181-182
- 是否需重新查看扫描页: 是
- 复核原因:
  - projectMatch.reviewRequired=true（项目匹配待人工确认）
  - contentIncomplete=true（正文在扫描件中中途截断/缺失部分栏目）
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
- 当前可确认事实:
  - 标题经视觉核对为「鱼香油菜苔」，与目录一致（confidence=high）
  - 原料栏已记录 11 项
  - 已确认读法：做法第3步（本条目正文在本扫描件中的最后一句完整可见） — 「炒锅置旺火上烧热，下油菜苔（加盐少许）炒至熟而带脆（不炒烂）时铲起。」
- 尚未确认的问题:
  - [page-boundary（页边界/印刷缺失）] 做法第4步及以后、特点栏：PDF第195页顶部延续做法第3步末句“炒锅置旺火上烧热，下油菜苔（加盐少许）炒至熟而带脆（不炒烂）时铲起。”，其后一行“4.锅内放菜油烧至……”起始文字因印墨严重褪色、字形大面积缺损而不可辨认；该行以下页面大片空白，未见后续做法正文与“三 特点”标题及内容；其后PDF第196页为下一条目“酱烧苦瓜”的起始页，无本条目连续正文
  - projectMatch classification=book-only，尚无匹配项目，待人工确认（book-only 或需补建）

### dz1979-p206 「烧拌莴笋」 — dz1979-b10

- 页码: PDF 219 / 书内 206
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - projectMatch.reviewRequired=true（项目匹配待人工确认）
- 当前可确认事实:
  - 标题经视觉核对为「烧拌莴笋」，与目录一致（confidence=high）
  - 原料栏已记录 7 项
  - 特点栏文字已保留
- 尚未确认的问题:
  - projectMatch候选「烧拌鲜笋」（classification=probable-match-needs-review）尚待人工确认是否为同一项目

### dz1979-p217 「米汤煮青菜」 — dz1979-b11

- 页码: PDF 230 / 书内 217
- 是否需重新查看扫描页: 是
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - 至少一项原料confidence.recognition或confidence.conversion未达high
  - dialectOrOldTerms中至少一项confidence未达high或缺失confidence字段
- 当前可确认事实:
  - 标题经视觉核对为「米汤煮青菜」，与目录一致（confidence=high）
  - 原料栏已记录 5 项
  - 特点栏文字已保留
  - 已确认读法：特点栏后附注 — 「如用苔菜，即为“米汤煮苔菜”。作法是：选新鲜苔菜尖洗净，用油煸炒后，掺汤煮炬时，加盐和味精、葱花即可。」
- 尚未确认的问题:
  - [unclear-glyph（字形无法稳定判定）] 原料栏：味精 [印墨磨损数量]
  - 原料「味精 五分」置信度未达high（{'recognition': 'medium', 'conversion': 'high'}）：印刷墨迹磨损，字形按“五分”读出（与本页“盐 五钱”笔画结构比对一致），五分 × 0.5g = 2.5g
  - 旧词/方言用语「煮炬」confidence=medium（“炬”字形可辨；该时代火候用语，语义未作现代化改写，与b06/b07/b09/b10已记录“炬”字用法一致）

### dz1979-p225 「熏豆筋」 — dz1979-b11

- 页码: PDF 238 / 书内 225
- 是否需重新查看扫描页: 是
- 复核原因:
  - projectMatch.reviewRequired=true（项目匹配待人工确认）
  - contentIncomplete=true（正文在扫描件中中途截断/缺失部分栏目）
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
- 当前可确认事实:
  - 标题经视觉核对为「熏豆筋」，与目录一致（confidence=high）
  - 原料栏已记录 10 项
  - 已确认读法：做法第2步（本条目正文在本扫描件中的最后一句完整可见） — 「用中火烧至汤干亮油时，加味精香油合匀，起锅装盘。」
- 尚未确认的问题:
  - [page-boundary（页边界/印刷缺失）] 特点栏及以后：PDF第238页正文在做法第2步末句“……用中火烧至汤干亮油时，加味精香油合匀，起锅装盘。”后结束，页面底部大片空白，未见“三 特点”标题及正文，也未见书内页码footer；其后PDF第239页为下一条目“蛋酥花仁”的起始页，无本条目连续正文
  - projectMatch classification=book-only，尚无匹配项目，待人工确认（book-only 或需补建）

## Medium (13)

### dz1979-p071 「夹沙肉」 — dz1979-b03

- 页码: PDF 84-85 / 书内 71-72
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
- 当前可确认事实:
  - 标题经视觉核对为「夹沙肉」，与目录一致（confidence=high）
  - 原料栏已记录 7 项
  - 特点栏文字已保留
  - 已确认读法：做法 — 「保肋」
  - 已确认读法：做法 — 「干沙」
  - 已确认读法：做法 — 「刀子形（篦）」
  - projectMatch=exact-name，已匹配「夹沙肉」
- 尚未确认的问题:
  - [old-term（旧词/方言用语，字形已确认但词义未证实或未现代化改写）] 原料栏：干沙

### dz1979-p090 「腊肉烧菜头」 — dz1979-b04

- 页码: PDF 103 / 书内 90
- 是否需重新查看扫描页: 是
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - dialectOrOldTerms中至少一项confidence未达high或缺失confidence字段
- 当前可确认事实:
  - 标题经视觉核对为「腊肉烧菜头」，与目录一致（confidence=high）
  - 原料栏已记录 8 项
  - 特点栏文字已保留
- 尚未确认的问题:
  - [page-boundary（页边界/印刷缺失）] 做法第1步：切成长一寸八、宽一寸、厚二
  - 旧词/方言用语「一寸八、宽一寸」confidence=medium（原文末端被页面截断）

### dz1979-p091 「豌豆焖肉」 — dz1979-b04

- 页码: PDF 104-105 / 书内 91-92
- 是否需重新查看扫描页: 是
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - dialectOrOldTerms中至少一项confidence未达high或缺失confidence字段
- 当前可确认事实:
  - 标题经视觉核对为「豌豆焖肉」，与目录一致（confidence=high）
  - 原料栏已记录 14 项
  - 特点栏文字已保留
- 尚未确认的问题:
  - [unclear-glyph（字形无法稳定判定）] 附注俗称：洗手橙
  - 旧词/方言用语「洗手橙」confidence=medium（附注中的俗称字形需复核）

### dz1979-p097 「明笋焖肉片」 — dz1979-b04

- 页码: PDF 110 / 书内 97
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
- 当前可确认事实:
  - 标题经视觉核对为「明笋焖肉片」，与目录一致（confidence=high）
  - 原料栏已记录 7 项
  - 特点栏文字已保留
  - projectMatch=exact-name，已匹配「明笋焖肉片」
- 尚未确认的问题:
  - [old-term（旧词/方言用语，字形已确认但词义未证实或未现代化改写）] 附注：明笋若不切片，可用手撕每根撕成两半

### dz1979-p132 「青笋烧兔」 — dz1979-b06

- 页码: PDF 145-147 / 书内 132-134
- 是否需重新查看扫描页: 是
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
- 当前可确认事实:
  - 标题经视觉核对为「青笋烧兔」，与目录一致（confidence=high）
  - 原料栏已记录 10 项
  - 特点栏文字已保留
  - 已确认读法：做法第2步 — 「煸至油呈红色时下酱油、盐、葱姜及鲜汤一起烧」
  - 已确认读法：做法第2步 — 「待兔肉烧炬即下味精、水豆粉，收浓汁起锅即成」
- 尚未确认的问题:
  - [page-boundary（页边界/印刷缺失）] source range：PDF第146-147页为下一分类"禽蛋鱼类"的分隔页（图案页）与空白背页，不含本条目正文

### dz1979-p139 「辣子鸡丁」 — dz1979-b07

- 页码: PDF 152-153 / 书内 139-140
- 是否需重新查看扫描页: 是
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
- 当前可确认事实:
  - 标题经视觉核对为「辣子鸡丁」，与目录一致（confidence=high）
  - 原料栏已记录 12 项
  - 特点栏文字已保留
  - 已确认读法：做法第1步 — 「用刀后尖戳十余下（皮向下）」
  - 已确认读法：做法（原印刷编号3.） — 「见油出红色时」
  - projectMatch=exact-name，已匹配「辣子鸡丁」
- 尚未确认的问题:
  - [page-boundary（页边界/印刷缺失）] 做法编号2.：印刷页面仅见做法编号“1.”与“3.”，编号“2.”及其正文未印出；PDF第152页与153页之间无空白页，正文由152页第1步直接接续至153页编号3.

### dz1979-p154 「酸辣蛋花汤」 — dz1979-b08

- 页码: PDF 167 / 书内 154
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - dialectOrOldTerms中至少一项confidence未达high或缺失confidence字段
- 当前可确认事实:
  - 标题经视觉核对为「酸辣蛋花汤」，与目录一致（confidence=high）
  - 原料栏已记录 9 项
  - 特点栏文字已保留
  - 已确认读法：做法第2步 — 「用水豆粉勾成清二流芡」
  - 已确认读法：附注 — 「葱花、醋、味精先放于碗内亦可」
- 尚未确认的问题:
  - 旧词/方言用语「清二流芡」confidence=medium（）

### dz1979-p184 「麻辣明笋丝」 — dz1979-b09

- 页码: PDF 197 / 书内 184
- 是否需重新查看扫描页: 是
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - dialectOrOldTerms中至少一项confidence未达high或缺失confidence字段
- 当前可确认事实:
  - 标题经视觉核对为「麻辣明笋丝」，与目录一致（confidence=high）
  - 原料栏已记录 8 项
  - 特点栏文字已保留
  - 已确认读法：做法第2步（字形确认为“余”，语义存疑，已在uncertainties记录） — 「在开水锅中余两次」
- 尚未确认的问题:
  - [unclear-glyph（字形无法稳定判定）] 做法第2步：在开水锅中余两次
  - 旧词/方言用语「余两次」confidence=medium（字形按“余”确认；语义是否等同于“煮/焯”未得到来源独立佐证，不作解释）

### dz1979-p189 「醋渍胡豆」 — dz1979-b09

- 页码: PDF 202-203 / 书内 189-190
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - dialectOrOldTerms中至少一项confidence未达high或缺失confidence字段
- 当前可确认事实:
  - 标题经视觉核对为「醋渍胡豆」，与目录一致（confidence=high）
  - 原料栏已记录 11 项
  - 特点栏文字已保留
  - 已确认读法：做法第2步：原料栏“生菜油”合计一两，做法第2步先用五钱调入调料碗，第3步注明“余下的生菜油”用于最后浇淋，两处均逐字保留，不合并为单一数量 — 「生菜油（五钱）」
- 尚未确认的问题:
  - 旧词/方言用语「泡红辣椒切“鱼眼睛”」confidence=None（指将泡红辣椒切成鱼眼睛大小的碎粒，保留原书比喻用语）

### dz1979-p191 「炒野鸡红」 — dz1979-b09

- 页码: PDF 204-205 / 书内 191-192
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - dialectOrOldTerms中至少一项confidence未达high或缺失confidence字段
- 当前可确认事实:
  - 标题经视觉核对为「炒野鸡红」，与目录一致（confidence=high）
  - 原料栏已记录 11 项
  - 特点栏文字已保留
  - 已确认读法：特点栏后附注 — 「附注：如用牛肉丝烹制，味道更觉鲜美。」
- 尚未确认的问题:
  - 旧词/方言用语「二粗丝」confidence=None（肉丝、萝卜丝的粗细分级用语，与b07/b08已记录术语一致，保留原书表达，不扩写精确定义）

### dz1979-p194 「家常芋头」 — dz1979-b09

- 页码: PDF 207 / 书内 194
- 是否需重新查看扫描页: 是
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - dialectOrOldTerms中至少一项confidence未达high或缺失confidence字段
- 当前可确认事实:
  - 标题经视觉核对为「家常芋头」，与目录一致（confidence=high）
  - 原料栏已记录 9 项
  - 特点栏文字已保留
- 尚未确认的问题:
  - [unclear-glyph（字形无法稳定判定）] 做法第2步：烧至芋头炬时
  - 旧词/方言用语「烧至芋头炬时」confidence=medium（“炬”字形可辨，但语义是否等同“耙/糯”未得到来源独立佐证，不作解释）

### dz1979-p197 「家常四季豆」 — dz1979-b10

- 页码: PDF 210 / 书内 197
- 是否需重新查看扫描页: 是
- 复核原因:
  - uncertainties非空（含未解决的字形/数量/归属/页边界问题）
  - dialectOrOldTerms中至少一项confidence未达high或缺失confidence字段
- 当前可确认事实:
  - 标题经视觉核对为「家常四季豆」，与目录一致（confidence=high）
  - 原料栏已记录 8 项
  - 特点栏文字已保留
- 尚未确认的问题:
  - [unclear-glyph（字形无法稳定判定）] 做法第2步：焖至豆炬
  - 旧词/方言用语「焖至豆炬」confidence=medium（“炬”字形清晰可辨，但在此语境下的确切含义（是否为“耙/糯”一类软烂状态的方言用字）未在本页得到独立佐证，与b06/b07/b09已记录“炬”字用法一致；不作语义推断）

### dz1979-p215 「拌辣菜」 — dz1979-b11

- 页码: PDF 228 / 书内 215
- 是否需重新查看扫描页: 否（可在crosswalk阶段处理）
- 复核原因:
  - dialectOrOldTerms中至少一项confidence未达high或缺失confidence字段
- 当前可确认事实:
  - 标题经视觉核对为「拌辣菜」，与目录一致（confidence=high）
  - 原料栏已记录 7 项
  - 特点栏文字已保留
  - 已确认读法：特点栏 — 「此菜为我省民间小菜，味麻辣冲鼻，故又名“冲菜”。」
  - 已确认读法：特点栏后附注 — 「此为大份量，家庭吃时可根据情况面定。吃多少拌多少，下者一定要依盐严，调料量也要酌情面用。」
- 尚未确认的问题:
  - 旧词/方言用语「情况面定」confidence=medium（字形清晰可辨为“面”；该字在“可根据情况面定”“调料量也要酌情面用”两处的确切语法功能（是否等同于“而”类连接用法）未在本页得到独立佐证，不作语义推断，逐字保留原文）

