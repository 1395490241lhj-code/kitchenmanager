# PROJECT_GUIDE.zh.md — Kitchen Manager 架构与开发约束（权威中文版）

> 本文件是稳定架构和工程约束的权威中文指南。当前状态看 `PROJECT_STATUS.md`，历史看 `CHANGELOG.md` 和 `docs/`，命令级验证看 `TESTING_RULES.md`。英文 `PROJECT_GUIDE.md` 是伴随摘要，不应包含本文件没有的独有规则。

最后重组：2026-07-16。

## 1. 一句话架构

Kitchen Manager 是一个 **Guest-first、Local-first 的双客户端厨房管理产品**：

- Web/PWA 使用原生 HTML、CSS、JavaScript ES Modules、Service Worker 和 `localStorage`；
- 原生 iOS 使用 SwiftUI、SwiftData、Keychain 和 `supabase-swift`；
- Express 提供静态托管、AI/抓取/媒体处理、认证和同步 API；
- Supabase 提供开发环境中的 Auth、Postgres、RLS 和受控同步 RPC。

账号与库存同步已经实现并验证，但默认关闭、尚未全面生产启用。不要把“仓库中存在云代码”误解成“Local-first 已被取消”，也不要把“开发环境验证通过”误写成“生产已上线”。

## 2. 产品闭环

任何改动都必须保护以下主路径：

1. 记录库存或确认小票入库；
2. 查看临期、缺货和可做菜；
3. 加入今日/周计划；
4. 将缺少的核心食材加入买菜清单；
5. 买完后确认入库；
6. 做完后由用户确认扣减；
7. 备份和恢复；
8. 可选登录，但不得伤害 Guest 本地数据；
9. 在明确启用时，预览/确认库存合并、处理冲突、手动同步和受控回滚。

## 3. 仓库分区

### 3.1 Web / PWA

主要入口：

- `index.html`：静态入口和底部导航
- `app.js`：初始化、迁移、数据包、路由和页面组合
- `styles.css`：PWA 视觉系统
- `src/views/*`：页面级渲染和事件绑定
- `src/components/*`：可复用 UI 流程
- `src/*.js`：库存、食材、推荐、购物、常备品、备份、迁移、AI 等领域逻辑
- `src/storage.js`：PWA 持久化唯一通用入口
- `data/*`：只读基础菜谱和补全数据
- `sw*.js` / `manifest.webmanifest`：PWA 缓存和安装

### 3.2 原生 iOS

根目录：`ios-native/Kitchen Manager/`

主要分层：

- SwiftUI View：展示、交互、导航和可访问性
- Store/Controller：业务状态和流程协调
- Business Model：Codable/Hashable、备份和领域语义
- Persistence Record/Protocol：SwiftData 实体、查询、写入和迁移
- Authentication/Networking：会话、Keychain、API 环境和请求
- Synchronization：DTO、元数据、PendingMutation、Cursor、Transport、Coordinator、Adapter、Guest Merge
- XCTest/XCUITest：领域、持久化、迁移、网络、同步和 UI 回归

不要把 SwiftData 实体直接变成所有 UI/备份/网络层共同依赖的万能模型。遵循当前业务模型与持久化记录分离的边界。

### 3.3 Express 服务端

- `server.js`：组合和启动
- `src/server/config.js`：环境配置
- `src/server/auth/*`：JWT/JWKS、身份和 `/api/me`
- `src/server/sync/*`：同步路由、验证、版本门、限流和服务
- `src/server/services/*`：AI、链接、页面、媒体等服务
- `src/server/utils/*`：解析、清洗和通用安全工具

服务端应保持职责分离。不要把完整业务、身份校验和 HTTP 输出堆回一个大路由函数。

### 3.4 Supabase

- `supabase/migrations/*`：数据库结构、RLS、函数和触发器的唯一版本化来源
- `supabase/tests/*`：远端验证或 pgTAP/SQL 证据
- 客户端不得绕过受控 API/RPC 直接写业务表

## 4. PWA 架构约束

### 4.1 路由

当前 Hash 语义稳定：

- `#today`
- `#inventory`
- `#shopping`
- `#recipes`
- `#settings`
- `#recipe:id`
- `#recipe-edit:id`

