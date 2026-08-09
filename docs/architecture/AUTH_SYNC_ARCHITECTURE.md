# Kitchen Manager 账户与跨端同步架构设计

状态：设计提案，尚未授权实现
日期：2026-07-12
范围：PWA、Render Express 后端、原生 iOS App

## 1. 结论摘要

当前系统没有账户、用户身份、会话、云端业务数据库或同步机制。PWA 的厨房数据保存在浏览器 `localStorage`；iOS 的八类数据保存在一个本地 SwiftData `ModelContainer`；Render 上的 Express 服务只提供公开的 AI、媒体处理和网页菜谱导入 API。

推荐方向：

1. 保留 **Guest-first**。未登录用户继续完整使用本地功能。
2. 采用 **Supabase Auth + Supabase Postgres**，现有 Express 继续作为受保护的业务同步与 AI API 层。
3. 从第一版建立 `households` 和 `household_members`。每位新用户自动拥有一个个人 household，暂不开放邀请 UI。
4. 厨房共享数据绑定 `household_id`；收藏、常做等个人偏好绑定 `user_id`。
5. 业务记录继续使用当前客户端 UUID 作为云端主键，不增加第二套 server ID。
6. 第一版同步采用批量增量协议：`POST /api/sync/push` + `GET /api/sync/pull?cursor=...`，服务器分配单调 cursor 和版本号。
7. 本地业务模型不加入同步字段；新增独立的本地 `SyncMetadataRecord` 和每账号独立的 SwiftData store。
8. 首次登录默认执行“预检后合并”，从不静默清空本地数据；云端和本地都非空时必须展示选择与摘要。

这是一份设计，不代表已创建 Supabase 项目、数据库、账户或生产密钥。

## 2. 当前系统事实

### 2.1 PWA

- 框架：无框架，HTML、CSS、原生 JavaScript ES Modules。
- 构建：无 TypeScript、Vite、Webpack 或 Babel。
- 路由：`app.js` 的 hash 路由。
- 状态管理：页面渲染时从 `src/storage.js` 的 `S` 读取，写入后通过 `onRoute()` 重渲染；没有集中式响应式 store。
- 数据获取：静态菜谱 JSON 使用 `fetch`；AI/导入通过 `src/ai.js` 等模块请求 Render API。
- 持久化：核心用户数据全部在浏览器 `localStorage`。
- 登录：不存在。
- `sessionStorage`：只用于菜谱编辑的临时 AI 草稿，不是登录 session。

主要数据来源：

| 数据 | 当前来源 |
| --- | --- |
| 库存 | `km_v19_inventory` |
| 今日计划 | `km_v19_plan` |
| 买菜清单 | `km_v87_shopping_items` |
| 用户菜谱 | `km_v19_overlay`，以基础菜谱 overlay 表达 |
| 收藏 | `km_v80_favorite_recipes` |
| 常做/烹饪活动 | `km_v2_recipe_activity`、`km_v95_recipe_usage` |
| 常备货架 | `km_v1_staples`、`km_v1_pantry_config` |
| 系统菜谱 | `data/*.json` 静态文件 |
| AI 推荐缓存 | 多个 `km_v48_*` / `km_v97_*` key |

### 2.2 后端

- 框架：Node.js 18+、Express 4、CommonJS。
- 部署：当前线上地址为 Render Web Service；同一进程托管静态文件和 `/api/*`。
- 数据库：无。
- ORM / migration：无数据库 ORM、数据库 schema 或数据库 migration 工具。
- 身份认证：无认证 middleware，无用户表，无 session/JWT/OAuth。
- 用户隔离：无；请求只能按 IP 做内存限流。
- API：
  - `GET /api/xhs-extract`
  - `POST /api/media/extract-audio`
  - `POST /api/media/extract-frames`
  - `POST /api/media/ocr-frames`
  - `POST /api/media/transcribe`
  - `GET /api/ai-status`
  - `POST /api/ai-chat`
  - `POST /api/recipe-import-from-url`
  - `POST /api/ai-parse`
- CORS：只允许指定 GitHub Pages origin 和一个可选额外 origin；目前只声明 `GET,POST,OPTIONS` 和 `Content-Type`。
- 限流：按 Express `req.ip` 的进程内 Map；Render 重启或多实例时不共享。
- 环境变量：AI provider/model/key、媒体限制、端口、CORS 额外来源和可信代理跳数。
- OpenAPI / schema sharing：不存在。

