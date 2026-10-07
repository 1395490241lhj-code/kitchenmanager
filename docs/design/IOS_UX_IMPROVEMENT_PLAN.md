# iOS UI/UX 改进方案（基于 2026-10-07 审计）

状态：阶段 A 已由 owner 批准并实现，已在 GitHub Actions 的 iOS 模拟器上编译并跑测试（见文末「验证记录」）；视觉走查尚未做。阶段 B、C 仍为提案。 本文不改变任何已接受的 Decision、设计语言或硬边界；凡涉及这些的条目都明确标为「需新 Decision」。

## 0. 依据与限制

- 依据：对 `ios-native/Kitchen Manager/KitchenManager/**` 的静态代码审计（commit `c772a36`），对照 `docs/design/KITCHEN_DESIGN_LANGUAGE.md` 与 `docs/design/UI_TASTE.md`。
- 审计时 Obsidian 规范库不可用（降级模式）；实施前须先用 `km-project-memory` 核对 `UI Design System.md`、`Product & IA.md` 与相关 Decisions。
- 审计未运行 Xcode，也没有渲染截图。所有"现状"描述来自代码，实施前每项都要在模拟器里复现确认。
- 范围仅限 iOS 原生端；PWA 不在本方案内。

## 1. 总体策略

问题分三层，按「风险从低到高、收益从直接到结构」排序实施：

| 阶段 | 内容 | 是否触碰已接受决策 | 预估规模 |
|---|---|---|---|
| A | 补齐四条断掉的高频操作路径 | 否（均在现有 IA 内） | 4 个独立小 PR |
| B | 视觉 token 与按钮体系收敛 + 文档纠偏 | 否（不改视觉结果，只收敛实现） | 2–3 个 PR |
| C | 信息架构调整 | **是，需新 Decision** | 先写提案，批准后再拆 |

每个 PR 只做一件事，单独验证、单独可回滚。阶段 A 内部各项互不依赖，可并行。

---

## 阶段 A：补齐高频操作路径

### A1. 买菜清单：单项编辑 / 删除 / 快速添加

**现状**
- 行只有点按勾选（`MainFeatureViews.swift:898`）；`KitchenStore.deleteShopping(_:)`（`KitchenStore.swift:2703`）在 UI 中无调用方。
- 添加需要 5 字段 Form，保存即关闭（`MainFeatureViews.swift:1500-1567`），「来源」把内部字段暴露给用户。
- 勾选无触感反馈。

**目标行为**
1. 待买行与已买行都支持尾部滑动「删除」（删除后底部出现「已删除 · 撤销」提示条。现有 `AppFeedbackView` 只有文字和样式，需要扩展出撤销按钮，并抽成食材、买菜两页共用的组件），以及 `contextMenu`「编辑」「删除」。
2. 「编辑」复用添加表单（改为 `AddOrEditShoppingItemView(mode:)`），只改名称 / 数量 / 单位 / 备注。
3. 添加表单：移除「来源」Picker（手动添加固定为 `手动添加`）；新增「添加并继续」——保存后清空并保持名称聚焦，不关闭 sheet。
4. 勾选加 `.sensoryFeedback(.selection, trigger:)`；状态切换用 `KitchenMotion.quick`，Reduce Motion 下为 nil。

**改动范围**：`MainFeatureViews.swift`（ShoppingView、AddShoppingItemView）、`KitchenStore.swift`（新增 `updateShopping(id:name:quantity:unit:remark:)`，与 `addShopping` 同一校验）。

**不做**：不改分类、排序、合并、生成、入库语义；不引入自然语言解析（「葱 2根」解析留作后续，需单独评估误解析风险）。

**验收**
- 单元测试：`updateShopping` 校验（空名、非正数量被拒）、删除后撤销恢复原位置与字段。
- UI 测试（扩展 `ShoppingExperienceUITests`）：滑动删除 → 撤销；编辑数量后行文本更新；「添加并继续」连续添加 3 项。
- 视觉：Light/Dark、AX XXXL、小屏 Light；最后一行仍可滚到浮动 tab bar 上方。

### A2. 「缺什么」可见并可一键补进清单

**现状**
- 菜谱列表显示「缺 N 样」（`RecipeViews.swift:283-293`），详情页食材行不标库存状态。
- 首页 hero 显示「N/M 食材已在库」（`HomeMealHero.swift`），不能看到缺哪些，也不能直接补。

