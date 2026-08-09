# Phase 0.5：Supabase 开发环境部署与认证 Smoke Test

状态（2026-07-13）：专用 Supabase 开发项目已经链接并完成真实验证。远端 migration 与本地版本一致；数据库对象/约束/RLS 静态查询通过；两个真实测试用户的 Auth、初始化 trigger、`/api/me`、双向隔离和 Guest 边界 smoke 连续通过。当前机器没有 Docker，因此本地 `supabase test db` / pgTAP **未执行**；不得把远端只读验证误写成本地 pgTAP 已通过。可选限流饱和检查也未执行。

本阶段只验证 Phase 0 的身份基础设施。它不添加 PWA/iOS 登录 UI、Supabase 客户端 SDK、厨房业务云表或同步。

## 本次收尾验证记录

- Supabase CLI `2.109.1` 已连接明确命名为 `kitchenmanager-dev` 的健康 development 项目；没有重新 login、link、创建用户或 push migration。
- 本地与远端 migration 均为 `20260713000100`，没有未应用 migration。
- `npm run verify:auth-db` 真实通过：3 张身份表全部启用 RLS，3 个预期索引（含 personal household 部分唯一索引）、外键/删除规则、role check、3 个唯一 trigger 和精确 9 条 policy 均匹配 migration；个人 household 与 owner membership 完整性通过。
- `npm run verify:auth-phase0`、`npm run smoke:auth` 与直接执行 `node scripts/auth-smoke.mjs` 均真实通过。两个已有用户的 profile、唯一 personal household、owner membership，以及 A/B 双向隔离均通过；脚本没有创建或删除测试用户。
- 真实 access token 使用 ES256、当前 JWKS `kid`、预期 issuer 和 `authenticated` audience 成功访问 `/api/me`。无 token、损坏 token、body/query userID 伪造均按预期处理；错误 issuer/audience、key rotation 和 JWKS 暂时不可用由隔离单元测试验证，没有破坏真实项目。
- Guest 公共菜谱和现有 API 认证边界通过；检查使用无效输入/请求构造，没有触发成功的付费 AI 任务。
- `npm test -- --test-reporter=tap`：708/708 通过；`xcodebuild test`（iPhone 17 Pro，iOS 27.0 Simulator）：394/394 通过、0 runtime warning。
- 两套菜谱包校验通过；保留已有的 `quick-solo` 样例元数据 warning。`npm audit --omit=dev --audit-level=high`：0 vulnerabilities。`git diff --check` 和密钥精确值/Token 模式扫描通过，`.env.development.local` 已忽略且未跟踪。
- `npx supabase test db`：未执行 pgTAP（本机无 Docker/local Supabase 数据库）。`AUTH_SMOKE_TEST_RATE_LIMIT=true`：未执行，仍是 opt-in 压力验证。
- 尚未实现 PWA/iOS 登录 UI、厨房业务云表、数据上传或双向同步。

## 1. 当前自动化

- `npm run verify:auth-phase0`：核对 migration 的关键安全语义，并访问真实 JWKS，拒绝 HS256/shared-secret 项目。
- `npm run verify:auth-db`：通过已链接开发项目的 Management API 执行只读 SQL，核对表、约束、索引、trigger、精确 policy 集合、RLS 开关和个人 household 完整性。
- `npm run smoke:auth`：以两个真实用户登录，使用 anon key + 用户 access token 验证 Auth trigger、`/api/me`、RLS、JWT/JWKS 和 Guest 边界。
- `npx supabase test db`：运行 `supabase/tests/*.sql`，验证对象、trigger 幂等性与 A/B RLS 隔离。
- `AUTH_SMOKE_TEST_RATE_LIMIT=true npm run smoke:auth`：可选的开发环境限流饱和检查。默认跳过，避免消耗共享环境额度。

所有脚本在失败时返回非零退出码，不输出 access token、密码、anon key 或完整项目引用。远程目标必须显式设置 `SUPABASE_ENVIRONMENT=development`（也接受 `staging/test`），以降低误跑生产项目的风险。

## 2. 创建专用开发项目

1. 在 Supabase Dashboard 创建名称明确包含 `development` 的项目；不要复用未来生产项目。
2. 记录项目 reference、URL、region、migration 版本到团队的受控密码库或运维记录，**不要提交到仓库**。
3. 在 Auth signing keys 中启用/迁移到非对称 signing key。真实 token 的 `alg` 必须是 `ES256` 或 `RS256`，JWKS 必须包含匹配的 `kid`。旧 `HS256` 是阻塞项，不能用共享 JWT secret 绕过。
4. 从 Dashboard 获取公开 anon/publishable key。当前 `/api/me` 不需要 service-role key。

项目级 Supabase CLI 已作为 devDependency 安装，使用 `npx supabase ...`；没有全局依赖，也不会进入生产 dependencies。