### 2.3 iOS

- UI：原生 SwiftUI，五个系统 Tab。
- Store：`KitchenStore`、`RecipeStore`、`HomeRecommendationStore` 及任务级 ObservableObject。
- 本地数据源：一个生产磁盘 `ModelContainer`，测试使用独立内存 container。
- SwiftData 模型：
  - `InventoryRecord`
  - `ShoppingItemRecord`
  - `TodayPlanRecord`
  - `ConsumptionRecordEntity`
  - `WeeklyPlanRecord`
  - `UserRecipeRecord`
  - `RecipePreferenceRecord`
- 网络：共享 actor `APIClient` + `APIEndpoint`；当前没有 token interceptor 或 401 refresh/retry。
- 后端连接：系统菜谱下载、AI chat、AI parse、链接/图片/小票导入与媒体流程。
- 完全本地：库存、购物、计划、消耗历史、周菜单、用户菜谱、收藏和常做。
- Keychain：未使用。
- 登录：未实现。

### 2.4 当前文本架构图

```text
┌──────────────────────── PWA ────────────────────────┐
│ HTML/CSS/ES Modules                                 │
│ hash route → domain modules → localStorage (S.keys) │
│ static recipes ← data/*.json                       │
└──────────────────┬──────────────────────────────────┘
                   │ public HTTPS /api, no identity
                   ▼
┌────────────── Render Express ───────────────────────┐
│ static hosting + AI proxy + page/media extraction  │
│ IP in-memory rate limits + SSRF/media safeguards   │
│ no users / no sessions / no database               │
└──────────────────┬──────────────────────────────────┘
                   │ provider secret on server
                   ▼
             AI provider / public web

┌──────────────────────── iOS ────────────────────────┐
│ SwiftUI → KitchenStore / RecipeStore                │
│ SwiftData shared local ModelContainer               │
│ APIClient ─────────────── public Render /api        │
└─────────────────────────────────────────────────────┘

PWA localStorage and iOS SwiftData have no link today.
```

## 3. 认证能力核对

1. PWA 是否有登录：否。
2. 后端是否识别用户：否。
3. 是否存在 user ID：否。
4. 是否有 session cookie：否。
5. 是否有 JWT access token：否。
6. 是否有 refresh token：否。
7. 是否已有 OAuth：否。
8. 是否支持 Apple 登录：否。
9. 是否支持 Google 登录：否。
10. iOS 是否可复用当前认证：没有可复用的认证。
11. 当前 API 是否全部公开：是。只有 CORS 和 IP 限流，不等于认证；非浏览器客户端不受 CORS 保护。
12. 未来必须登录的接口：`/api/me`、所有 `/api/sync/*`、账户/household/导出/删除接口。AI 接口可在 Guest 阶段继续有限公开，但登录用户应进入按 user/plan 配额的受保护桶；高成本媒体和导入接口最终也应要求登录或使用严格匿名额度。

## 4. 认证方案比较

| 方案 | 开发复杂度 | 安全/维护 | PWA+iOS | Apple/Google | 数据层 | 结论 |
| --- | --- | --- | --- | --- | --- | --- |
| A 复用当前系统 | 不适用 | 当前没有认证可复用 | 不适用 | 无 | 无 | 排除 |
| B1 Supabase Auth + Postgres | 中 | 托管密码、验证、OAuth、JWT；仍需正确 RLS/API 授权 | Web 与 Swift 均可接入 | 支持 | 与关系型同步表天然匹配 | **推荐** |
| B2 Firebase Auth + Firestore | 中 | 成熟 SDK/模拟器/匿名升级 | Web 与 Apple 平台成熟 | 支持 | 文档型数据与当前 Express/Postgres式同步设计差异较大 | 可行备选 |
| B3 Clerk/Auth0 + 独立数据库 | 中高 | 身份能力强，需另选数据库并整合计费/租户 | 均支持 | 支持 | 身份和数据分离，组件更多 | 规模扩大时备选 |
| C 自建邮箱密码 + JWT | 很高 | 密码散列、邮件验证、找回、rotation、撤销、OAuth、审计全部自担 | 可做 | 需分别实现 | 可自由选择 | 当前团队/规模不推荐 |

