# 大众川菜 1979 —— Crosswalk Dry-run 审计报告

生成时间: 2026-08-07

基线: main/origin/main=f88bbfa, applicationReady=False

本报告仅审计 147 个 source-restoration entryId 与项目当前 Curated/Full 真实菜谱 ID 之间的映射关系，不做 production promotion。不修改 canonical 147 道 worker/chunk/assembled、name-matches、R1/R2 overlay、review queue、apply-review audit、Curated/Full/HOC/UI/cache。

## 汇总

- 总条目: **147**（147/147 覆盖，无重复）
- exact-name: **74**
- confirmed-alias: **7**
- probable-match-needs-review: **1**
- book-only: **65**
- confirmed 映射总数: **81**
- consistency problems: **0**
- collision: **0**　many-to-one: **0**（无多个 source entry 绑定同一 project recipe 的情形）

本轮已按 crosswalk-probable-review 的正文复核结论写回 canonical projectMatch（4 道），并重新生成本 crosswalk。name-matches 保持历史 name-only baseline 不变。

## 判定规则

- exact-name: 书名与项目菜名规范化后实质完全一致，绑定真实 project ID。
- confirmed-alias: 名称不同但仓库既有证据足以确认同菜别名/历史名，记录 alias 依据与真实 project ID。
- probable-match-needs-review: 有合理候选但无法无歧义证明，candidate 单独记录，不入 confirmed projectIds，reviewRequired=true。
- book-only: 当前项目找不到可靠对应，不强行配对。

证据优先级：名称/name-matches 明确证据 > 主料与菜型 > 核心调味结构 > 做法/关键工艺 > 特点描述。名称相似但主料或核心做法冲突时不得确认映射。

## Confirmed-alias（7，其中 2 道来自正文复核）

| entryId | 书名 | 项目菜名 | 依据 |
| --- | --- | --- | --- |
| dz1979-p079 | 锅粑肉片 | 锅巴肉片 | “粑/巴”为该菜名明确字形/写法差异，其余文字完全一致 |
| dz1979-p145 | 蘑芋烧鸭 | 魔芋烧鸭 | “蘑芋/魔芋”指向同一食材，烹调法与主料一致 |
| dz1979-p199 | 干煸四季豆 | 干煸豆角 | “四季豆/豆角”为明确同义食材称呼，烹调法一致 |
| dz1979-p208 | 炒土豆丝 | 土豆丝 | 项目名仅省略烹调动词“炒”，核心菜名唯一 |
| dz1979-p210 | 青椒拌皮蛋 | 青椒皮蛋 | 项目名仅省略“拌”，原料组合完整一致 |

## 正文复核已确认（probable → 新分类，依据 crosswalk-probable-review）

| entryId | 书名 | 新分类 | 绑定 | 依据 |
| --- | --- | --- | --- | --- |
| dz1979-p141 | 热味姜汁鸡 | confirmed-alias | full: ex--832d7c5d | 正文证据确认同菜异名（decision=confirmed-alias，confidence=high） |
| dz1979-p168 | 豆腐鱼 | book-only | 无 | 候选正文为奶白汤炖制，与原书豆瓣红味收汁实质冲突（decision=reject-candidate，confidence=high） |
| dz1979-p177 | 麻辣豆腐 | confirmed-alias | curated: fam-mapo-tofu | 正文证据确认同菜异名（decision=confirmed-alias，confidence=high） |
| dz1979-p206 | 烧拌莴笋 | book-only | 无 | 莴笋≠鲜笋，主料身份冲突（decision=reject-candidate，confidence=high） |

## Probable-match-needs-review（1，reviewRequired=true）

| entryId | 书名 | candidate | candidate projectIds | 依据 |
| --- | --- | --- | --- | --- |
| dz1979-p173 | 干煸鳝鱼丝 | 干煸鳝鱼 | curated+full: ex--efa871b1 | 项目名省略形态词“丝”，需正文刀工与成品确认 |

该候选仍只记录于 candidateProjectIds，未进入 confirmed projectIds。

## Book-only（65）

当前 Curated/Full 库中找不到可靠对应，未强行配对。其中含 B 类 12 道中的 9 道（见下）、R1/R2 confirmed-unresolved 的「麻辣兔丁」「水煮牛肉」等未匹配条目，以及本轮经正文复核剔除候选的「豆腐鱼」「烧拌莴笋」。

## Source quality（独立维度，与映射分类无关）

- ready-for-later-promotion-review: **90**
- needs-source-review: **45**
- alternate-source-required: **12**

