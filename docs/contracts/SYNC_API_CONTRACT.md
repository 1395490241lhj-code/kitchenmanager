# Phase 2A 同步 API Contract

状态：**Phase 2A-2.5 development 后端已验证；Phase 2A-3 iOS client boundary 已实现但默认禁用**
Schema version：`1`

所有 endpoint 都要求 `Authorization: Bearer <Supabase access token>`。Express 先验证 JWT，再以 publishable/anon key + 同一用户 JWT 调用固定 Supabase RPC。服务端不接受客户端 `userId` 作为身份依据，也不使用 service-role key。

> **Phase 2C-1（本节起新增）**：所有 `/api/sync/*` 请求现在还统一携带四个版本
> header（`X-Kitchen-App-Platform`/`X-Kitchen-App-Version`/`X-Kitchen-App-Build`/
> `X-Kitchen-Client-Schema`），并在 `auth → role` 之后新增
> `versionGate → rateLimiter` 两层中间件——默认均不生效（`SYNC_VERSION_ENFORCEMENT_ENABLED`
> 默认 `false`；rate limiter 无独立开关，只有阈值可配置）。详见
> `docs/MINIMUM_APP_VERSION_ENFORCEMENT.md` 与 `docs/SYNC_API_RATE_LIMITING.md`。

## 1. 通用约定

- JSON 字段使用 camelCase；repository 在调用 RPC 前映射为数据库 snake_case。
- UUID 使用小写标准格式。
- cursor、sequence、返回的 version 使用十进制字符串，避免 JavaScript `Number` 精度损失。
- 请求 `baseVersion` 可使用非负安全整数或十进制字符串；服务端统一规范化成字符串后传给 BIGINT RPC。
- 最大 mutation batch：100。
- 最大 pull limit：100。
- 最大 sync request body：1 MiB；超限返回 HTTP 413。
- 单实体 recipe/snapshot JSON 最大 256 KiB，最多 6 层嵌套。
- 错误不返回 SQL、Supabase 上游 body、token 或 Authorization header。

## 2. Bootstrap

`GET /api/sync/bootstrap`

```json
{
  "schemaVersion": 1,
  "user": { "id": "uuid", "email": "user@example.com" },
  "households": [{ "id": "uuid", "role": "owner" }],
  "defaultHouseholdId": "uuid",
  "syncScopes": [
    { "type": "household", "id": "uuid", "cursor": "1234" },
    { "type": "user", "id": "uuid", "cursor": "1235" }
  ],
  "serverTime": "2026-07-13T12:00:00.000Z",
  "capabilities": { "push": true, "pull": true, "maxBatchSize": 100 }
}
```

不返回其他成员邮箱、业务快照、token、项目配置或 secret。默认 household 优先选择 personal household。

## 3. Pull

`GET /api/sync/changes?scopeType=household&scopeId=<uuid>&cursor=<decimal>&limit=100&entityTypes=inventory_item,user_recipe`

每次 pull 只允许一个明确 scope：household scope 包含库存、买菜、今日计划、消耗、周菜单及家庭菜谱；user scope 只包含收藏和常做。全局 sequence 只负责排序，客户端必须按每个 `scopeType + scopeId` 独立保存 cursor。

`entityTypes` 可省略；允许值：

```text
inventory_item
shopping_item
today_plan
consumption_record
weekly_meal_plan
weekly_meal_plan_item
user_recipe
recipe_favorite
frequent_recipe
```

响应：

```json
{
  "scopeType": "household",
  "scopeId": "uuid",
  "cursor": "1234",
  "hasMore": false,
  "changes": [{
    "sequence": "1234",
    "entityType": "inventory_item",
    "entityId": "uuid",
    "operation": "upsert",
    "version": "4",
    "changedAt": "2026-07-13T12:00:00.000Z",
    "data": { "id": "uuid", "name": "鸡蛋", "version": "4" }
  }]
}
```