未经产品确认和兼容计划，不得交换语义、删除旧入口或自行加“猜测式”重定向。

### 4.2 分层

- 视图负责读取状态、渲染 DOM、绑定事件和调用领域函数。
- 组件负责可复用交互流程。
- 领域模块负责匹配、分类、扣减、合并、打分、解析和转换。
- 不要在多个 View 里复制调料分类、库存匹配、缺货计算或购物合并规则。
- 动态字符串进入 `innerHTML` 前必须使用现有转义工具；属性上下文使用属性安全的转义。

### 4.3 存储

- 通用 `localStorage` 访问必须经过 `src/storage.js` 的 `S.load`、`S.save` 和 `S.keys`。
- 不在功能代码中散落裸 `km_*` 字符串。
- 现有 key 和数据形状不可随意改名。
- 破坏性变更必须增加 schema 版本、写迁移并测试旧数据。
- 迁移失败不得清空用户数据。
- 新持久化字段要检查备份、恢复、导入和重置路径。
- 用户菜谱修改只写 Overlay；基础菜谱和补全文件保持只读。

特别注意：购物项加载/归一化可能按固定字段重建对象。增加购物字段时必须同步检查重建块，否则刷新后会静默丢字段。库存加载对未知字段的行为与购物项并不相同，不要类推。

### 4.4 PWA 缓存

- 浏览器导入的 JS/CSS 变更后，按现有脚本统一更新 `?v=` 版本。
- 优先运行 `node scripts/stamp-version.js`，不要手工改几十处版本号。
- 需要真正失效 Service Worker 缓存时，再审查并更新 Cache Name。
- 不要为普通功能改动随意重写缓存策略。

## 5. 原生 iOS 架构约束

### 5.1 SwiftUI

- View 只持有展示状态和调用能力，不保存访问令牌或数据库秘密。
- 通过环境、依赖注入或组合根连接 Store/Controller/Service。
- 业务规则尽量留在纯类型、Store、Controller 或 Service 中，便于 XCTest。
- 处理数组元素 Binding 时按稳定 id 重新解析，避免捕获会失效的数组 index。
- 支持 Dynamic Type、VoiceOver、深浅色、Safe Area 和合理触控区域。

### 5.2 SwiftData

- 使用项目共享的生产/内存 Schema 和工厂，避免测试/生产模型漂移。
- 业务模型与 Record 的映射必须覆盖所有当前字段。
- 迁移要幂等；标记成功前应验证数据；保留旧数据的自愈和显式清除语义。
- 不要因为 SwiftData 表暂时为空就自动破坏性清除旧 JSON。
- 多 `ModelContext` 写入时先审计事务边界和竞争条件。
- 备份契约是否包含某模块必须显式决定，不能因为迁移到 SwiftData 就自动改变备份版本。

### 5.3 认证

- 会话存 Keychain，不存 SwiftData/UserDefaults/日志。
- View 不直接缓存或传播 token 字符串。
- 网络调用在需要时向认证状态读取新 token；登出后后续请求必须失去凭据。
- 登录/登出不得自动清理或上传本地厨房数据。
- 缺少配置或远端失败时，Guest 本地功能继续可用。

## 6. 同步协议约束

同步是高风险协议，不是普通 CRUD 封装。

### 6.1 身份和作用域

- 服务端用户身份来自验证后的 JWT subject。
- 不信任客户端提交的 user id。
- 家庭作用域与用户作用域必须明确分离。
- 所有查询/写入都要验证成员关系和实体类型 allowlist。

### 6.2 写入和冲突

- 客户端写入通过 Express 和受控 RPC，不直接 DML。
- 每个 mutation 必须保留 mutation id、entity id、operation、scope、base version 和合法 payload。
- 幂等重试不能重复应用。
- 版本冲突不能静默覆盖。
- 删除使用 tombstone/soft delete，除非协议明确改变。
- 游标可能超过 JavaScript/Swift 安全整数范围；继续使用当前任意精度字符串语义。

### 6.3 本地队列

- PendingMutation 和 SyncMetadata 的状态转换要原子或具有明确补偿。
- Mutation coalescing 必须保持当前 create/update/delete 语义和真实 remote version。
- 队列上限不能丢 delete，也不能阻止对已排队实体的合法合并。
- 失败不得错误推进 cursor 或删除尚未确认成功的 pending mutation。