映射成功不等于可以 promotion；例如「水煮牛肉」映射为 exact-name 但 sourceQuality=needs-source-review（R2 confirmed-unresolved）。

sourceQuality 只评价来源数据保真度，不因 crosswalk 未确认而降低：
- contentMissing / contentIncomplete
- uncertainties 非空
- ingredient 或整体 recognition/conversion 低于 high
- 旧词 modernSummary 仍为 null 或相关 confidence 未达 high
- R1/R2 confirmed-unresolved

projectMatch.reviewRequired、probable-match-needs-review、candidateProjectName、name-match 未确认均不构成 source-quality 原因；映射风险由 crosswalk 的 reviewRequired 单独表达。本轮 4 道 classification 变化（2 道 probable→confirmed-alias、2 道 probable→book-only）不影响 sourceQuality：上述条目来源层均无保真问题，sourceQuality 保持 ready，三类总数仍为 90/45/12。

### 相对上一版（88/47/12）的变化（8 道）

| entryId | 书名 | 变化 | 原因 |
| --- | --- | --- | --- |
| dz1979-p141 | 热味姜汁鸡 | needs → ready | 原仅因 projectMatch.reviewRequired 入 needs；来源层无保真问题 |
| dz1979-p168 | 豆腐鱼 | needs → ready | 同上（probable，来源层无保真问题） |
| dz1979-p173 | 干煸鳝鱼丝 | needs → ready | 同上（probable，来源层无保真问题） |
| dz1979-p177 | 麻辣豆腐 | needs → ready | 同上（probable，来源层无保真问题） |
| dz1979-p206 | 烧拌莴笋 | needs → ready | 同上（probable，来源层无保真问题） |
| dz1979-p070 | 清蒸肘子 | ready → needs | methodSummary.dialectOrOldTerms[0].modernSummary=null（“头粗丝”旧词未解） |
| dz1979-p074 | 粉蒸肉 | ready → needs | methodSummary.dialectOrOldTerms[0].modernSummary=null（“保肋”旧词未解） |
| dz1979-p076 | 荷叶蒸肉 | ready → needs | methodSummary.dialectOrOldTerms[0].modernSummary=null（“保肋”旧词未解） |

其余 139 道 sourceQuality 不变；本轮仅按正文复核调整 4 道 classification 与绑定（见「正文复核已确认」节），其余 143 道 project/candidate 绑定不变。

### Alternate-source-required（12，来自 apply-review-resolutions audit 的 unchangedByDesign.alternateSourceRequired）

dz1979-p090 腊肉烧菜头、dz1979-p100 豆芽肉饼汤、dz1979-p122 蒜烧肚条、dz1979-p138 红油鸡块、dz1979-p139 辣子鸡丁、dz1979-p142 香菌烧鸡、dz1979-p145 蘑芋烧鸭、dz1979-p152 番茄炒蛋、dz1979-p155 芹黄炒什件、dz1979-p171 大蒜烧鳝鱼、dz1979-p181 鱼香油菜苔、dz1979-p225 熏豆筋

## Collision / many-to-one

机械检查后无任何多个 source entry 绑定同一 project recipe 的情形，collision=0、many-to-one=0，无需人工解决。

## 验证

- 147/147 entryId 覆盖且无重复：通过
- 四种 classification 总数=147：通过
- 所有 confirmed project ID 在 Curated/Full 库中真实存在：通过（全量核对，非抽样）
- probable 候选不进入 confirmed projectIds：通过
- B 类 12 道全部 sourceQuality=alternate-source-required：通过
- catalog/bookName 三源（catalog、recipes、name-matches、crosswalk）一致：通过
- crosswalk 与 canonical recipes projectMatch 一致：通过
- canonical 与 name-matches 的 4 个 classification 差异全部由 crosswalk-probable-review 解释（2×confirmed-alias/high、2×reject-candidate/high），无其他未解释 drift：通过
- `node --test test/dazhong-source-restoration-crosswalk-dry-run.test.mjs`：20/20 通过
- JSON parse：通过
- sourceQualityReasons：147 项齐备；needs/alternate 均含具体来源字段依据；ready 均为空数组；无任何引用 projectMatch/reviewRequired/candidate/name-match 的理由

生成方式：`node scripts/build-dazhong-chuancai-crosswalk-dry-run.mjs`。generator 本身只读 canonical 且不调用 assembler；source-restoration 测试可能触发 assembler 测试副作用，若 canonical recipes 的 updatedAt 因此变化必须恢复。
