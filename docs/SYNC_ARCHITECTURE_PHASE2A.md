# Phase 2A 同步协议基础设计

状态：**Phase 2A-2.5 development 后端已验证；Phase 2A-3 iOS 基础已实现但仍默认 disabled**
日期：2026-07-13

## 1. 保持 Guest-first

- 未登录用户继续只读写现有 SwiftData/localStorage。
- 登录本身不触发上传、下载、覆盖或合并。
- 用户必须在未来明确开启云同步，并先看到 bootstrap 预览。
- Phase 2A-2 仍没有任何自动同步代码，也没有修改 iOS/PWA 本地 schema。

## 2. 所有权模型

### Household shared

库存、买菜、今日计划、消耗记录、周菜单、用户菜谱属于 household。RLS 只允许 household member 读取；任何客户端都不能以 body/query 传入 user ID 作为授权依据。

### Personal

收藏与常做只属于 `auth.uid()`。它们不会因加入同一 household 而对其他成员可见。

## 3. 统一 change feed

采用单表 `sync_changes`，而不是每个业务表独立序列表：

```text
sequence BIGINT IDENTITY (全局单调)
household_id XOR user_id
entity_type
entity_id
operation = upsert | delete
version
changed_at
changed_by
record_data (该 sequence 对应的事务时快照)
```

同步 cursor 是十进制 `sequence` 字符串，但它属于一个明确的 `(scopeType, scopeId)`。下载语义为先锁定 household 或 user scope，再执行 `sequence > cursor ORDER BY sequence LIMIT n`。返回批次的 cursor 是本批最大 sequence；空批次保持原 cursor。客户端只有在整批应用并保存成功后才能推进该 scope 的 cursor。

使用数据库 identity，而不是 `updated_at + id`，避免同毫秒写入、时钟偏差和分页漏项。trigger 同事务写入当时的 `record_data`，避免连续更新后旧 sequence 错带最新行快照。household 与 personal change 共用全局 sequence，但 pull 只查询一个 scope，bootstrap 为每个 household 和当前 user 分别返回 cursor，客户端不得跨 scope 复用 cursor。

## 4. Version 与冲突

- 新纪录 version = 1。
- 每次业务更新、软删除或恢复都由数据库 trigger 设置 `version = old.version + 1`。
- 客户端不能提交或覆盖 `created_by`、`updated_by`、`household_id`、version。
- mutation 必须带 `baseVersion`（新建时为 null/0）和 UUID `mutationId`。
- 当前 mutation RPC 在单事务内：
  1. 从 `auth.uid()` 取得 actor；
  2. 验证 household membership；
  3. 检查 `(user_id, mutation_id)` 是否已处理；
  4. 以 `id + version = baseVersion` 原子匹配；
  5. 写业务行、递增 version、写 change feed；
  6. 写入 mutation ledger 并返回结果。

当前草稿显式撤销 authenticated 对业务表的 INSERT/UPDATE/DELETE，只授予 RLS 约束的 SELECT。`apply_sync_mutation` 是唯一写入口，使用固定 allowlist、JWT actor、membership、baseVersion 与 mutation ledger；客户端无法通过普通 PostgREST update 绕过并发检查。

### 冲突响应契约

```json
{
  "mutationId": "uuid",
  "entityId": "uuid",
  "status": "conflict",
  "version": "4",
  "errorCode": "stale_version",
  "serverRecord": {}
}
```

单项冲突是可预期的业务结果，因此 batch endpoint 返回 HTTP 200，并在对应 result 中标记 `conflict`；认证、格式和服务故障仍使用 HTTP 错误。默认不做 silent last-write-wins。客户端可展示“使用云端版本 / 保留本机并基于新 version 重试 / 稍后处理”。

## 5. 删除与墓碑