规则：

- SQL 使用 `sequence > cursor ORDER BY sequence ASC LIMIT limit + 1`。
- `cursor` 是最后一条实际返回的 sequence；空页保持请求 cursor。
- tombstone 的 data 仅含 `id`、`deletedAt`、`version`。
- upsert data 来自 change trigger 同事务保存的 snapshot，不会把较早 sequence 错配成实体的最新版本。
- household scope 必须由当前 JWT 用户的 membership 验证；user scope 的 `scopeId` 必须等于 JWT subject。
- SQL 先按单一 scope 过滤，再执行 `sequence > cursor` 与分页；读取某个 household 永远不会推进 personal 或另一 household 的 cursor。

## 4. Mutations

`POST /api/sync/mutations`

```json
{
  "scopeType": "household",
  "scopeId": "uuid",
  "mutations": [{
    "mutationId": "uuid",
    "entityType": "inventory_item",
    "entityId": "uuid",
    "operation": "upsert",
    "baseVersion": "2",
    "clientUpdatedAt": "2026-07-13T12:00:00.000Z",
    "data": {
      "name": "鸡蛋",
      "normalizedName": "鸡蛋",
      "quantity": 6,
      "unit": "个"
    }
  }]
}
```

响应：

```json
{
  "results": [{
    "mutationId": "uuid",
    "entityId": "uuid",
    "status": "applied",
    "version": "3",
    "sequence": "456",
    "serverRecord": {}
  }],
  "cursor": "456"
}
```

### 4.1 upsert 是 PATCH，不是整行替换

`data` 里**实际出现的字段才会被写入**。这是 `20260827000100_sync_mutation_patch_semantics`
定义的语义，适用于**每一个** entity type，不只是 `inventory_item`。

| payload 中的写法 | 含义 |
| --- | --- |
| 字段缺席（key 不存在） | **保持数据库当前值不变** |
| 字段为显式 `null` | **清除该字段**（列必须 nullable，否则 `rejected/invalid_payload`） |
| 字段为具体值 | 写入该值 |

推论，客户端必须据此实现：

- 缺席与 `null` 是两条**不同**的指令，不能互相替代。要清空一个字段必须显式发 `null`。
- 客户端**不需要**了解全部列。一个只认识部分字段的客户端做 upsert，不会影响它没发送的列——
  这正是 iOS 与 PWA 能共用 `inventory_items` 而互不破坏的前提。
  **唯一的规范性例外见 §4.2**：把 `isStaple` 与 `preparationKind` 投影成单一本地分类模型的
  客户端，在改变该分类时必须同时发送两个字段。
- **服务端默认值只在 create 时应用。** update 不会把没发送的字段回灌成默认值，
  因此一次 iOS upsert 不再把 `is_frozen` 重置为 `false`、把 `cooked_count` 重置为 `0`。
- **required 字段的"必须存在"只约束 create。** update 可以完全不发 `name`，
  已存储的值保持不变；但只要发了，值就必须合法——`null` 或空白字符串一律 `400 missing_field`。
  create 判定与 `invalid_create_version` 同一条件：`baseVersion` 为 `0` 或 `null`。
- 对**已存在**的记录发出 `data` 为 `{}` 的 upsert，返回 `rejected` + `errorCode: "empty_update"`，
  不会写入任何列。
- 未在 entity 白名单内的字段仍然是 `400 unknown_field`，白名单本身未放宽。

`request_hash`（idempotency 键的载荷部分）覆盖的是**客户端实际发送并通过校验的 payload**，
不含服务端补出的默认值。因此调整某个字段的默认值，不会改变客户端已经暂存的 mutation 的 hash；
JSON key 顺序也不影响 hash（服务端按字段定义顺序规范化，Postgres 侧 `jsonb` 再次规范化）。