**目标行为**
1. 把 `missingCoreIngredientCount` 的匹配逻辑提取为共享纯函数，例如 `RecipeStockMatch.missing(in:inventory:) -> [String]`，列表、详情、首页共用同一结果（消除两处各自匹配可能产生的不一致）。
2. 菜谱详情的食材区：缺货行在数量旁显示次级文字「缺」（文字，不用颜色单独表达），区块标题右侧显示「缺 2 样 · 加入清单」文字按钮，调用现有的生成购物清单流程（`isShowingShoppingGeneration`），只预选缺货项。
3. 首页 hero 的就绪行在 `ready < total` 时可点，弹出 sheet 列出缺货食材 +「加入买菜清单」主操作；文案仍为"在库"，不声称数量充足（遵守 presence-only 约束）。

**改动范围**：新文件 `RecipeStockMatch.swift`；`RecipeViews.swift`；`HomeMealHero.swift` / `HomeView.swift`（新增 sheet case）；`HomeMealReadinessProjection.swift` 改为复用共享匹配。

**不做**：不做数量充足性判断（D 级延期项）；不改 hero 层级与 D-048 推荐结构。

**验收**
- 单元测试：共享匹配函数与原 `HomeMealReadinessProjection` 结果对齐（迁移前后同一 fixture 输出一致）。
- UI 测试：缺 2 样的菜谱 → 详情显示 2 个「缺」→ 加入清单 → 买菜清单出现这 2 项且无重复。
- VoiceOver：缺货行朗读「…，缺货」；hero 就绪行有按钮 trait 与提示。

### A3. 食材列表快捷「用掉」与可撤销删除

**现状**：行只有尾部滑动「删除」+「无法撤销」确认框（`MainFeatureViews.swift:245,472-484`）；用掉食材必须进详情。

**目标行为**
1. 前置滑动「用完」：调用现有 `KitchenStore.applyConsumption`（已支持冲突安全撤销，见 `79e55c6`），记录为一次全量消耗，底部提示「已用完 · 撤销」。
2. 删除改为直接执行 + 撤销提示，移除确认 alert（删除仍为破坏性角色）。若撤销需要的快照机制在 store 中不存在，则本条保留 alert，只做第 1 点——实施前先确认。
3. 常备食材行行为不变（常备的数量语义不同，不加「用完」）。

**改动范围**：`MainFeatureViews.swift`（InventoryView）、必要时 `KitchenStore.swift` 增加 `restoreInventory(_:)`。

**验收**：单元测试覆盖用完 → 撤销后库存与消耗记录均恢复；UI 测试滑动用完 / 撤销；同步相关 flag 保持默认关闭，不触碰 sync mutation 语义（若 `deleteInventory` 会入队 sync mutation，撤销路径必须走同一 store API，不能绕开）。

### A4. Cooking Mode 节奏

**现状**（`RecipeCookingModeView.swift`）
- 「下一步」不标记完成，进度可能长期为 0/N（39-50, 256 行）。
- 不能滑动切步；看不到下一步；当前步骤用料需开 sheet。
- 步骤建议时长藏在「开始计时」菜单里；`onDisappear` 取消计时器（89 行），「保留进度」退出也会丢计时。

**目标行为**
1. 「下一步」= 标记当前步完成 + 前进；保留独立的「标记完成」切换仅用于撤销误标（降为 utility 文字按钮）。
2. 当前步骤卡下方显示一行次级「下一步：…」预览（单行截断，AX 尺寸下完整换行）。
3. 步骤区支持水平滑动切换（`TabView(.page)` 或拖拽手势），Reduce Motion 下无过渡动画；按钮路径保持不变。
4. `RecipeStepTimerSuggestion` 命中时，在计时面板直接显示一键按钮「计时 N 分钟」，菜单保留为「其他时长」。
5. 「保留进度」退出时不取消已在运行的计时器（计时器状态已依赖本地通知调度，确认 `CookingTimerController` 在视图外存活的归属后再改；若需要把控制器提升到 session，则本条单独成 PR）。

**不做**：多计时器、Live Activity（需要新 target / entitlement，属硬边界，另行提案）。

**验收**：扩展 `RecipeCookingModeUITests`：连续「下一步」后进度为 N/N；滑动切步；建议时长一键启动；保留进度退出再进入，计时仍在。

---

## 阶段 B：视觉体系收敛

目标：**渲染结果不变**，只消除重复与漂移，让后续调整只改一处。