## 3. 本地环境文件

创建已被 `.gitignore` 排除的 `.env.development.local`：

```dotenv
SUPABASE_ENVIRONMENT=development
SUPABASE_PROJECT_REF=<development-project-ref>
SUPABASE_URL=https://<development-project-ref>.supabase.co
SUPABASE_ANON_KEY=<development-anon-or-publishable-key>
SUPABASE_JWKS_URL=https://<development-project-ref>.supabase.co/auth/v1/.well-known/jwks.json
SUPABASE_JWT_ISSUER=https://<development-project-ref>.supabase.co/auth/v1
SUPABASE_JWT_AUDIENCE=authenticated
EXPRESS_API_BASE=http://127.0.0.1:3000
TEST_USER_A_EMAIL=<secret>
TEST_USER_A_PASSWORD=<secret>
TEST_USER_B_EMAIL=<secret>
TEST_USER_B_PASSWORD=<secret>
```

Node 18 不会自动加载该文件。仅在当前 shell 导入，完成后关闭 shell：

```bash
set -a
source .env.development.local
set +a
```

不要把 `SUPABASE_ACCESS_TOKEN`、数据库密码或 test-user 密码写入命令参数。Supabase CLI 登录令牌使用官方凭据存储或临时环境变量；不要提交 `.supabase`/`.env` 文件。

## 4. Link、migration 与数据库对象验证

```bash
npx supabase login
npx supabase link --project-ref "$SUPABASE_PROJECT_REF"
npx supabase migration list --linked
npx supabase db push --linked
npx supabase migration list --linked
npx supabase db lint --linked
```

首次 `db push` 后，第二次运行必须报告数据库已是最新状态，不能创建重复 trigger、policy、index 或默认 household。不要仅凭退出码验收；继续执行真实对象检查：

```bash
npm run verify:auth-db
```

本次开发项目验证中，`migration list --linked` 显示本地与远端同为 `20260713000100`，因此没有再次执行 `db push`。只读远端检查确认 3 张基础表均启用 RLS、3 个预期 trigger、9 条精确 policy、必要索引/外键/role 约束，以及每位已初始化用户唯一的个人 household + owner membership。查询只输出计数和验证标记，不输出邮箱、UUID 或密钥。

若本机有 Docker-compatible runtime：

```bash
npx supabase db reset
npx supabase test db
```

`auth_household_objects_test.sql` 检查 3 张表、3 个 RLS 开关、关键索引、唯一 Auth trigger 和 policy 数量；`auth_household_rls_test.sql` 检查 trigger 初始化、重复执行与 A/B 隔离。没有 Docker 时，使用 `npm run verify:auth-db` 进行远端只读对象与完整性验证，并以真实 A/B REST smoke 验证运行时 RLS；完整 pgTAP 仍应在有 Docker 的本机或受控 CI 中补跑。本次 `npx supabase test db` 确实尝试过，但因本地数据库/Docker 不可用而未执行任何 pgTAP case。

## 5. 创建两个真实测试用户

在开发项目 Auth Dashboard 创建并确认两个专用邮箱密码用户。密码只能放在 ignored env/secret manager。

每个用户创建后应满足：

- `profiles.id = auth.users.id`，email 一致；
- 恰好一个 `is_personal = true` 的 household，`created_by` 为该用户；
- 恰好一个 owner membership；
- 重复登录或更新 email 不会产生第二个个人 household。

Smoke 脚本不会通过 service role 创建用户，也不会把 Admin API 当作客户端真实性测试。

## 6. 配置并启动 Express

在已经导入 `.env.development.local` 的同一 shell：

```bash
npm run verify:auth-phase0
npm start
```

另开一个同样导入环境文件的 shell：

```bash
npm run smoke:auth
```

预期成功摘要：

```text
[auth-smoke] real Auth/JWKS: PASS
[auth-smoke] trigger, /api/me, user isolation and RLS: PASS
[auth-smoke] Guest route authentication boundary: PASS
[auth-smoke] rate-limit saturation: SKIP (opt-in)
```

脚本实际验证：

- 无 token 和损坏 token 为 401，响应不泄露 JWT/JWKS 内部原因；
- access token 的 `iss`、`aud`、`alg`、`kid` 与真实 JWKS 一致；
- A/B 的 `/api/me` 各自返回验证后 JWT subject 和可见 household；
- GET body 或 query 伪造另一用户 ID 不能覆盖 JWT subject；
- A 只能读取/更新自己的 profile，不能修改受保护字段；
- A/B 双向均不能读取对方 profile、household 或 members；
- owner 可改名（脚本随即恢复），普通 member 不可改名；
- 唯一 owner 不能删除自己的 membership，也不能把自己降级为 member；
- 临时 member 关系在检查后删除；profile/household 临时文本也会恢复；
- `/api/ai-status` 与公开菜谱可匿名读取；`xhs-extract`、`ai-parse`、`ai-chat` 不返回认证 401。无效输入用于边界检查，不应触发成功的 AI 任务。