> [!warning] 一次性的 idempotency 断裂
> 该 hash 定义与旧函数不同。旧函数记录在 `sync_mutations` 里的 mutation 若在迁移后被重放，
> 会得到 `idempotency_mismatch`。
>
> 安全条件是「sync 关闭，**且 ledger 中不存在仍可能由客户端重放的旧 mutation**」——
> **不是**「ledger 必须为空」。历史遗留的惰性 smoke/test ledger 记录可以存在：它们的
> `mutationId` 每次运行都是新生成的，没有任何客户端会重发，因此跨迁移边界不受影响。
> 需要防的只有一种情况——某个客户端仍持有一条已进入 ledger、但它尚未记录到结果的
> pending mutation，并在迁移后按原 `mutationId` 重试。这种记录只可能由启用过 sync 的
> 客户端产生，且**无法从服务端观测**（pending 队列是设备本地状态），所以判断依据是
> 「是否曾有客户端在该环境启用过 sync」，而不是 ledger 的行数。
>
> 无论哪种情况，该迁移**必须在启用 sync 之前完成**。

### 4.2 inventory `preparationKind`（P2 preparation axis）

`20260828000100_inventory_preparation_kind` 为 `inventory_items` 增加 ready-to-cook
preparation 轴（iOS `InventoryItemKind.readyToCook` 的 sync 表达）：

| 层 | 定义 |
| --- | --- |
| DB 列 | `preparation_kind text not null default 'none'`，CHECK `('none','readyToCook')` |
| wire 字段 | `preparationKind`，枚举 `none \| readyToCook`（`readyToCook` 与 Swift rawValue 逐字一致） |
| create 缺席 | RPC `default_data` 落 `'none'` |
| update 缺席 | 保持存储值不变（§4.1 PATCH 规则，未改动） |
| 显式 `null` | **拒绝**（列非 nullable；`none` 是唯一的"无 preparation"值） |
| 词表外值 | 拒绝（Express `invalid_field` / DB CHECK `invalid_payload`） |

所有权边界不变：

- `inventory_items.kind` 完全属于 PWA 的 `raw/dry/staple` 语义，本轮未修改、未重释；
- `is_staple` 仍是 staple 轴的 canonical sync 表达；
- `preparationKind` 是与二者正交的第三列，不是三值 `ordinary/staple/readyToCook` 枚举。

`isStaple=true` 且 `preparationKind='readyToCook'` 是**合法的** wire/存储组合——
故意不加 cross-axis CHECK：PATCH 允许一次只动一个轴，数据库若按客户端看不见的
存储状态拒绝这种 sparse update，会把合法请求变成不可诊断的 `invalid_payload`。
把组合态解析回单一分类是客户端 decode 的职责，precedence 为
`staple > readyToCook > ordinary`（P3 实现）。

**Paired-write 规则（规范性）**：任何把 `isStaple` + `preparationKind` 投影为单一本地
分类模型的客户端，在**改变该分类**时，必须从同一份本地 snapshot **同时发送两个字段**，
按此规范化映射：

```text
ordinary    -> isStaple=false, preparationKind=none
staple      -> isStaple=true,  preparationKind=none
readyToCook -> isStaple=false, preparationKind=readyToCook
```

只修改 quantity / expiry / note 等无关字段的 mutation 仍然是普通 sparse PATCH，
**不**要求携带这两个分类字段。完全不知道 `preparationKind` 的客户端（如当前 PWA）
继续只写自己认识的字段：§4.1 的 PATCH 语义保证它们的写入不会清掉 preparation 状态。

单项 status：

- `applied`：业务记录、version、change 和 ledger 在同一事务提交。
- `conflict`：baseVersion 过期；返回当前 serverRecord/version，不写 change。
- `rejected`：字段、创建版本、已删除/不存在、空 update（`empty_update`）或 idempotency payload 不一致。
- `duplicate`：相同用户、mutationId、canonical payload 已处理；不再次写业务记录/change。返回原 status、version、sequence 的最小元数据，不重复保存完整业务正文。

