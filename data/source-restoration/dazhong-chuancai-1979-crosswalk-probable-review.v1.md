# 大众川菜 1979 —— Probable Candidate 复核报告

生成时间: 2026-08-07

基线: main/origin/main=a99eef6, applicationReady=False

本轮仅复核 crosswalk 中 5 个 probable-match-needs-review 候选。只记录判断，不写回 canonical source、name-matches、crosswalk、Curated/Full/HOC，不修改 applicationReady，不开始 promotion。不读取 PDF，不调用视觉模型，不重新审 147 道。

## 结论汇总

- confirmed-alias: **2**（热味姜汁鸡、麻辣豆腐）
- remain-probable: **1**（干煸鳝鱼丝）
- reject-candidate: **2**（豆腐鱼、烧拌莴笋）

## 1. dz1979-p141 热味姜汁鸡 → 热窝姜汁鸡（full ex--832d7c5d）

**结论: confirmed-alias（high）**

一致证据：
- 调味结构一致：盐、酱油、醋、汤/二汤的姜醋味型，是这道菜的身份核心。
- 步骤顺序逐项一致：菜油七成热 → 下鸡块+姜米+葱花煸炒 → 加盐酱油汤焖烧 → 水豆粉收浓滋汁 → 临起锅下醋。
- 项目版起锅放净辣椒油，对应原书附注中的辣椒油变法。

差异（版本级，可解释）：熟公鸡肉 vs 肥嫩母鸡；八分见方块 vs 一寸四长五分宽条块；焖烧五分钟 vs 八分钟；辣椒油原书为附注可选、项目版固定。正文结构足以证明同一道菜，「热味/热窝」为同一姜汁鸡菜名的历史写法差异，非字形猜测。

## 2. dz1979-p168 豆腐鱼 → 豆腐鲫鱼（curated+full ex--8aec747f）

**结论: reject-candidate（high）**

冲突证据：
- 核心调味结构冲突：原书豆瓣+甜酱+醪糟汁+酱油（厚味红味）；项目姜蒜+盐（清汤白味），无豆瓣/甜酱/醪糟。
- 关键步骤冲突：原书合烧后收芡、豆腐连汁挂于鱼上；项目大火滚出奶白鱼汤再小火炖（汤菜）。
- 成品冲突：原书「色泽金红、味厚」vs 项目「汤色乳白」。
- 原书鱼种未指定（鲜鱼），项目指定鲫鱼。

候选应清空，条目回到 book-only。项目鲫鱼菜仅凉粉鲫鱼、干烧鲫鱼、豆腐鲫鱼，均非豆瓣豆腐红烧形态。

## 3. dz1979-p173 干煸鳝鱼丝 → 干煸鳝鱼（curated+full ex--efa871b1）

**结论: remain-probable（medium）**

一致证据：主料同为鳝鱼，干煸技法一致（煸至水汽收干/吐油、干香），共有豆瓣与姜蒜，芹菜均出现。

阻止确认的差异：
- 刀工/成品形态：原书切「丝」（一寸半长二分宽），项目明确切「段」。
- 调味细节：原书醪糟汁+醋+花椒面（起锅撒面），干辣椒/花椒不入锅；项目料酒+干辣椒+花椒入锅，无醋与撒面花椒面。

维持 probable，reviewRequired=true，不升级绑定。

## 4. dz1979-p177 麻辣豆腐 → 麻婆豆腐（curated fam-mapo-tofu）

**结论: confirmed-alias（high）**

一致证据（对照 Curated 正文与 recipe-methods.js 经典正文）：
- 主料组合一致：豆腐+肉末+豆瓣+辣椒面+花椒面+豆豉+蒜苗+水豆粉/水淀粉。
- 调味结构一致：豆瓣炒红油+辣椒面+豆豉+花椒面的麻辣组合。
- 步骤顺序一致：豆腐焯水 → 肉末炒干/酥 → 豆瓣辣椒面炒红油 → 掺汤下豆腐烧 → 勾芡 → 撒花椒面。
- 成品一致：麻辣烫鲜。

差异为家常变体级：猪肉 vs 牛肉末；勾芡一次 vs 两次；糖与姜蒜的有无。正文证据足以确认「麻辣豆腐」即 1979 年版麻婆豆腐。

## 5. dz1979-p206 烧拌莴笋 → 烧拌鲜笋（curated+full ex--57fd9bbb）

**结论: reject-candidate（high）**

冲突证据：
- 主料身份冲突：莴笋（茎用莴苣）≠ 鲜笋（竹笋），不是默认同义食材。
- 烹调方法冲突：原书灰火包裹烧熟 vs 项目焯水/水煮。
- 调味结构冲突：原书糊辣干辣椒+香油 vs 项目蒜泥+醋+花椒面+热油激香。

候选应清空，条目回到 book-only；项目库无任何「莴笋」菜谱。

## 验证

- 5 项覆盖当前全部 probable 条目，无遗漏、无重复
- confirmed-alias 2 项均 confidence=high
- remain-probable / reject 未产生 confirmed projectIds
- JSON parse、node --check 通过
- source-restoration 相关测试通过
- 未修改 crosswalk dry-run 原文件、name-matches、canonical source、Curated/Full/HOC、applicationReady