### B1. Token 收敛（纯重构）
- 以 `KitchenTheme` 为唯一视觉 token 入口；`AppTheme` 保留外观偏好、`adaptive` 工具和库存生命周期域 token。
- 为所有重名不同值的 token 建立映射表（主文字、次文字、分隔线、surface、圆角 10/12），逐个确认实际渲染采用哪个，再替换调用方。**值不同的地方必须先截图对比再决定，不能默认取一方。**
- 语义别名：新增 `KitchenTheme.accent`（= 现 `cookingGreen` 值）、`accentFill`；`cookingGreen` / `sage` / `managementBlue` 标 `@available(*, deprecated)` 并迁移调用方。这是设计语言文档已记录的命名债，按其要求用别名 + 废弃方式处理。
- 19 处硬编码 `.red` / `.orange` 改为 `AppTheme.danger` / `warningInk`。

**验收**：现有 `ProductionDesignLanguageUITests`、`HomeVisualGateUITests`、`RecipeVisualMatrixUITests` 全部通过；关键页 Light/Dark 截图前后逐像素或目视对比无差异。

### B2. 主按钮统一
- 21 处 `.borderedProminent` + `managementActionFill` 与 10 处 `KitchenButtonStyle(.primary)` 并存。逐处归类：表单/系统流程中的确认按钮保留原生；页面级单一主操作统一为 `KitchenButtonStyle(.primary)`。
- 先出一份清单（文件:行 → 归类 → 理由）给 owner 确认，再改。此项会改变部分页面观感，需走 `UI_TASTE.md` 的 Taste Pass 与对比法。

### B3. 文档纠偏
- 修正 `KITCHEN_DESIGN_LANGUAGE.md` v1 段落中与代码不符且仍被当作规格引用的数值（canvas 色值、`featureRadius`、forest/sage/indigo 描述），或在表格处明确标注「以 `KitchenTheme.swift` 为准」。
- 修正 `AppTheme.swift:37-46` 关于 brand=绿色的过时注释。
- 必须同步回写 Obsidian `UI Design System.md`（`km-delivery`）。

---

## 阶段 C：信息架构（需新 Decision，先提案）

以下各条都会改动已接受的 IA（四 tab 结构、Planner 作为一级 tab、D-048 首页推荐），按 `AGENTS.md` §3 只能通过新的 Decision 变更。本阶段交付物是 **Decision 草案 + 原型对比截图**，不是代码。

| # | 问题 | 候选方案 | 需要 owner 决定 |
|---|---|---|---|
| C1 | 买菜清单在「食材」下两级，超市场景路径长 | a) 升级为第 5 个 tab；b) 「食材」tab 顶部改为「库存 / 买菜」分段；c) 全局可呼出的买菜 sheet | 选哪种；是否接受 5 tab |
| C2 | 跨 tab 跳转清空目标 tab 栈、返回不到原处（`KitchenStore.swift:102-110`） | 首页 / AI 等入口改为以 sheet 呈现买菜和菜谱详情，tab 栈不被覆盖 | 是否接受「从首页打开的是 sheet 而非 push」 |
| C3 | 菜谱库是 Planner 中的一行，AX 尺寸下沉底 | a) 菜谱库作为 tab；b) Planner 顶部常驻入口（AX 下也不沉底） | 菜谱库是否是一级目的地 |
| C4 | 术语不统一（买菜清单/购物清单、特殊计划/聚餐、常备食材/常备货架、计划/用餐计划） | 出术语表，一个概念一个词 | 每个概念保留哪个词 |
| C5 | Planner 切周靠菜单、「+」菜单嵌套 3 层 | 周范围行改为可点的左右箭头 + 水平滑动切周；「+」菜单拍平 | 是否接受拍平后菜单变长 |
| C6 | 无新手引导；空库存时首页显示「今天没有需要处理的食材」 | 空库存时替换为一行引导「先添加几样食材」→ 添加 / 扫小票 | 引导形式（单行 vs 首次启动流程） |
| C7 | 首页「加入今天」后卡片消失、页面整体切换模式 | 保留卡片原位并显示「已加入」，下一次进入首页时再切换；或提示条带撤销 | 是否调整 D-048 的模式切换时机 |

C4 与 C6 风险低、可最早决策；C1–C3 互相关联，建议一起出一份导航 Decision。

---

## 2. 通用验证要求（每个 PR）

- 走 `km-acceptance` 定义边界，`km-ios-validation` 取得 Xcode 证据（MCP 或 `xcodebuild` 回退，如实注明）。
- 视觉相关：Light / Dark × 普通 / AX XXXL，外加小屏 Light；底部最后一项可滚到浮动 tab bar 上方。
- 交互相关：VoiceOver 标签与 trait、44pt 目标、Reduce Motion。
- 不改 SwiftData 模型 / 迁移、sync / merge / smoke flag、Keychain、entitlement。若某项实施中发现必须改，停下并上报。
- 已知基线红（`ReceiptCompactListUITests.swift:127`）不得被描述为新回归或修复。