### 6.4 Guest Merge

- 先只读预览，再由用户明确确认。
- 匹配、冲突、keepLocal/keepRemote/keepBoth/skip 语义不得自行简化。
- 同 id 的 keepBoth 必须使用稳定 fork id；回滚只能删除本次创建的 fork/实体。
- 计划 hash、远端版本和本地快照要防止预览后数据漂移。
- 回滚成功必须验证每个实体真实进入期望状态，不能只信一次 round-trip 的聚合结果。

### 6.5 启用边界

- 不增加启动、登录、定时、后台、Realtime 或自动同步钩子，除非用户明确要求并批准新的产品/安全设计。
- 所有 sync/merge/smoke/dogfood/diagnostics 开关默认保持安全关闭。
- Hosted Smoke 只使用允许的开发环境、隔离标记和最小权限用户凭据。
- 测试结束恢复本地 flag，清理标记并验证无残留。

## 7. 服务端和数据库安全

- 保持 JWT 的非对称 JWKS 验证、issuer/audience/origin 检查。
- 保持认证 → 角色/成员 → 版本门 → 限流 → handler 的保护顺序。
- 被版本门/限流拒绝的请求不得进入业务 handler 或写入 mutation ledger。
- 限制请求体、批量条数、文本/图片/媒体大小和超时。
- 保持 SSRF 防护、URL 协议/地址检查和重定向审查。
- 错误响应只暴露安全 code/status/retry 信息；不返回 token、Authorization、完整 prompt、base64 图片、数据库秘密或内部堆栈。
- 数据库迁移优先 additive、幂等、可验证；RLS、grant、index、trigger、function 和 rollback/恢复说明一并审查。
- 不在客户端或仓库中使用 service-role key。

## 8. AI 功能约束

- AI 结果一律视为草稿。
- 前后端都使用现有校验、清洗和 JSON 修复边界。
- 小票和菜谱导入必须给用户确认/编辑机会。
- 来源不足时显示不确定性，不补写成完整事实。
- AI 失败时保留文本录入、本地推荐和手工编辑等路径。
- 不把完整厨房数据作为默认背景静默上传。

## 9. UI 与设计原则

### PWA

- 390px 移动端优先，深浅色均可读。
- 复用现有 token 和语义 class，不直接粘贴 Tailwind 原子类。
- 主操作清楚；不要用多层嵌套卡片制造视觉噪音。
- 修改前查看最终生效 CSS，而不是只看文件中较早的旧原型样式。

### iOS

- 使用原生 SwiftUI 组件和平台交互模式。
- 与产品视觉一致，但不为了像网页而牺牲系统可访问性和导航语义。
- 危险操作确认、错误信息、空状态和离线状态必须可理解。

## 10. 依赖和架构变更

### 当前允许的既有技术

- PWA 原生 JS/CSS/HTML
- Node/Express/Axios/JOSE/ffmpeg-static
- Supabase CLI、Auth、Postgres、RLS
- SwiftUI、SwiftData、Keychain、supabase-swift

不要再使用旧规则声称“数据库、登录、云同步或原生 iOS 不存在”。它们已经是现有架构。

### 仍需明确批准的扩张

- PWA 框架/TypeScript/打包器迁移
- 新的重型前端或状态管理库
- 更换 iOS 持久化/认证架构
- 新数据库或绕过现有 Supabase/Express 合约
- 将同步扩张到新实体或启用自动同步
- 改变部署、Service Worker、路由、备份或数据作用域
- 大范围 UI 重设计

添加依赖前说明必要性、替代方案、客户端体积/构建影响、部署影响和测试影响。

## 11. 文档维护

- 当前事实只写入 `PROJECT_STATUS.md`。
- 稳定架构规则写在本文件和 `CODING_RULES.md`。
- 命令和选择矩阵写在 `TESTING_RULES.md`。
- 一次任务流程写在 `PROJECT_WORKFLOW.md`。
- 变更摘要写 `CHANGELOG.md`。
- 详细设计与验证写 `docs/`。
- 不在五个文件中复制同一段 Phase 测试报告。

当代码改变架构或契约时，更新对应权威文档；普通修复不需要机械修改所有文档。
