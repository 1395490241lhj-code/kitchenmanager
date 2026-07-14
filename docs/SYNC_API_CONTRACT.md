# Phase 2A 同步 API Contract

状态：**Phase 2A-2.5 development 后端已验证；Phase 2A-3 iOS client boundary 已实现但默认禁用**
Schema version：`1`

所有 endpoint 都要求 `Authorization: Bearer <Supabase access token>`。Express 先验证 JWT，再以 publishable/anon key + 同一用户 JWT 调用固定 Supabase RPC。服务端不接受客户端 `userId` 作为身份依据，也不使用 service-role key。

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

单项 status：

- `applied`：业务记录、version、change 和 ledger 在同一事务提交。
- `conflict`：baseVersion 过期；返回当前 serverRecord/version，不写 change。
- `rejected`：字段、创建版本、已删除/不存在或 idempotency payload 不一致。
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

## 6. 稳定 ID

1. 已有 UUID：直接复用。
2. 有稳定 legacy key：以固定 UUIDv5 namespace 对 `scopeType + scopeId + entityType + legacyKey` 生成确定性 UUID。
3. 无稳定 key：首次本地 bootstrap 生成随机 UUID并持久化到独立 SyncMetadata；后续永远复用。

映射不依赖设备名，不记录用户正文。`recipe_favorite`/`frequent_recipe` 的 entity UUID 应以 user scope + recipe ID 生成；recipe ID 本身仍作为业务字段保存。

## 7. 部署与尚未启用

- development 已应用 `20260713000200`，并完成真实 Auth/RLS、RPC、mutation、cursor、实体 mapper 与本地 Express smoke。production 未部署。
- iOS 已有 disabled-by-default 的 DTO、pending queue、per-scope cursor、transport/coordinator 和 inventory POC；没有 App/Auth 自动调用点。
- PWA SyncEngine 与其他 iOS domain adapter。
- Guest bootstrap/merge、冲突 UI、自动或后台同步。
- household 邀请、Realtime。