## 3. 建议顺序

1. A1、A2（收益最高、风险最低，可并行）
2. A4、A3（A3 依赖撤销机制确认）
3. B1 → B3 → B2
4. 并行推进 C4、C6 的 Decision；随后 C1–C3 导航 Decision

## 4. 开工前需要 owner 确认

1. 阶段 A 是否可以直接开始（不涉及 Decision）。
2. A3：是否接受用撤销代替删除确认框。
3. B2：主按钮统一的归类原则。
4. 阶段 C 先出哪几条 Decision 草案。

---

## 阶段 A 实施记录（2026-10-07）

代码在没有本地 Xcode 的环境中编写，随后通过 `.github/workflows/ios-tests.yml` 在 GitHub Actions 的 macOS 机器上验证（见下方「验证记录」）。

| 项 | 已实现 | 与方案的偏差 |
|---|---|---|
| A1 | 行尾滑动 / 长按菜单「编辑」「删除」；删除即时生效 + 撤销提示（复用现有 `FeedbackToast`）；添加表单可编辑、去掉「来源」、新增「添加并继续」；勾选触感 | 无 |
| A2 | 新增 `RecipeStockMatch` 作为唯一在库判定；消耗 planner、菜谱库「缺 N 样」、详情页逐行「缺货」共用；详情页「加入买菜清单」；首页 hero 增加「还缺 … · 加入买菜清单」工具行 | 首页没有把就绪文字本身做成可点按钮（单菜时整个 hero 已是按钮，嵌套点击不可靠），改为 hero 末尾独立工具行 |
| A3 | 食材行前滑 / 长按「用完」，只清零该批次，撤销仅在该行仍为 0 时恢复 | 用完不经 `applyConsumption`（它按名称跨批次扣减，可能扣到另一批），因此不生成「最近消耗」记录；**删除仍保留确认框**——重新插入已删除的库存行可能与同步墓碑契约冲突（硬边界） |
| A4 | 下一步预览、步骤卡左右滑动切步、步骤时长一键计时、修复时长解析（`\b` 对中文无效） | **「下一步自动标记完成」未实现**：`RecipeCookingModeUITests` 断言「仅导航到下一步不应增加已完成步骤」，属测试约束的产品契约，需 owner 决定；**「保留进度」退出保留计时**未实现：计时器归属需提升到 session，另做 |

### 验证记录（2026-10-07，GitHub Actions macOS，Xcode 26.6 / iOS 26.5 模拟器，用的是 `xcodebuild` 这条备用路径，不是 Xcode MCP）

- `ios-release-check.yml` run 37653312470：Debug / Release 模拟器构建、无签名 Release archive 全部成功。
- `ios-tests.yml` run 37668877165（分支 `f8d0f16`）：
  - 单元测试 2447 个，2 失败、5 跳过；阶段 A 新增的 `ShoppingItemEditingTests`、`RecipeStockMatchTests`、`InventoryUsedUpTests` 全部通过。
  - 聚焦 UI 测试 113 个，2 失败；新增的滑动删除撤销、编辑数量两个 UI 测试通过。
- 剩余 4 个失败在 `main`（`c772a36`）上同样失败（同一 run 的 baseline job），属于阶段 A 之前就存在的问题，不是本次回归：
  - `AIConversationTransportTests.testRuntimeRequestCarriesNoProviderField`（请求体多了 `turnID`）
  - `ShoppingExperienceTests.testSearchKeepsFixedCategoryOrderAndNameSort`（中文排序随系统语言变化，CI 是英文环境）
  - `RecipeCookingModeUITests.testRecipeListFinalRowClearsFloatingTabBar`（`791.0000000000001 > 791`，浮点误差）
  - `ShoppingExperienceUITests.testStockInConfirmationProcessesPurchasedItemsIntoInventory`（「食材」同时匹配返回按钮和 tab）
- CI 抓到并已修复的阶段 A 回归：详情页「缺货」把数量挤离右侧对齐线 38pt（`RecipePresentationUITests`），改为放在食材名下方；在 `main` 上该测试通过，修复后分支上也通过。
- 未覆盖：Light/Dark、AX XXXL、小屏的人工视觉走查；全量 UI 测试（这次只跑了聚焦集合）。
