# Kitchen Manager Phase 0：Supabase 与认证基础设施

状态：后端认证基础设施已实现；PWA/iOS 登录和业务数据同步尚未实现。

真实开发项目的部署、RLS 与两用户端到端验证见
[`AUTH_SYNC_PHASE0_5_VALIDATION.md`](./AUTH_SYNC_PHASE0_5_VALIDATION.md)。该文档会明确区分自动化就绪与真实环境已执行结果。

本轮名称沿用实施任务中的“Phase 0”。原路线图把决策冻结称为 Phase 0、把后端认证称为 Phase A；实现内容仍遵守既定 Guest-first、Supabase Auth/Postgres、Express 验证 JWT、RLS 隔离的架构，没有进入客户端登录或同步阶段。

## 1. 已建立的边界

- Supabase Auth 管理密码、OAuth、session 和 access token；业务表不保存密码。
- Express 通过 Supabase JWKS 验证 access token 的签名、`iss`、`aud`、`exp` 和 UUID `sub`。
- 只有 `GET /api/me` 强制认证。现有 PWA、iOS、本地数据和公开 AI/导入接口保持 Guest 可用。
- `/api/me` 使用 anon/publishable key 加当前用户 JWT 查询 PostgREST，因此 RLS 仍然生效。它不使用 service-role 绕过 RLS。
- `SUPABASE_SERVICE_ROLE_KEY` 预留给未来明确的服务端管理任务；当前 `/api/me` 不读取它。

参考：

- [Supabase JWT/JWKS](https://supabase.com/docs/guides/auth/jwts)
- [Supabase RLS](https://supabase.com/docs/guides/database/postgres/row-level-security)
- [Supabase 用户数据 trigger](https://supabase.com/docs/guides/auth/managing-user-data)
- [Supabase 本地开发](https://supabase.com/docs/guides/local-development)

## 2. 目录

```text
supabase/
├── config.toml
├── migrations/
│   └── 20260713000100_auth_household_foundation.sql
├── seed.sql
└── tests/
    └── auth_household_rls_test.sql
```

迁移创建：

- `profiles`：与 `auth.users(id)` 一对一，保存邮箱和显示名。
- `households`：包含创建人和 `is_personal`；partial unique index 保证每位用户最多一个个人 household。
- `household_members`：以 `(household_id, user_id)` 为主键，角色限制为 `owner/admin/member`。

`auth.users` insert 或 email update trigger 会幂等 upsert profile、“我的厨房”和 owner membership。唯一索引与复合主键保证重试或并发触发不会产生重复个人 household/成员。

## 3. 本地配置

前置条件：Supabase CLI 与 Docker-compatible container runtime。

```bash
cp .env.example .env
supabase start
supabase status
supabase db reset
supabase test db
```

把 `supabase status` 给出的本地 URL 和 anon key 写入本机 `.env`。典型本地 URL 为：

```dotenv
SUPABASE_URL=http://127.0.0.1:54321
SUPABASE_ANON_KEY=<supabase status 输出的本地 anon key>
SUPABASE_JWKS_URL=http://127.0.0.1:54321/auth/v1/.well-known/jwks.json
SUPABASE_JWT_ISSUER=http://127.0.0.1:54321/auth/v1
SUPABASE_JWT_AUDIENCE=authenticated
SUPABASE_SERVICE_ROLE_KEY=<仅本地 Express 使用的 service role key>
```

当前 JWT middleware 要求项目使用 Supabase 的 asymmetric signing key（ES256/RS256），因为 JWKS endpoint 不会暴露旧 HS256 shared secret。不要把 JWT secret 硬编码为替代方案。

## 4. 密钥放置

| 配置 | Express | PWA/iOS 未来可用 | 可提交 |
| --- | --- | --- | --- |
| Supabase URL | 是 | 是 | 仅模板 |
| anon/publishable key | 是 | 是 | 本仓库仍只提交占位符 |
| JWKS URL / issuer / audience | 是 | 公开元数据 | 仅模板 |
| service-role key | 仅服务端 | 绝不允许 | 否 |
| 数据库密码 | 部署/CLI secret | 否 | 否 |

`.gitignore` 忽略 `.env*`，仅允许 `.env.example`。不要把 token、Authorization header、service-role key 放进日志、浏览器存储、iOS bundle 或备份。

## 5. 远程项目与 migration

1. 在 Supabase 创建项目并启用 asymmetric JWT signing key。
2. 在项目 Auth URL 配置中登记未来回调地址；Phase 0 不启用登录 UI。
3. 使用 `supabase link --project-ref <ref>` 连接项目。
4. 先在本地执行 `supabase db reset` 和 `supabase test db`。
5. 审核差异后执行 `supabase db push`。
6. 在 Render 的 server-only 环境变量中配置 `.env.example` 所列 Supabase 项。

不要把 Dashboard 生成的数据库密码或 service-role key写进命令历史、文档或仓库。

## 6. 验证 `/api/me`

启动 Express 后，使用 Supabase Auth 获得的真实 access token：

```bash
curl -i http://127.0.0.1:3000/api/me \
  -H "Authorization: Bearer <access-token>"
```

成功返回当前用户 profile 和其 membership 可见的 households。缺少/错误/过期 token 返回 401；触发器初始化尚未可见时返回可重试的 409；数据库不可用返回不含 SQL/JWKS/密钥细节的 503。客户端提交的 `userId` 不参与授权。

## 7. RLS 策略

- profile：用户只能 select/update 自己。
- household：成员可 select；owner 可改名或删除。
- household members：同 household 成员可 select；只有 owner 可添加/修改成员；owner membership 不允许通过普通 delete policy 删除，避免无 owner household。
- 未认证请求没有任何基础表策略。
- policy 不包含 `using (true)`；membership 查询通过未暴露的 `private` security-definer helper，避免 RLS 自递归。

`supabase/tests/auth_household_rls_test.sql` 验证 A/B profile 隔离、非成员隔离、member/owner 更新权限以及 trigger 幂等性。

## 8. 回滚与恢复

本地开发直接使用 `supabase db reset` 从 migration 重建。已经部署到共享环境后优先前滚修复；不要重写或删除已发布 migration。

若在尚无业务数据、尚无客户端登录的 Phase 0 环境必须完全回滚：先备份数据库，再新增一条 forward migration，按顺序删除 Auth trigger、RLS policies/helper functions、`household_members`、`households`、`profiles`。不要直接手工编辑生产 migration history。进入业务同步阶段后禁止使用这种破坏性回滚。

## 9. 尚未实现

- PWA/iOS 登录、OAuth、Apple/Google UI。
- iOS Keychain token store、refresh、logout 和每账号 SwiftData container。
- 云端厨房业务表、首次 Guest 数据合并、上传/下载、双向同步。
- household 邀请、切换、owner 转移、账号导出/删除。
- 生产 Supabase project/region/回调、Render secrets 和共享限流后端的实际配置。
