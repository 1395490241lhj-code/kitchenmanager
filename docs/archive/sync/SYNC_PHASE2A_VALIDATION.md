# Phase 2A-2.5 Development 验证记录

日期：2026-07-13
目标：linked `kitchenmanager-dev`（仅 development；本文不记录 project ref、用户 UUID 或密钥）

## 安全门禁

- `SUPABASE_ENVIRONMENT=development`；linked 项目名称为 `kitchenmanager-dev`。
- `.env.development.local` 与 iOS `Local.xcconfig` 均被 Git ignore 且未跟踪。
- migration dry-run 只包含 `20260713000200_sync_business_foundation.sql`；`00100` 已在远端。
- smoke 仅使用 publishable/anon key 与 User A/User B 的短期 JWT；未使用 service-role。
- 日志和本文不包含 key、JWT、Authorization header、密码、数据库密码或完整用户 UUID。
- 所有 smoke 业务记录使用明确的 Phase 2A 标记，结束后经 mutation RPC 软删除；没有物理删除。

## SQL 审计结论

- 九类实体表具有 UUID id、明确 household/user scope、BIGINT version、actor audit 字段与 tombstone。
- `sync_changes.sequence` 是全局 BIGINT identity；snapshot 与业务 mutation 由 trigger 在同一事务写入。
- `sync_mutations` 以 `(user_id, mutation_id)` 为主键，并保存 canonical request hash 与最小结果元数据。
- 三个公开 RPC 均为固定 `search_path=pg_catalog`，拒绝空 `auth.uid()`；public/anon execute 已撤销，只授予 authenticated。
- mutation RPC 仅从固定 entity/table/column allowlist 选择动态 SQL 标识符，不拼接客户端表名/列名。
- authenticated 对所有业务表无 direct INSERT/UPDATE/DELETE；RLS 只开放必要 SELECT。
- JSON/body/depth/count 限制由 Express validation 执行，SQL 再拒绝非 object、超大 JSON 和未知字段。
- JS 全程把 cursor/sequence/version 作为十进制字符串，避免 BIGINT 进入 `Number`。

## Scope 与 cursor 决策

统一 change sequence 不等于统一 cursor。正式 contract 使用：

```json
{ "scopeType": "household|user", "scopeId": "uuid", "cursor": "decimal-string" }
```

household scope 包含 inventory、shopping、today plan、consumption、weekly plan/item、user recipe；user scope 包含 favorite 与 frequent recipe。bootstrap 为每个可见 household 和当前 user 返回独立 cursor。pull 在应用 cursor 前先过滤单一 scope，因此一个 household 的高 sequence 不会导致 personal 或其他 household 变更被跳过。

## Mutation 事务边界

Express 对最多 100 条 mutation 逐条调用一次 RPC。每个 RPC 是独立数据库事务，并在事务内完成 membership/self-scope 检查、幂等锁与 ledger 检查、baseVersion 比较、业务写入/软删除、trigger version/change snapshot、ledger result。单项 conflict/rejected 不回滚同批此前已 applied 的项；网络失败后用原 mutationId 与完全相同 payload 重试。

## Migration 与对象验证

- `npx supabase db push --linked --dry-run`：只计划 `00200`。
- `npx supabase db push --linked`：成功。
- migration list：local/remote 均包含 `00100`、`00200`。
- linked 对象审计：11 张受保护表、11 条 policy、18 个实体 trigger、3 个 RPC；RLS、grants、签名、search path、scope constraint、ledger PK 和关键 index 均通过。
- `npx supabase test db --linked`：当前 CLI 尝试启动 Docker，而本机没有 Docker，因此标准 runner 未执行。
- 等价执行：同一 `sync_business_objects_test.sql` 在 linked database 的 rollback-only transaction 内临时启用 pgTAP，运行到 `ok 44`，无异常并 rollback。

## 真实 Auth / RLS / RPC 结果

- User A 与 User B 均可 bootstrap 自己的 household/user scopes。
- 双向跨 household pull 被拒绝；User A 向 User B household mutation 被拒绝。
- direct PostgREST DML 被拒绝；body 中伪造 userId/householdId 被 Express validation 拒绝。
- inventory create `baseVersion=0` 返回 version 1；正确 update 返回 version 2；stale update 返回 conflict 和 server version，不产生 change。
- delete 返回 version 3 与最小 tombstone；相同 delete retry 返回 duplicate，不重复增加 version/change。
- 同 mutationId + 完全相同 canonical payload 返回 duplicate；同 ID + 不同 payload 返回 `idempotency_mismatch`；ledger 只有一行。
- feed 对同一实体仅出现 create/update/delete 三条变更，sequence 严格递增，snapshot 与 tombstone 正确。
- limit=1 分页、hasMore、相同 cursor 重试、下一页无重复、空页保持输入 cursor 均通过。
- household 与 personal pull 互不泄漏；跨实体使用同一全局递增 sequence。
- shopping、today plan、consumption、weekly plan + item、user recipe、favorite、frequent recipe 均完成真实 create/change/soft-delete smoke。
- 本地 Express 的 bootstrap/changes/mutations：无 token 401，A/B 200，非成员 403，malformed/伪造字段 400，101 条 batch 413。
- temporary backend failure 503 与 BIGINT 超过 JS safe integer 的字符串 contract 由 Node 模块测试覆盖，未向开发库制造巨型 sequence。

## 可重复命令

加载 ignored development env 后执行：

```bash
npm run verify:sync-db
npx supabase db query --linked --file supabase/tests/sync_business_objects_test.sql
npm start
npm run smoke:sync
node --test --test-reporter=tap test/sync-phase2a-api.test.mjs test/sync-phase2a-rpc-contract.test.mjs test/sync-phase2a-schema.test.mjs
npm test -- --test-reporter=tap
npm audit --omit=dev --audit-level=high
git diff --check
```

`smoke:sync` 会创建 development 标记记录并在 finally 中软删除。若中断，应以同一用户重新运行或人工通过受控 mutation RPC 软删除残留；不得用 service-role/物理 DELETE 做客户端真实性验证。

## 仍未实现

- iOS/PWA SyncEngine、PendingMutation、SyncCursor 本地持久化。
- Guest 数据上传、合并预览、自动/后台同步。
- production migration、Render sync endpoint 部署验证。
- household 邀请、Realtime、tombstone/ledger 后台清理。

因此可以进入 Phase 2A-3 的 **disabled-by-default 客户端同步边界**，但仍不得登录即上传、修改现有 Guest 数据或启用自动同步。