- 同步实体禁止客户端物理 DELETE。
- 删除写 `deleted_at`，version 递增，并生成 `operation=delete` 的 change。
- 下载端必须保留 tombstone 同步元数据，不能只过滤删除行后推进 cursor。
- 恢复删除记录属于一次显式 upsert：清空 `deleted_at` 并递增 version。
- 服务器可在所有活跃设备 cursor 都越过墓碑且超过保留期后做物理清理；清理机制不属于 Phase 2A。
- iOS/PWA 当前本地删除仍是物理删除。直到 PendingMutation/tombstone 本地层完成前，不开启自动上传。

## 6. 幂等

`sync_mutations` 的主键是 `(user_id, mutation_id)`：

- 同一用户重试同一 mutation 返回第一次结果，不重复执行。
- 不同用户可以产生相同 UUID 而互不冲突。
- ledger 只保存安全的结果元数据（状态、version、error code），不保存 token 或完整敏感请求。

本阶段不自动清理 ledger。未来只有在设备注册/last-seen 与持久化 cursor 可证明重试窗口已经结束后，才由受控服务端任务分批清理：记录至少保留 90 天，且其 `result_sequence` 必须低于该用户所有活跃设备已确认 cursor。没有足够设备确认信息时宁可保留，避免旧离线 mutation 被误执行第二次。

## 7. RLS 与写入边界

### 读取

- household 表：`private.is_household_member(household_id, auth.uid())`。
- personal 表：`user_id = auth.uid()`。
- change feed：满足 household member 或 personal self。
- mutation ledger：只能读自己的记录。

### 写入

不提供 authenticated direct DML policy。RPC 固定 `search_path`，限定 entity/table/column allowlist，从 JWT 取 actor，并拒绝跨 household、伪造 actor、未知字段和物理删除。

RLS 是最后防线，不代替 API 校验；CORS 不是认证机制；service-role key 不进入 PWA 或 iOS。

## 8. 首次同步（未来实现）

默认流程：

1. 用户登录，App 仍保持 Guest/local 模式。
2. 用户主动选择“开启同步”。
3. 客户端扫描本地记录，建立稳定 UUID 映射并生成 dry-run 摘要。
4. 获取 household 云端快照，不立即覆盖本地。
5. 无云端数据时可选择“上传此设备厨房”；有云端数据时显示合并预览。
6. 用户确认后生成 PendingMutations，逐批上传。
7. 下载 change feed，事务性应用，最后推进 cursor。
8. 任一步失败都保留现有本地数据和 pending queue，可重试。

禁止“登录即上传”和“登录即以云端空数据覆盖本地”。

## 9. iOS 边界

Phase 2A-3 已新增独立层：

```text
SyncCoordinator actor (only explicit runOnce)
├── ExpressSyncTransport (existing APIClient)
├── SwiftDataSyncPersistence (independent ModelContext)
│   ├── SyncMetadataRecord
│   ├── PendingMutationRecord
│   └── SyncCursorRecord (per scope)
└── InventorySyncAdapter (POC only)
```

- UI `@MainActor` store 不直接执行网络合并。
- actor 不跨线程传递 `ModelContext` 或 @Model 实例；只传 Sendable DTO/value。
- 一批 change 的业务写入与 cursor 推进必须有可恢复边界。
- cloud version、pending/error 状态没有塞进现有七个业务 @Model。
- feature flag、示例配置和 Release 默认均为 false；App/AuthStore/KitchenStore 没有自动调用点。
- inventory POC 的本地业务变化、metadata 和 pending mutation 使用同一个 context + 单次 save；普通库存 CRUD 未接入。
- 详见 `docs/IOS_SYNC_PHASE2A3.md`。

## 10. PWA 边界

PWA 必须在启用同步前增加独立 metadata store（IndexedDB 优先评估；若继续 localStorage，必须保证事务/容量失败可恢复）。历史记录的 UUID 映射需要持久化，不能使用读取时随机生成。

## 11. Phase 2A-2.5 验证结果与停止点

- development 已部署 migration：`20260713000200_sync_business_foundation.sql`
- pgTAP 对象测试：`sync_business_objects_test.sql`
- Node migration/API 语义测试
- Express sync routes/service/repository/validation/cursor/entities
- 原子 mutation、bootstrap、scope-aware pull RPC
- schema 映射与正式 HTTP contract 文档