明确推荐 Supabase：它将 Auth、Postgres 和 RLS 放在同一平台，能减少当前“零数据库”项目需要新增的基础设施数量；官方支持 Apple、Google、JWT/JWKS 和数据库 RLS。Firebase 同样成熟，但会使同步业务更偏向 Firestore 文档/规则体系，与保留现有 Express 业务层和关系型约束的方向不如 Supabase直接。

参考官方文档：

- Supabase Auth / RLS: https://supabase.com/docs/guides/auth
- Supabase JWT / JWKS: https://supabase.com/docs/guides/auth/jwts
- Supabase Apple: https://supabase.com/docs/guides/auth/social-login/auth-apple
- Supabase Google: https://supabase.com/docs/guides/auth/social-login/auth-google
- Firebase Auth: https://firebase.google.com/docs/auth

不应把 Supabase service-role key 放入 PWA 或 iOS。客户端只有 publishable/anon key；Express 使用服务端凭据，并且所有请求先根据 access token 得出用户身份。

## 5. 统一身份和 household

### 5.1 建议模型

```text
profiles
- id uuid PK references auth.users(id)
- email text
- display_name text
- created_at timestamptz
- updated_at timestamptz

households
- id uuid PK
- name text
- created_by uuid references profiles(id)
- created_at timestamptz
- updated_at timestamptz

household_members
- household_id uuid
- user_id uuid
- role text check owner/admin/member
- created_at timestamptz
- PK(household_id, user_id)
```

第一版产品仍表现为单用户。注册事务自动创建“我的厨房” household 和 owner membership，不提供邀请/共享 UI。现在保留 household 能让伴侣共享无需以后给所有表补 ownership 并迁移现有数据。

归属建议：

- `household_id`：inventory、shopping、today plan、consumption、weekly plan、user recipes。
- `user_id`：recipe preferences、设备、session/audit、个人设置。
- user recipe 额外保存 `created_by` / `updated_by`，但 ownership 仍是 household。
- 主题、通知权限、PWA UI 状态继续仅设备本地，不同步。

## 6. 云端数据模型

所有厨房表共同字段：

```text
id uuid PK                 -- 客户端现有 UUID
household_id uuid NOT NULL
created_at timestamptz NOT NULL DEFAULT now()
updated_at timestamptz NOT NULL DEFAULT now()
deleted_at timestamptz NULL
version bigint NOT NULL DEFAULT 1
change_seq bigint NOT NULL -- 服务器单调变更序号/同步 cursor
last_device_id uuid NULL
```

服务器忽略客户端提交的 `household_id`/`user_id`，从认证用户 membership 推导。客户端时间只作为业务信息，不参与冲突排序。

### 6.1 `inventory_items`

- 独立列：`id`, `household_id`, `name`, `normalized_name`, `quantity`, `unit`, `expiry_date`, `is_staple`, `created_at`, `updated_at`, `deleted_at`, `version`, `change_seq`, `last_device_id`。
- `staple_settings jsonb`：threshold、默认补货量、追踪模式、状态、备注、分类等低频扩展字段。
- 索引：`(household_id, deleted_at)`, `(household_id, normalized_name)`, `(household_id, expiry_date)`。
- 不以名称做唯一约束：同名不同批次必须共存。

PWA 当前 inventory 没有 UUID。进入同步前必须做一次本地迁移，为每个库存批次生成并永久保留 UUID；仍可继续按现有 name/kind 逻辑匹配，但云端身份不能靠名称。

### 6.2 `shopping_items`

- 独立列：name、normalized_name、quantity、unit、done、stocked_in、source、remark、排序字段。
- 索引：`(household_id, done, deleted_at)`。
- 不对 normalized name 做唯一约束；当前同名不同单位/来源可能独立存在，合并仍由现有业务规则决定。

### 6.3 `today_plan_items`

- 独立列：recipe_id、recipe_name snapshot、servings、plan_date、is_cooked、cooked_at、sort_index。
- 索引：`(household_id, plan_date, deleted_at)`。
- Recipe 删除不级联删除历史计划；使用名称快照保证可读性。

### 6.4 `consumption_records`

- 独立列：recipe_id、recipe_name、consumed_at、is_undone。
- `plan_ids jsonb` 和 `entries jsonb` 保持当前完整业务语义，避免为了少量嵌套数组过度拆表。
- 默认 append-only；undo 是同一记录的显式状态更新。
- 索引：`(household_id, consumed_at desc)`。