创建要求 baseVersion 为 `0` 或 `null`；更新/删除必须与当前 version 完全相同。delete 不接受 data，写 `deleted_at`，不执行物理 DELETE。恢复墓碑是一条基于当前 tombstone version 的 upsert。

每条 mutation 单独调用一个原子 RPC，因此同批 applied/conflict 可混合。若中途网络失败，之前的项可能已提交；客户端使用原 mutationId 重试整批即可安全收敛。

mutation 响应的 `cursor` 只是本批 applied/duplicate 结果中的最大 sequence（没有 change 时为 `"0"`），不能替代客户端已成功应用的 pull cursor；客户端只有完整应用 pull page 后才能推进持久化 cursor。

## 5. HTTP 状态

| 情况 | HTTP |
| --- | --- |
| 请求/query/body 格式无效 | 400 |
| batch/body/entity payload 超限 | 413 |
| 缺失/无效登录凭证 | 401 |
| 无权访问指定 household/user scope | 403 |
| 单条 conflict/rejected/duplicate | 200，见单项 status |
| Supabase/RPC 暂时不可用 | 503 |
| 客户端版本低于配置的最低要求，或版本 header 缺失/格式错误（enforcement 开启时） | 426，`{"error":"client_upgrade_required","code":"CLIENT_UPGRADE_REQUIRED","message":"...","minimumVersion":"x.y.z","minimumBuild":n}` |
| enforcement 已开启但最低版本配置本身缺失/格式错误 | 503，`{"error":"sync_version_enforcement_misconfigured","code":"SYNC_VERSION_ENFORCEMENT_MISCONFIGURED","message":"..."}` |
| 超出 rate limit（按 JWT subject + route/scope 计） | 429，`{"error":"rate_limited","code":"SYNC_RATE_LIMITED","message":"...","retryAfterSeconds":n}`，附 `Retry-After` header |

426/429/503（版本相关）均在到达 handler 之前被拒绝，因此永远不会写入
`sync_mutations` ledger 或 change feed。

## 6. 稳定 ID

1. 已有 UUID：直接复用。
2. 有稳定 legacy key：以固定 UUIDv5 namespace 对 `scopeType + scopeId + entityType + legacyKey` 生成确定性 UUID。
3. 无稳定 key：首次本地 bootstrap 生成随机 UUID并持久化到独立 SyncMetadata；后续永远复用。

映射不依赖设备名，不记录用户正文。`recipe_favorite`/`frequent_recipe` 的 entity UUID 应以 user scope + recipe ID 生成；recipe ID 本身仍作为业务字段保存。

## 7. 部署与尚未启用

- development 已应用 `20260713000200` 与 `20260827000100`（§4.1 的 PATCH 语义已在
  hosted development 运行），并完成真实 Auth/RLS、RPC、mutation、cursor、实体 mapper
  与本地 Express smoke。尚不存在独立的 production Supabase project，因此这些迁移只
  落在 hosted development；inventory sync 也**未 production-enabled**，从未发生过
  production sync rollout。
- `20260828000100_inventory_preparation_kind`（§4.2）**已 apply 到 hosted
  development**：hosted migration history 现为 5/5，§4.2 的列、CHECK 词表、RPC
  allowlist 与 create default 均已通过 remote verifier。配套的 Express 侧
  `entities.js` `preparationKind` 定义已随 `afe1035` 在 Render 收敛——即 Render 上
  运行的服务端**确实**已具备该契约能力。同一句话不要读成「production 已上线」：
  尚不存在独立的 production Supabase project，且 inventory sync **未
  production-enabled**，从未发生过 production sync rollout。

  该 migration 与 Express 定义是一对且顺序敏感——必须先 migration（列 + RPC 原子
  落地）、再部署 Express。**该顺序在本次 rollout 中已被满足**，以下仍记录其原因：
  新 Express 对旧 RPC 发送 `preparation_kind` 会触发 `unsupported fields` raise，
  整个 HTTP 请求以 503 失败（batch 逐条独立提交，raise 之前的条目可能已经生效；
  按原 mutationId 重试仍然 idempotency-安全，但该条 mutation 在 RPC 更新前会一直
  失败）；旧 Express 对新 schema 则会在 pull 映射中静默丢弃该列。任何未来重放该
  rollout 的环境仍须遵守同一顺序。