脚本异常退出时仍会尽力清空内存中的 token 引用；JavaScript 字符串无法保证物理擦除，因此运行器、shell history 与 CI log 仍必须按 secret 处理。

## 7. 可选限流检查

只在隔离的开发 Express 实例运行：

```bash
AUTH_SMOKE_TEST_RATE_LIMIT=true npm run smoke:auth
```

它最多发出 `AUTH_SMOKE_RATE_LIMIT_REQUEST_CAP`（默认 70）个 A 请求，确认最终 429，再确认 B 的用户+IP bucket 未被 A 消耗。它会占用 A 当前 10 分钟窗口，不能对共享 staging/生产执行。无 token 401 的无异常路径在普通 smoke 中始终检查。

## 8. JWKS rotation 验证

自动单元测试已用两个真实非对称测试 key 验证未知 `kid` 会触发一次远程 JWKS 刷新、旧/新 key 可并存、错误签名被拒绝。真实项目 smoke 验证当前 token 的 `kid` 与 JWKS 匹配。

真实轮换只能在专用开发项目中执行：新增非对称 signing key、等待 JWKS 同时发布新旧 key、获取新 token、再次运行 `npm run smoke:auth`。不要立即撤销仍有有效 session 使用的旧 key。`jose` 远程 JWKS 当前缓存 10 分钟、未知 key refresh cooldown 30 秒，不会无限重试。

## 9. 常见错误

- `Missing required environment variable`：环境文件没有导入当前 shell。
- `Invalid ... URL` 或 `duplicate protocol`：检查环境 URL 是否误写为 `https://https://...`、`rhttps://...`，或含用户名/密码；诊断不会回显原始值。
- `express-reachability`：确认 Express 已启动且 `/api/me` 的无 token 响应为 401。若提示 `EADDRINUSE`，先确认占用端口的是预期的 Kitchen Manager 实例，不要盲目停止未知进程。
- `supabase-sign-in-a` / `supabase-sign-in-b`：对应测试用户凭据或确认状态有问题；脚本只报告阶段和 HTTP 状态，不回显 Supabase 响应正文。
- `jwks` / `api-me` / `rls`：分别定位真实签名配置、受保护接口或数据库隔离阶段，便于在不泄露 token 的情况下排障。
- `Refusing remote verification`：缺少 `SUPABASE_ENVIRONMENT=development`，或正在误指向远程非开发项目。
- `unsupported signing algorithm: HS256`：项目仍使用旧 shared secret；迁移 signing key，不能修改 Express 接受 HS256。
- `profile_initializing`：Auth trigger 尚未生成 profile；检查 migration/trigger，不要由客户端重复创建。
- `account_unavailable`：检查 anon key、PostgREST、RLS 与 Express 环境；对外响应不会包含 SQL 细节。
- owner/member 测试提示使用 fresh users：测试账号已有共享或提权关系；新建干净的开发测试用户。
- 429：等待 10 分钟窗口，或重启隔离的本地 Express；不要通过伪造转发 IP 绕过。

## 10. CI 建议（尚未启用）

当前不直接新增 CI job，因为仓库没有可用的开发 Supabase secrets，而且 live job 会修改临时 profile/household 文本。后续可增加手动触发/受保护分支的 `auth-integration` job，Secrets 仅包含开发 URL、anon key、两个测试账号和密码；不需要 service-role。job 启动 Express，运行 `verify:auth-phase0` 与 `smoke:auth`，默认关闭限流饱和测试。

## 11. 回滚

- 尚未共享使用的纯开发项目：可删除并重建项目，重新 `db push`。
- 已共享的环境：不要改写已发布 migration history；新增 forward migration 修复。
- 在任何回滚前导出 Auth/数据库验证记录。进入业务同步阶段后，不允许删除身份表作为普通回滚。

## 12. 安全检查表

- 仓库、Git diff、日志中没有真实 key/password/token/project reference。
- service-role 不参与 smoke、`/api/me` 或客户端真实性验证。
- 目标明确为 development/staging，禁止误跑 production。
- token/userID 只来自签名验证后的 JWT；body/query 不参与授权。
- CORS 不是认证机制；现有 rate limit 保留。
- 未创建业务云表，未改变 Guest、SwiftData 或备份格式。

Phase 0.5 当前可标记为“开发环境已验证”：远端 migration 一致、只读对象检查、真实两用户 smoke、`/api/me`、双向 RLS 隔离、JWT/JWKS 和 Guest 回归均已通过。剩余验证缺口是 Docker pgTAP 与可选限流饱和测试；它们必须继续明确标为未执行。该结论只覆盖认证基础设施，不代表 PWA/iOS 登录、厨房业务云表或同步已经实现。