### 6.5 `weekly_plans`

- 每份周计划一行，`start_date` 单独索引，完整 `plan_json jsonb` 保留当前快照结构和 AI-only recipes。
- 唯一约束可为 `(household_id, start_date)`；如果产品只保留当前计划，也应使用稳定计划 UUID 而不是数据库 singleton。
- JSON 必须有 `schema_version`，服务端验证后才接受。

### 6.6 `user_recipes`

- 完整 `recipe_json jsonb`，保持 iOS 当前 lossless Codable 语义。
- 独立列：title、normalized_source_url、content_fingerprint、created_by、updated_by、sort_index。
- 唯一约束：`(household_id, id)`（由 PK 已隐含）、可对非空 `normalized_source_url` 建 partial unique；内容指纹先作为索引和重复提示，不应强制唯一，因为用户可能有意保存变体。
- PWA adapter 将 overlay + 基础菜谱解析为完整用户 recipe 上传；下载时可在本地继续生成 overlay，不能直接覆盖 `data/*.json`。

### 6.7 `recipe_preferences`

```text
user_id uuid
recipe_id text
is_favorite boolean
is_frequent boolean
updated_at / deleted_at / version / change_seq / last_device_id
PK(user_id, recipe_id)
```

偏好允许指向静态远端菜谱或用户菜谱，因此不对 `recipe_id` 建强制外键。静态菜谱 ID 必须保持跨 PWA/iOS 稳定。

### 6.8 同步辅助表

- `sync_operations(operation_id uuid PK, user_id, household_id, device_id, received_at, result_json)`：push 幂等。
- `devices(id uuid PK, user_id, platform, display_name, last_seen_at, revoked_at)`。
- `account_deletion_requests` / 审计记录按合规需要加入，日志不得保存 token 或完整用户内容。

## 7. 同步协议选择

### 7.1 比较

- 全量拉取：实现最简单，但每次下载全部历史，删除和多设备冲突处理仍不能省略。只适合首次 bootstrap 或小规模故障恢复。
- 增量同步：使用服务器 cursor 返回变更和 tombstone；复杂度适中，适合当前规模。
- 完整事件日志/CRDT：审计和合并能力最强，但会显著扩大模型、压缩和回放复杂度，当前过度设计。

推荐：**版本化记录 + 服务器 change cursor 的增量同步**。保留全量 snapshot endpoint 作为首次下载/恢复手段，不引入通用 CRDT。

### 7.2 API 形态

第一版推荐聚合 sync API，而不是七套资源 CRUD。原因是一次厨房操作会跨库存、消费记录、计划和购物清单，批量事务与统一 cursor 更可靠，也更适合离线队列。

```http
POST /api/sync/push
Authorization: Bearer <access-token>
Idempotency-Key: <operation-batch-uuid>
Content-Type: application/json

{
  "deviceId": "uuid",
  "householdId": "uuid-for-selection-only",
  "operations": [
    {
      "operationId": "uuid",
      "entity": "inventory_item",
      "action": "upsert",
      "id": "uuid",
      "baseVersion": 4,
      "payload": { "name": "鸡蛋", "quantity": 6, "unit": "个" }
    },
    {
      "operationId": "uuid",
      "entity": "shopping_item",
      "action": "delete",
      "id": "uuid",
      "baseVersion": 2
    }
  ]
}
```

```json
{
  "accepted": [{ "operationId": "uuid", "id": "uuid", "version": 5, "changeCursor": "845" }],
  "conflicts": [{ "operationId": "uuid", "reason": "version_mismatch", "serverRecord": {} }],
  "nextCursor": "845",
  "serverTime": "2026-07-12T22:00:00Z"
}
```

```http
GET /api/sync/pull?householdId=<uuid>&cursor=845&limit=500
Authorization: Bearer <access-token>
```

```json
{
  "changes": [
    { "entity": "inventory_item", "id": "uuid", "version": 6, "deletedAt": null, "payload": {} },
    { "entity": "shopping_item", "id": "uuid", "version": 3, "deletedAt": "2026-07-12T22:10:00Z" }
  ],
  "nextCursor": "901",
  "hasMore": false,
  "serverTime": "2026-07-12T22:11:00Z"
}
```

辅助账户 API：

