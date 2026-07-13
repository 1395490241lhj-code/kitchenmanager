# Kitchen Manager 账户与同步实施路线图

状态：待产品/安全评审，不是已启动工程
依赖设计：[`AUTH_SYNC_ARCHITECTURE.md`](./AUTH_SYNC_ARCHITECTURE.md)

## Phase 0：决策与契约冻结

- 目标：确认 Supabase、region、成本预算、数据保留政策、Guest-first 和 household ownership。
- 修改范围：ADR、威胁模型、OpenAPI 3.1、JSON Schema、fixtures；不改生产功能。
- 验收：认证供应商与数据归属获得明确批准；PWA/iOS 模型差异表完整；备份政策决定是否升级 v2。
- 风险：未经确认直接建库会锁定供应商和隐私承诺。
- 依赖：无。

## Phase A：后端认证和用户模型

- 目标：Supabase Auth、profiles、households、members；Express 可验证 JWT 并授权 `/api/me`。
- 修改范围：服务端 auth middleware、JWKS cache、数据库 migration、RLS、环境变量文档；不接业务同步。
- 验收：注册自动创建个人 household；无/伪造/过期 token 被拒；用户 A 无法读取 B；Apple/Google 开发环境回调通过。
- 风险：service-role 绕过 RLS、callback 配置、JWT issuer/audience 错误。
- 依赖：Phase 0。

## Phase B：iOS AuthManager 和登录

- 目标：Guest、登录、启动恢复、refresh、登出、Apple 登录。
- 修改范围：Authentication 目录、Keychain TokenStore、AppRootView、APIClient token provider；业务仍使用 Guest store，不同步。
- 验收：token 不进 UserDefaults/日志/备份；401 single-flight refresh；登出不会误删厨房数据；离线启动可进入受控缓存状态。
- 风险：启动状态闪烁、refresh race、多账号 token 串用。
- 依赖：Phase A。

## Phase C：云端业务模型和同步骨架

- 目标：七类云端表、preferences、devices、sync_operations、change cursor。
- 修改范围：SQL migrations、RLS、validator、OpenAPI、`/api/sync/push|pull` 空/fixture 实现。
- 验收：所有表均有 ownership、version、tombstone、sequence；push 幂等；pull 分页稳定；跨用户/非成员访问为零。
- 风险：PWA inventory 无 UUID、recipe overlay 与完整 JSON 语义差异。
- 依赖：Phase A、Phase 0 schema。

## Phase D：单向首次上传

- 目标：iOS Guest 数据 dry-run、preview、幂等上传到空云端。
- 修改范围：Sync metadata/queue、bootstrap API、迁移 UI；不自动下载覆盖本地。
- 验收：八类数据字段/顺序/ID 保持；中断可重试；重复 commit 不重复；失败不标完成、不清本地。
- 风险：大 payload、部分事务、菜谱 source/fingerprint 重复。
- 依赖：B、C。

## Phase E：云端拉取和每账号本地缓存

- 目标：新设备登录可全量 bootstrap；每账号独立 SwiftData container。
- 修改范围：AccountDataCoordinator、账号 store factory、snapshot apply/rollback、登出策略。
- 验收：新手机恢复一致；账号 A/B/Guest 完全隔离；下载校验失败保持旧 store；重登同账号复用缓存。
- 风险：当前 App 在启动时构造 store，需要谨慎调整 root 生命周期。
- 依赖：B、C。

## Phase F：双向增量同步

- 目标：离线写队列、cursor pull、optimistic concurrency、tombstone、冲突 UI。
- 修改范围：每个 Store 的原子业务写 + queue、background/foreground sync、冲突处理。
- 验收：离线数天后收敛；删除不复活；消费 undo 不双扣/双恢复；菜谱冲突不丢版本；服务器时间偏差无影响。
- 风险：跨模块操作原子性、SwiftData context lifecycle、重试风暴。
- 依赖：D、E。

## Phase G：PWA 接入相同身份和同步 API

- 目标：Guest localStorage 保持可用，登录后使用 scoped IndexedDB queue 与同一协议。
- 修改范围：Auth/session、API wrapper、storage adapter、UUID migration、bootstrap/conflict UI、CSP/XSS 加固。
- 验收：同一账号 PWA/iOS 数据一致；退出账号不串数据；PWA 离线仍可编辑；现有 backup 可导入 Guest 后再安全上传。
- 风险：无构建 ES Module 环境的 SDK装载、XSS token 风险、Service Worker 旧资源。
- 依赖：F；PWA 安全审计必须先完成。

## Phase H：Household 共享

- 目标：邀请、角色、切换厨房、成员移除和 owner 转移。
- 修改范围：邀请 API/UI、membership RLS、活动审计、多 household selector。
- 验收：成员只见已加入 household；移除立即失权；最后 owner 删除有明确处理；个人偏好保持个人化。
- 风险：权限提升、邀请泄露、家庭数据删除责任。
- 依赖：A–G 稳定后。

## 测试矩阵

### 后端

- 注册、验证邮件、登录、OAuth callback、refresh rotation、logout/revoke。
- 缺失、过期、错误 issuer/audience、错误签名 JWT。
- A/B 用户和非 household member 的逐表隔离测试。
- 客户端伪造 userID/householdID 不生效。
- push operation idempotency、事务回滚、cursor 分页、tombstone retention。
- AI/API 按匿名/IP/user 配额及多实例共享限流。

### iOS

- Keychain CRUD、保护级别、无 token 日志、access/refresh 生命周期。
- 401 并发只 refresh 一次，失败转 expired 而不删除缓存。
- Guest/账号 A/账号 B 三个容器隔离。
- 首次上传成功、失败、中断、重复和 preview/commit 内容一致。
- 离线新增/编辑/删除、前后台恢复、网络抖动和 App 被杀。
- 各模块冲突：库存数量、购物勾选、计划 cooked、消费 undo、weekly snapshot、recipe fork、preference LWW。
- 清除设备缓存、登出保留缓存、删除账号三个不同操作。

### PWA

- OAuth PKCE state/nonce、token 不进 backup、登出清理。
- localStorage UUID 升级失败不清数据。
- Guest → account preview/merge 和 IndexedDB pending queue。
- 离线 Service Worker 版本下的同步恢复。
- CSP/XSS 回归，尤其动态 `innerHTML` 内容。

### 跨端验收

1. PWA 建库存，iOS 增量拉取。
2. iOS 勾购物项，PWA 收敛。
3. 两端同时改同一库存，出现明确冲突且不丢数量。
4. 一端删除、另一端离线编辑，记录不复活。
5. iOS 新建/编辑用户菜谱，PWA overlay adapter 无损呈现。
6. 收藏/常做在同用户间同步，在不同用户间独立。
7. 换机/卸载后从云端恢复。
8. 账号切换不串数据。

## 每阶段发布门槛

- 所有数据库 migration 可前滚，并有经过演练的回滚/恢复方案。
- 新 API 先有 OpenAPI/JSON Schema 和 authorization tests。
- 同步功能通过 feature flag 灰度；Guest 默认路径不受影响。
- 不删除旧本地数据，直到至少一个稳定版本和用户明确确认。
- 监控只记录 operation ID、entity type、status、latency；禁止 token 和用户 payload。
- 每阶段更新隐私说明、数据导出/删除说明和 `PROJECT_STATUS.md`。
