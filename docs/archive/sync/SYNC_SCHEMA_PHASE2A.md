# Phase 2A 云端业务 Schema 映射审查

状态：**Phase 2A-2.5 schema 已部署到 development 并真实验证；production 与客户端同步未启用**
日期：2026-07-13

本文以当前仓库代码为准，对 iOS SwiftData、PWA localStorage 与拟议 Supabase 表逐项映射。Phase 2A-2 不修改任何现有本地数据模型，也不上传本地数据。

## 1. 范围结论

首批同步实体为：

| 业务事实 | 云端表 | 作用域 | 纳入原因 |
| --- | --- | --- | --- |
| 库存 | `inventory_items` | household | iOS 与 PWA 都可编辑，是共享厨房核心事实 |
| 买菜清单 | `shopping_items` | household | 两端都可编辑，需要保持完成/入库状态 |
| 今日/未来计划 | `today_plan_items` | household | 当前并非周计划的可靠派生物，必须独立同步 |
| 库存消耗记录 | `consumption_records` | household | iOS 用于撤销和审计，不应仅做本地派生 |
| 周菜单 | `weekly_meal_plans` + `weekly_meal_plan_items` | household | iOS 已独立持久化；PWA 当前只把建议写入普通计划 |
| 用户菜谱 | `user_recipes` | household | 用户创建/导入内容应在家庭厨房内共享 |
| 收藏 | `recipe_favorites` | user | 明确是个人偏好；独立 UUID 由 user scope + recipe key 确定性生成 |
| 常做 | `frequent_recipes` | user | iOS 是显式用户选择；独立 UUID 由 user scope + recipe key 确定性生成 |

PWA 的 `recipe_activity` / `recipe_usage` 暂不直接映射到 `consumption_records`：两者语义和粒度不同，直接合并会伪造 iOS 的扣减审计记录。它们将在后续协议阶段单独评估。

## 2. iOS 当前本地模型审计

### 2.1 SwiftData 表

| SwiftData 模型 | 本地主键 | 重要字段 | 云端映射 | 差异/风险 |
| --- | --- | --- | --- | --- |
| `InventoryRecord` | `UUID` | 数量、单位、保质期、常备货架配置 | `inventory_items` | 无 household/version/tombstone；本地删除是物理删除 |
| `ShoppingItemRecord` | `UUID` | 数量、来源、完成状态、备注、`sortIndex` | `shopping_items` | 无创建/完成时间（PWA 有）；需适配 nullable 字段 |
| `TodayPlanRecord` | `UUID` | recipe ID/name、日期、份数、完成状态、排序 | `today_plan_items` | recipe ID 为 `String`；本地无 `cookedAt` |
| `ConsumptionRecordEntity` | `UUID` | 时间、菜谱、plan IDs JSON、items JSON、撤销状态 | `consumption_records` | JSON 载荷需在上传前验证 schema |
| `WeeklyPlanRecord` | `UUID`（持久化记录） | `startDate`、整份 plan JSON | 两张 weekly 表 | 业务 `WeeklyMealPlan` 本身无 id；不能在每次编码时重新生成 |
| `UserRecipeRecord` | `String` | 完整 recipe JSON、来源 URL、fingerprint、排序 | `user_recipes` | 云端要求 UUID；必须先建立稳定的一次性映射 |
| `RecipePreferenceRecord` | recipe `String` | favorite/frequent 两个 Bool | 两张个人偏好表 | 云端拆成两类墓碑记录，adapter 需做双向合并 |

### 2.2 领域模型

- `InventoryItem` 已是 UUID，适合直接作为云端 id。
- `MealPlanItem` 与 `KitchenShoppingItem` 已是 UUID。
- `InventoryConsumptionRecord` 已是 UUID，属于审计事件；`isUndone` 仍是可变状态。
- `WeeklyMealPlan` 没有领域 id，只有 SwiftData record id。后续 adapter 必须以 record id 为稳定云端 id，不能按周重新随机生成。
- `Recipe.id` 是字符串，既承载静态远端菜谱 key，也承载用户菜谱 id。云端用户菜谱只接受 UUID；非 UUID 旧用户菜谱必须在 `SyncMetadata` 中保存稳定映射，不能修改静态菜谱 key，也不能每次同步重新生成。
- 当前各 SwiftData repository 各自拥有 `ModelContext`，跨实体写入采用业务层 best-effort/rollback，不是单一事务。
- 当前仅 `APIClient` 是 actor；repository 不是 actor。后续同步层应使用独立 actor 与独立 `ModelContext`，不能让网络回调直接操作 View 的 context。

Phase 2A-2 **不向这些 @Model 添加云字段**。后续应建立独立 `SyncMetadata`、`PendingMutation`、`SyncCursor`，避免业务模型被网络状态污染。

## 3. PWA 当前本地模型审计