- Supabase Auth SDK/REST 负责 signup/login/OAuth/refresh/logout。
- `GET /api/me` 返回 profile、households、权限和 feature flags。
- `POST /api/sync/bootstrap/preview` 返回首次合并摘要，不写数据。
- `POST /api/sync/bootstrap/commit` 使用 idempotency key 提交首次合并。
- `GET /api/export` 和 `DELETE /api/account` 后续提供数据导出/删除。

## 8. 冲突策略

全局原则：服务器版本是唯一并发依据；不按设备 `updatedAt` 判断先后。普通 push 使用 optimistic concurrency。删除写 tombstone，不能物理删除后让离线设备复活数据。

| 模块 | 推荐策略 |
| --- | --- |
| Inventory | 不静默 LWW 数量。版本冲突时返回服务器记录；名称/备注等可自动三方合并，数量/单位/保质期冲突要求用户选本地、云端或手动合并。未来可把“增减库存”升级为语义操作。 |
| Shopping | 不同 UUID 自然合并；同项勾选/编辑用 server version。相同字段冲突默认服务器最后接受值，并保留可重试本地变更；删除 tombstone 优先于基于旧版本的编辑。 |
| Today Plan | 不同计划 UUID 合并；同一项 servings/date/cooked 冲突使用 optimistic concurrency。已完成状态不应被旧离线未完成状态覆盖。 |
| Consumption | 创建为 append-only，UUID 幂等；相同 ID 内容不一致视为错误。Undo 使用版本检查，不能重复恢复库存。 |
| Weekly Plan | JSON 快照冲突不可字段级可靠合并；保留两个版本，用户选择当前版本，未选版本作为历史快照。 |
| User Recipe | title/tags/ingredients/steps 的并发修改保留两个副本或进入手动冲突编辑器，绝不静默覆盖。来源 URL 和内容指纹用于提示重复，不作为无条件合并依据。 |
| Preferences | `(user_id, recipe_id)` 布尔状态可用服务器接受顺序 LWW；这是低损失、可立即重做的个人操作。 |

场景答案：

- iPhone/PWA 同改库存：第二个提交收到 409，数量冲突人工确认。
- 一端删除另一端编辑：如果编辑的 baseVersion 早于 tombstone，删除胜；UI 可提供“恢复为新记录”。
- 两端同时勾购物项：服务器 version 串行；客户端 pull 后收敛。
- 同时编辑用户菜谱：保存冲突副本，不丢任一版本。
- 离线数天：先 pull 到本地 shadow，逐个 rebase pending operations，再 push。
- 卸载/换机：登录后 bootstrap 全量云端数据；没有登录且无备份的数据无法恢复。
- 服务器/设备时钟不同：冲突只看 server version/change_seq；设备时间只展示或保存业务发生时间。

## 9. 本地同步元数据

不建议把 `serverID/syncStatus/serverVersion/...` 塞进七个现有业务模型。推荐独立表：

```text
SyncMetadataRecord
- key: "entityType:entityID" (unique)
- entityType
- entityID
- serverVersion
- syncStatus: synced|pending|conflict|failed
- pendingOperation: upsert|delete|null
- lastSyncedAt
- lastErrorCode

SyncCursorRecord
- householdID
- cursor
- lastSuccessfulSyncAt

PendingSyncOperationRecord
- operationID (unique)
- entityType / entityID / action
- baseVersion
- payloadData
- createdAt / retryCount
```

- 当前 UUID 直接作为云端 UUID，不需要两套 ID。
- 离线新增：业务记录立即写本地，同时事务性加入 pending operation，`baseVersion = 0`。
- 删除：本地 UI 隐藏业务记录，但保留 pending delete/tombstone metadata，直到服务器确认且超过保留窗口。
- 成功：更新 serverVersion/cursor/lastSyncedAt，删除对应 pending operation。
- 失败：业务数据不回滚；保留队列并显示同步状态。

PWA 也使用同一 JSON contract，但本地队列应放 IndexedDB；现有 localStorage 继续作为业务数据源的过渡阶段。不要把大量 operation payload 塞进 localStorage。

## 10. 首次登录与数据合并

推荐交互：