已执行：dry-run、development `db push`、远端对象/权限审计、44 项 pgTAP SQL、两用户 RLS、真实 PostgREST RPC、mutation 全矩阵、九类实体代表性 smoke 与本地 Express 三个 endpoint。`supabase test db --linked` 因本机没有 Docker 无法使用，故同一 pgTAP SQL 改经 linked query 在 rollback-only 事务内执行。

未执行：production 部署、iOS/PWA sync client、首次上传、自动同步、Guest merge、冲突 UI。

Phase 2A-3 已完成 disabled-by-default 的 iOS DTO/metadata/pending/cursor、transport/coordinator 和 inventory POC。下一步只有在人工确认后才能进入 Phase 2A-4；仍不得自动上传 Guest 数据或启用 hosted 写入。

## 12. Phase 2B-1：Guest Inventory 合并（新增，本节起）

Phase 2B-1 在不修改本文件第 1–11 节所述任何后端契约、schema 或核心同步语义的前提下，新增一层"用户主动确认后合并"的本地编排：

- 只针对 `inventory_item` 一种 entity，不涉及 shopping/plan/recipe。
- 新增独立开关 `INVENTORY_SYNC_ENABLED`（默认 `NO`，与 `SYNC_ENABLED` 互相独立，互不启用）。
- 合并前生成纯本地、可重新校验（hash）的 `InventoryMergePlan`，用户逐条确认冲突后才允许上传；上传/回滚仍复用既有 `SyncCoordinator` / `InventorySyncAdapter` / `ExpressSyncTransport`，未新增第二套上传客户端，也未新增后端 endpoint。
- 合并状态（`GuestMergeSession`）落在与 `SyncMetadata`/`PendingMutation` 相同的 `@ModelActor` 单一 `ModelContext` 事务边界内，绑定 `(userId, householdId, entityType)`，不会跨用户/跨设备共享。
- 详见 `docs/GUEST_MERGE_PHASE2B.md`（设计与状态机）与 `docs/INVENTORY_MERGE_CONTRACT.md`（匹配规则、上传/回滚契约）。

本阶段（2B-1）仍未执行任何真实 hosted Guest merge；真实测试账号验证留待 Phase 2B-2。

## 13. Phase 2B-3：正式 Guest Merge UI 与手动同步（新增，本节起）

Phase 2B-3 在不新增任何后端 endpoint、不修改任何既有同步语义的前提下，把 Phase 2B-1/2B-2 已验证的合并引擎接入正式 App UI：

- 新增第二个独立开关 `INVENTORY_MERGE_UI_ENABLED`（默认 `NO`）——只控制合并/同步 UI 是否显示，与控制网络能力的 `INVENTORY_SYNC_ENABLED` 完全独立；两者都为默认关闭，缺一不会显示 UI 或获得写入能力。
- `InventoryMergeConflictChoice` 新增第四个选项 `skip`（"稍后处理"）：语义与未处理完全一致（不上传、不覆盖），仅记录用户已看过。
- 新增 `GuestMergeController.syncNow(authStore:householdId:)`——除 `confirmMerge`/`rollback` 外唯一的 `SyncCoordinator.runOnce` 生产调用点，仅由用户主动点击"立即同步库存"触发，作用域仍只限 `inventory_item`。
- 明确决定但本阶段未接入：合并完成后，普通 Inventory CRUD 是否应自动生成 PendingMutation。保守策略已写入 `docs/INVENTORY_SYNC_PHASE2B3.md`，但接入 `KitchenStore` 现有写入路径需要引入 Auth/Sync 依赖，属于更大的架构改动，本阶段刻意推迟。
- App 启动、登录、后台任务、timer 仍不触发任何同步——由 Node 语义护栏测试确认整个文件中 `runOnce` 只出现在 `confirmMerge`/`rollback`/`syncNow` 三处。
- 详见 `docs/INVENTORY_SYNC_PHASE2B3.md`。
