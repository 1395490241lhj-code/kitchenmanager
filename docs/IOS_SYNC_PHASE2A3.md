# iOS Sync Phase 2A-3

状态：**基础设施已实现，默认 disabled；没有自动网络或 Guest 数据副作用**
日期：2026-07-13

## 实现边界

本阶段在原生 iOS target 中增加了可测试的同步边界：

- 与 `docs/SYNC_API_CONTRACT.md` 对齐的 Codable DTO。
- 任意精度十进制字符串 `SyncCursorValue`，不经过 `Int`/`Int64`。
- 独立 SwiftData `SyncMetadataRecord`、`PendingMutationRecord`、`SyncCursorRecord`。
- 使用现有 `APIClient` 的 `ExpressSyncTransport`。
- 仅能被显式调用一次的 actor `SyncCoordinator.runOnce(authentication:)`。
- inventory-only proof-of-concept adapter。

没有修改 `AuthStore`、现有库存写入入口或 SwiftUI 启动流程。没有 timer、后台任务、Realtime、登录事件订阅或自动调用点。

## 默认关闭

`Config/Shared.xcconfig` 和 `Config/Local.example.xcconfig` 都设置：

```text
SYNC_ENABLED = NO
```

Info.plist 将其注入 `KM_SYNC_ENABLED`。配置缺失、`NO` 或无法识别时均为 false。开关不在正式 UI 中展示，也不能由 bootstrap 响应开启。

disabled coordinator 在读取持久化或调用 transport 前返回 `.disabled`。启用测试配置但未认证时返回 `.paused(.notAuthenticated)`，同样不发请求。

## 本地数据模型

### SyncMetadata

唯一键为 `entityType + entityId`。当前后端每种实体表的 UUID 是主键，实体不会在 scope 间移动，因此 scope 作为校验/归属字段保存而不进入唯一键。

保存 remote version、scope、状态、同步/错误/删除时间；不保存完整 server record、JWT 或 Authorization。较旧 remote version 不得覆盖较新 metadata。删除 metadata 不删除业务实体。

### PendingMutation

每条 mutation 首次创建 UUID 后永久复用。队列按 `createdAt + mutationId` 稳定排序；pending、失败或进程中断留下的 in-flight 项可在次数上限内重试。只有 `applied`/`duplicate` 删除；`conflict`/`rejected` 保留并标记。payload 是受控 Codable JSON `Data`，不含 token。

### SyncCursor

唯一键为 `scopeType + scopeId`，household A、household B 和 user cursor 完全独立。只接受规范化非负十进制字符串；拒绝负数、小数、科学计数法、空值和前导零。相同值幂等，回退报错。

## Inventory POC 与事务

`InventorySyncAdapter` 的 staging 方法仅供专项测试/未来显式接入：

- create/update/delete 在同一个独立 ModelContext 中写业务记录、metadata 和 pending mutation，并只调用一次 `save()`。
- save 失败立即 `rollback()`，三类记录都不落盘。
- remote upsert/tombstone 与 metadata 也在一个 save 边界中应用。
- duplicate/stale remote version 幂等忽略。
- 本地 pending 优先；遇到云端 change 时记录 conflict，不覆盖本地库存。

当前 `KitchenStore` 的常规库存 CRUD 没有调用 adapter，因此 Guest 新增/编辑/删除不会创建 pending mutation。

## Coordinator 顺序

显式 `runOnce` 的测试路径为：feature flag → authentication context → bootstrap → 逐 scope push pending → pull inventory changes → 完整应用 page → 推进该 scope cursor。

- push response 的 cursor 不用于替代 pull cursor。
- transport 失败保留相同 mutationId 并增加 attemptCount。
- conflict/rejected 不被清理。
- 任意 change 应用失败时不推进该 page cursor。
- 同一 coordinator 拒绝并发重入。
- 401/403/409/413/503 映射为明确 `SyncError`。

## 安全与 Guest 边界

- transport 每次请求临时向 token provider 取 access token；不持久化副本，不自行刷新。
- `APIClient` 仍只记录 method/path/status，不打印 headers/body。
- committed 配置没有 publishable key、service-role key、token 或密码。
- 登录不扫描、不上传、不重新归属 Guest 数据；退出不删除本地业务数据或 sync metadata。
- 本阶段测试全部使用 MockURLProtocol/MockSyncTransport，不访问 Render 或 hosted Supabase。

## 尚未实现

- 自动同步、登录后同步、App 启动同步或后台同步。
- Guest merge/bootstrap 和用户确认 UI。
- shopping/plan/consumption/weekly-plan/recipe/preference adapters。
- 冲突解决 UI。
- production migration、hosted 写入验证、Realtime、household 邀请。

进入下一阶段前，仍需人工确认何时、如何显式启用首次同步及 Guest merge 预览。