1. 登录前创建本地加密/JSON safety snapshot，且不删除原数据。
2. 获取 `/api/me` 和云端计数摘要。
3. 本地和云端均为空：直接绑定账号。
4. 只有本地有数据：默认“上传并保留本地”，先 preview 后幂等 commit。
5. 只有云端有数据：下载到新的账号 store，完成校验后切换；Guest store 保留直到用户确认。
6. 两端都有数据：展示三项选择：
   - **合并（推荐）**：按 UUID 合并，冲突逐项确认。
   - 使用云端：不是立刻删除；先存档 Guest 数据，再替换账号 store。
   - 仅上传本地：高风险，仅在二次确认后允许覆盖/归档云端冲突。
7. commit 返回完整 accepted/conflict 清单；只有校验通过才标记 bootstrap complete。

各模块首次合并：

- 库存：UUID 合并；PWA 先补 UUID。不同 UUID 即使同名也不自动压成一批，只提示可能重复。
- 购物：UUID 合并；同名同单位可在 preview 中建议合并，不自动丢项。
- 今日计划：UUID 合并；同菜谱不同计划 ID 保持独立。
- 消耗记录：UUID 幂等；相同 ID 不同内容阻止 commit。
- 周菜单：同 startDate 两个快照形成显式冲突。
- 用户菜谱：先 ID，再 normalized source URL，再 content fingerprint；后两者只提示，用户确认后合并。
- 收藏/常做：集合并集是首次 bootstrap 的安全默认；之后按普通偏好同步。

任何步骤失败都继续使用原 Guest 数据，不写“已迁移”标记。

## 11. Guest、登出和多账号

### Guest 模式

明确推荐 Guest-first。当前产品已有完整离线能力，强制登录会破坏本地优先定位并提高首次使用门槛。登录的价值表达为“备份与跨设备同步”，不是使用前置条件。

### iOS 数据隔离

- Guest 使用独立 `guest` ModelContainer。
- 每个账号使用按 auth user UUID 命名的独立 ModelContainer，例如 `Kitchen-<userID>.store`。
- `AppRootView` 根据 auth state 创建/销毁对应 `AccountDataCoordinator`、`KitchenStore` 和 `RecipeStore`。
- 不建议在同一表只加 userID 后让多个账号共享一个 context；查询遗漏 predicate 会造成串数据。
- 同一账号重新登录复用其缓存并先 sync；新账号绝不能看到上个账号 store。

登出默认：撤销/清除 Keychain session，停止 sync，卸载账号 container，但保留设备缓存以便同账号离线快速恢复。提供“登出并删除此设备数据”明确选项。账号缓存应使用 iOS Data Protection；极敏感威胁模型下再评估文件级加密。

PWA 多账号应采用 user-scoped IndexedDB database。登出后不把上个账号业务数据重新映射到全局 `S.keys`；过渡期必须先完成 storage adapter，否则不开放账号切换。

## 12. iOS 认证规划

建议后续结构：

```text
Authentication/
  AuthState.swift
  AuthManager.swift
  AuthService.swift
  TokenStore.swift
  LoginView.swift
  AccountView.swift
Sync/
  SyncCoordinator.swift
  SyncAPI.swift
  SyncModels.swift
  SyncMetadataRecord.swift
  PendingSyncOperationRecord.swift
  AccountDataCoordinator.swift
```

- `AuthManager @MainActor ObservableObject`：guest/restoring/authenticated/expired 状态。
- `AuthService actor`：PKCE/OAuth、refresh、logout；优先使用官方 Supabase Swift SDK，不自写 JWT 验签。
- `TokenStore actor`：refresh token 仅 Keychain；access token 可放内存，必要时 Keychain；使用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 或按后台同步需求评估。
- `APIClient`：后续通过 token provider 注入 `Authorization: Bearer`；遇 401 只允许 single-flight refresh + 一次重放，避免刷新风暴。
- App 启动：恢复 Keychain session → refresh → `/api/me` → 选择账号 container；失败时不删除缓存，进入离线/重新登录状态。
- 登出：先停止新请求、取消 sync、尝试 provider logout/revoke，再清 token 和卸载 store。
- Sign in with Apple：iOS 使用 AuthenticationServices 取得 identity token/nonce，再交换 Supabase session；PWA 走 OAuth redirect。

## 13. 安全设计与当前风险

必须实施：

