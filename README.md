# Kitchen Manager / 厨房管理

> Guest-first、Local-first 的家庭厨房管理产品，包含 Web/PWA、原生 iOS、Express 服务端和 Supabase 账号/同步基础设施。

## 项目现状

Kitchen Manager 已不再只是一个浏览器原型。当前仓库包含四个彼此协作、但可独立退化的部分：

| 部分 | 当前技术 | 当前角色 |
| --- | --- | --- |
| Web / PWA | 原生 HTML、CSS、JavaScript ES Modules、Service Worker、`localStorage` | 可独立使用的本地优先厨房应用；也是静态部署版本 |
| 原生 iOS | SwiftUI、SwiftData、Keychain、官方 `supabase-swift` | 原生移动客户端；本地厨房功能完整度持续提高 |
| Express 服务端 | Node.js、Express、Axios、JOSE | 静态托管、AI/链接处理、认证探针和同步 API |
| Supabase | Auth、Postgres、RLS、迁移、受控 RPC | 开发环境中的账号、家庭作用域和增量同步基础 |

**重要状态：** PWA 和 iOS 的本地功能可以在 Guest 模式下使用。账号和库存同步能力已经完成开发环境、模拟器和真机验证，但相关同步/合并/诊断开关在仓库默认配置中仍为 `NO`；它们不是已经全面上线的生产功能。当前工程判断是“Production Go Candidate with conditions”，不是“Production Enabled”。详见 `PROJECT_STATUS.md` 和 `docs/PRODUCTION_ENABLEMENT_READINESS.md`。

## 核心产品能力

- 食材库存、临期状态和常备品管理
- 今日计划、周计划、菜谱浏览与编辑
- 根据库存生成可做/差少量食材的推荐
- 缺货食材进入购物清单，购买后确认入库
- 做菜后由用户确认库存扣减
- 小票识别、菜谱草稿和链接/文本导入
- 本地备份、恢复和用户菜谱 Overlay
- 原生 iOS 本地持久化、账号登录和受控库存同步基础

Kitchen Manager 不是企业库存 ERP。产品应保持低摩擦、可信、移动端优先，并优先保护“库存 → 推荐/计划 → 买菜 → 做菜 → 更新库存”闭环。

## 目录概览

```text
.
├── index.html / app.js / styles.css     # Web/PWA 入口
├── src/                                 # PWA 领域、视图、组件与服务端模块
├── data/                                # 菜谱库和补全数据
├── server.js                            # Express 入口
├── supabase/                            # 数据库迁移、配置与数据库验证
├── ios-native/Kitchen Manager/          # 原生 SwiftUI 工程
├── test/                                # Node 内置测试运行器测试
├── scripts/                             # 校验、配置、Smoke 与维护脚本
├── docs/                                # 架构、阶段、验证和生产准备文档
└── AGENTS.md                            # 所有 AI 编码代理的唯一总入口
```

## 运行 Web / PWA

要求：Node.js 18 或更高版本、npm。

```bash
npm install
npm start
```

默认访问：`http://localhost:3000`

`npm start` 使用 Express 提供静态文件和 `/api/*` 能力。仅查看静态前端时，也可以使用：

```bash
python -m http.server 8000
```

纯静态模式没有 Express API；AI、抓取、认证和同步相关能力必须明确降级，不能假装可用。

## 打开原生 iOS 工程

工程路径：

```text
ios-native/Kitchen Manager/Kitchen Manager.xcodeproj
```

首次配置开发环境时：

```bash
npm install
npm run configure:ios-auth
```

该命令只负责本地配置辅助。真实凭据必须保存在被 Git 忽略的本地配置中，不能提交到仓库。

## 常用验证命令

```bash
npm test
npm audit --omit=dev --audit-level=high
npm run validate:recipe-packs
npm run validate:recipe-pack-data
```

认证和同步相关命令只应在明确连接到允许使用的开发环境时运行：

```bash
npm run verify:auth-phase0
npm run verify:auth-db
npm run smoke:auth
npm run verify:sync-db
npm run smoke:sync
```

原生 iOS 的构建、Unit/UI 测试和 Hosted Smoke 规则见 `TESTING_RULES.md`。不要只因为 `npm test` 通过就声称整个双客户端项目已完成全量回归。

## 数据与隐私边界

- Guest 模式下，厨房数据优先保存在当前设备。
- PWA 通过 `src/storage.js` 和 `S.keys` 访问 `localStorage`。
- iOS 通过 SwiftData 持久化厨房业务记录，通过 Keychain 保存认证会话。
- AI 输出始终是草稿；小票、菜谱和库存变更必须经过校验与用户确认。
- 用户菜谱编辑写入 Overlay，不直接改写基础菜谱数据。
- 备份默认不得包含 API Key、访问令牌或其他秘密。
- 同步写入必须走受控服务端/RPC 合约，不允许客户端绕过 RLS 直接写业务表。

## 文档入口

- `AGENTS.md`：AI 代理总入口和按任务阅读路由
- `PROJECT_STATUS.md`：唯一的当前项目状态快照
- `PROJECT_GUIDE.zh.md`：详细、权威的中文架构与约束指南
- `PROJECT_GUIDE.md`：英文伴随版，不承载独有规则
- `CODING_RULES.md`：跨 PWA、iOS、Server、Sync 的编码规则
- `TESTING_RULES.md`：按改动类型选择验证的方法
- `PROJECT_WORKFLOW.md`：一次开发任务从检查到交付的流程
- `AI_CONTEXT.md`：稳定的产品语境和 AI 决策边界
- `CHANGELOG.md`：历史变更摘要
- `docs/`：专题设计、阶段记录、验证证据和生产准备材料

发生冲突时，以实际代码、配置、迁移和测试为准；不要依赖聊天记忆替代仓库事实。

## 部署说明

- 静态 PWA 可由 GitHub Pages 等静态平台托管。
- Express 后端当前部署流程主要在托管平台外部配置，仓库内没有完整的后端 Infrastructure-as-Code。
- 当前开发与“production”配置仍存在环境隔离不足等发布条件；不得把开发环境验证描述为正式生产上线。

## License

MIT