- 客户端侧的 §4.2 round-trip（decode precedence `staple > readyToCook >
  ordinary`、paired-write、merge 分类比较）已随 `8132ae5` 进入 canonical `main`。
  该 commit 只含 iOS 代码、iOS/静态测试与 `INVENTORY_MERGE_CONTRACT.md`，**没有任何
  server / schema / PWA 改动**，因此 Render 的 `renderCommit` 是否已前进到该 commit
  与本契约无关，也不是它的 gate。
- **以上都不代表 sync 已 production-enabled。** 所有 committed configuration 中的
  sync / merge / smoke / dogfood / diagnostics flag 仍然全部是 `NO`；数据库与服务端
  具备该能力，但没有任何客户端路径会走到它。

  两个先后记录在这里的 production-runtime blocker 现均已关闭：

  - **R1 / R1b** —— remote hydration 写入 SwiftData 后 `KitchenStore.inventory` 不
    reload，下一次本地 `replaceInventory` 用 stale in-memory 状态覆盖刚同步下来的行。
    **production / controller runtime fixed and clean-tree validated**（`21bd030`）：
    一致性窗口在操作的第一次 durable 写之前打开、退出时 reconcile，`didSet` 路径改为
    row-scoped diff，编辑在窗口开启期间被 `KitchenStore` 中央拒绝。
  - **R3** —— Guest merge 的 `rollback` 会物理删除用户自己的本地 guest
    `InventoryRecord`（`createdEntityIds` 对 `create` candidate 记录的是本地条目自身
    的 id）。**production-runtime rollback blocker fixed, clean-tree validated,
    integrated to canonical main at `fadd26e`**：rollback 改走 remote-only 的
    staging 路径，本地 durable 行一律保留；tombstone 后的本地编辑不得复活远端行；
    歧义失败的重试保留原 `mutationId` 以借服务端幂等 ledger 收敛。客户端侧的语义
    细化记录在 `INVENTORY_MERGE_CONTRACT.md` 的 Rollback 节；本契约的 §1–§6 未因此
    改变。

  因此：**no known production-runtime inventory-sync HARD BLOCKER remains。**

  > [!warning] 这不是启用许可
  > **inventory sync is NOT production-enabled**；**dogfood has NOT been enabled**；
  > **all sync / merge / smoke / dogfood / diagnostics flags remain `NO`**；启用之前
  > 仍然需要一道**独立的 pre-dogfood enablement gate**。该 gate 之前已知的前置项至少
  > 包括：`GuestMergeSmoke` 中绕过一致性窗口的 direct-call caveat（DEBUG-only、
  > 当前不可达，但若用作 dogfood 验收 harness 则必须先修）、以及一份正式的
  > pre-dogfood enablement checklist。
  >
  > 其余已知 follow-up（remote staple hydration 的 `tracksExpiry` 不变量、rollback
  > 不撤销 `InventorySyncEnrollment`、rollback 重试 requeue 的 two-commit crash
  > window、`PreparedComponent` 的持久化 bug）**都不是** production-runtime hard
  > blocker，不要在本节被读成 enablement 的门。
- iOS 已有 disabled-by-default 的 DTO、pending queue、per-scope cursor、transport/coordinator 和 inventory POC；没有 App/Auth 自动调用点。
- PWA SyncEngine 与其他 iOS domain adapter。
- Guest bootstrap/merge、冲突 UI、自动或后台同步。
- household 邀请、Realtime。