| localStorage key | 当前形状 | 云端映射 | 适配要求 |
| --- | --- | --- | --- |
| `S.keys.inventory` | 数组；历史项通常没有 id，包含 `name/qty/unit/buyDate/kind/shelf/stockStatus` 等 | `inventory_items` | 首次 bootstrap 前必须持久化一次性 UUID 映射；不能每次读取生成新 id |
| `S.keys.shopping_items` | 数组；`id` 为 `u-*` 字符串，含完成/入库时间 | `shopping_items` | 旧 id 不是 UUID；需要稳定映射，同时保留当前字符串 id 给 UI |
| `S.keys.plan` | `{id: recipeID, servings, date, isCooked, cookedAt...}` | `today_plan_items` | 当前没有行 UUID，同菜谱/日期组合不能作为永久主键；需要稳定映射 |
| `S.keys.overlay` | 基础菜谱 overlay、删除标记、食材映射 | `user_recipes`（仅用户拥有的记录） | 不能把基础菜谱或 overlay 删除标记误当用户菜谱上传 |
| `S.keys.favorite_recipes` | recipe ID 字符串数组 | `recipe_favorites` | 个人作用域；删除必须生成墓碑而非仅从数组移除 |
| `S.keys.recipe_activity` | 以 recipe ID 为 key 的计划/烹饪统计 | 暂缓 | 不是 iOS 消耗记录的等价物 |

PWA 当前“本周菜单”不独立持久化：AI/本地建议仅在用户确认后写入 `S.keys.plan`。因此云端周菜单首版主要承接 iOS 的现有周计划；PWA 将来要显示/编辑周计划时再接入两张 weekly 表。

## 4. 云端字段约定

所有 household 业务表统一包含：

```text
id UUID
household_id UUID
created_at TIMESTAMPTZ
updated_at TIMESTAMPTZ
deleted_at TIMESTAMPTZ NULL
version BIGINT
created_by UUID
updated_by UUID
```

`recipe_favorites` 与 `frequent_recipes` 是个人偏好，以 UUID `id` 为同步实体主键，并以 `(user_id, recipe_id)` 保证业务唯一；它们拥有同样的时间、墓碑、version 和 actor 字段。

### 4.1 ID 决策

- 已有 UUID 的 iOS 记录直接复用，不生成第二个云端 id。
- PWA 历史字符串/无 id 记录必须先建立本地稳定映射，再参与首次上传。
- `Recipe.id` 继续允许字符串，因为它也引用服务器静态菜谱；但 `user_recipes.id` 必须 UUID。
- change feed 的 `entity_id` 统一使用 UUID。个人菜谱偏好的 UUID 通过固定 namespace、user scope、entity type 与 recipe key 确定性生成，不依赖设备或随机重算。

## 5. 表设计摘要

### `inventory_items`

同时覆盖 iOS 的 expiry/staple 字段与 PWA 的 shelf/kind/frozen/dryPrep/stockStatus 字段。数量允许 NULL，避免把“未知”错误写成 0。`normalized_name` 仅用于查找/合并，不设全局唯一，因为同名不同批次可合法并存。

### `shopping_items`

同时保留数值 `quantity` 与不能安全解析时的 `quantity_text`；保留 PWA 已有的 `stocked_in_at`/`completed_at`。不以名称做唯一约束，同名不同单位可独立存在。

### `today_plan_items`

独立保存 recipe 字符串引用、日期、份数和完成状态。它不是 weekly 表的物化视图：用户可单独添加、移动和完成计划。

### `consumption_records`

属于 household 审计事实。`items` 和 `plan_ids` 首版保留 JSON 数组以无损承接现有 iOS Codable 结构；后续如需跨记录聚合再规范化。撤销写 `is_undone=true` 并增加 version，不物理删除原事件。

### weekly tables

`weekly_meal_plans` 保存周起始日、人数、摘要与生成购物项快照；`weekly_meal_plan_items` 保存 day/meal/recipe 层次。AI 新菜谱必须保留 `recipe_snapshot`，不能只存一个可能不存在于菜谱库的 recipe ID。

### `user_recipes`

结构化保存食材、调料、步骤、来源和 fingerprint。canonical URL 与 fingerprint 都是 household 内活动记录的部分唯一键，用于防止重复导入；墓碑记录不阻止用户未来重新导入。

### personal preference tables

收藏与常做分表，使每一项开关有独立 UUID/version/tombstone。iOS 本地组合 record 由 adapter 合并，PWA 收藏数组由 adapter 转换。

## 6. 不应同步或暂缓同步的数据

- AI 推荐缓存、首页推荐签名、抓取中间结果：可重建缓存，不同步。
- API Key、token、session、Local.xcconfig、`.env*`：绝不进入业务表。
- 静态菜谱包：服务器公共数据，不逐用户复制。
- PWA demo 状态、安装提示、缓存标记：设备本地偏好。
- 通知授权状态：系统/设备状态，不做 household 同步。
- PWA `recipe_activity` / `recipe_usage`：需先明确与 iOS consumption/frequent 的语义，暂缓。

## 7. Phase 2A-3 前置阻塞

1. 为 PWA 无 UUID 记录实现持久化 bootstrap 映射；已有 legacy ID 使用已冻结的 UUIDv5 helper。
2. 为 iOS 非 UUID 用户菜谱与无领域 id 的周计划实现 SyncMetadata adapter。
3. 为每个 `(scopeType, scopeId)` 建立独立持久化 cursor；禁止 household 与 personal 共用 cursor。
4. 在 Phase 2A-3 只实现 disabled-by-default 的本地 metadata/pending/cursor 边界，不上传 Guest 数据。