- 密码、邮箱验证、重置由托管 Auth 处理，不在 Express 保存密码。
- Express 使用成熟 JOSE/JWT 库和 Supabase JWKS 验证 `iss/aud/exp/signature`，不能只 decode token。
- `user_id`、`household_id` 和角色完全由 token + membership 查询得出，绝不信客户端 payload。
- 所有业务表启用 RLS；即使 Express 使用 service role，也要在服务层做统一 authorization，并用集成测试证明用户隔离。
- 正常同步请求优先让 Express 以用户 JWT 创建 user-scoped Supabase client，或调用 `security invoker` 数据库函数，使 RLS 继续生效。Service-role 只用于明确列出的后台管理任务，不能成为普通同步请求的默认连接。
- 全站 HTTPS；生产拒绝非 HTTPS callback。
- PWA OAuth 使用 Authorization Code + PKCE、state、nonce。若用 Bearer token，强化 CSP、移除不安全 `innerHTML`；不要把 refresh token写入备份。
- 如果未来改用同站 HttpOnly cookie，所有写接口必须 CSRF token + SameSite/Origin 校验。当前 GitHub Pages → Render 跨站部署使第三方 cookie 不可靠，因此第一版不推荐 cookie session。
- Refresh token rotation/reuse detection；iOS 放 Keychain，日志永不输出 token/header/body。
- CORS 增加 `Authorization, Idempotency-Key`，但 CORS 不是授权。
- 速率限制从单进程 Map 移到共享 Redis/数据库桶，并按 user + IP + endpoint 分层；匿名 AI 配额更严。
- 数据导出与账户删除必须覆盖所有 household ownership/member 规则；最后 owner 删除需转移或删除 household。

当前仓库风险：

1. 所有高成本 AI/媒体 API 无认证，任何脚本可调用；CORS 无法阻止非浏览器滥用。
2. 限流在进程内，重启清空，多实例不共享。
3. AI 状态接口公开，可能泄露服务能力配置（需继续避免返回密钥/敏感上游细节）。
4. PWA 支持 BYOK，浏览器 token/key 暴露面受 XSS 影响；备份目前会剥离 API Key，但未来 auth token也必须明确排除。
5. 前端存在大量动态 DOM/`innerHTML` 路径，接入持久 auth token 前必须完成 XSS 审计和 CSP。
6. 没有持久审计、账户撤销、数据导出/删除或用户隔离测试。
7. Render 与 Supabase 的 region、连接池、备份和密钥轮换尚未配置。

## 14. PWA 迁移影响和共享契约

PWA 需要新增：Auth 状态/登录页、OAuth callback、Bearer API wrapper、Guest/账号 storage adapter、首次合并 UI、IndexedDB pending queue、同步状态、冲突界面、在线/离线触发和账号清除选项。

保持不变：hash 路由语义、Guest 本地功能、基础菜谱静态包、现有 backup 文件可作为安全迁移输入。

可跨端共享的是契约而不是运行时代码：

- `docs/schemas/*.json` JSON Schema。
- OpenAPI 3.1 API contract。
- entity 名称、字段语义、enum raw values。
- `sync_protocol_version`、recipe/weekly JSON `schema_version`。
- 固定测试 fixtures 和 golden payload。
- UUID、日期（RFC 3339 UTC timestamp / 本地业务 date）规范。

Swift Codable 和 JS validator 分别由相同 schema/fixtures 验证。当前不建议为了共享类型把 PWA 改成 TypeScript。

## 15. 目标架构图

```text
 PWA Guest localStorage/IndexedDB       iOS Guest SwiftData
             │                                  │
             ├── login/bootstrap preview ───────┤
             ▼                                  ▼
 PWA account IndexedDB              per-user SwiftData ModelContainer
 auth session + pending ops          Keychain + pending ops
             │ Bearer JWT                         │ Bearer JWT
             └──────────────┬─────────────────────┘
                            ▼
                 Render Express API
        JWT/JWKS auth → membership authorization
        sync transaction / AI quota / import guards
                    │                 │
                    ▼                 ▼
       Supabase Postgres + RLS     AI/media providers
       Auth / profiles / household
       records + tombstones + seq
```

## 16. 明确不在本轮实施

- 不添加任何 auth SDK/dependency。
- 不创建 Supabase 项目、数据库表、RLS policy 或生产环境变量。
- 不修改 `S.keys`、SwiftData schema、备份格式、API 行为或登录 UI。
- 不启用同步，不上传任何现有本地数据。
