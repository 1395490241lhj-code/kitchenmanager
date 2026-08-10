# Kitchen Manager / 厨房管理

> Guest-first、Local-first 的家庭厨房管理产品，包含 Web/PWA、原生 iOS、Express 服务端和 Supabase 账号/同步基础。

Kitchen Manager 帮助个人或小家庭管理库存、临期食材、菜谱、今日/周计划和购物清单，并在用户确认后完成入库或烹饪扣减。PWA 与 iOS 的核心本地功能均可在 Guest 模式使用。

账号和库存同步能力已存在，但提交配置中的同步、合并、smoke、dogfood 和 diagnostics 开关默认关闭；当前并非生产启用状态。准确发布姿态见 [`PROJECT_STATUS.md`](PROJECT_STATUS.md)。

## 目录概览

```text
.
├── index.html / app.js / styles.css     # Web/PWA 入口
├── src/                                 # PWA 领域、视图、组件和服务端模块
├── data/                                # 菜谱与来源恢复数据
├── server.js                            # Express 入口
├── supabase/                            # 迁移与数据库验证
├── ios-native/Kitchen Manager/          # SwiftUI / SwiftData 工程
├── test/                                # Node 内置测试
├── scripts/                             # 校验、配置和维护脚本
├── docs/                                # 权威文档、契约、runbook 与历史证据
└── AGENTS.md                            # AI 编码代理唯一入口
```

## 运行 Web / PWA

要求：Node.js 22 或更高版本、npm。

```bash
npm install
npm start
```

默认地址：`http://localhost:3000`。

仅查看静态前端时可使用静态文件服务器；静态模式不提供 Express `/api/*`，AI、抓取、认证和同步能力会明确降级。

## 打开原生 iOS 工程

工程路径：

```text
ios-native/Kitchen Manager/Kitchen Manager.xcodeproj
```

首次配置开发环境：

```bash
npm install
npm run configure:ios-auth
```

真实凭据必须保存在 Git 忽略的本地配置中，不得提交。

## 常用验证

```bash
npm test
npm audit --omit=dev --audit-level=high
npm run validate:recipe-packs
npm run validate:recipe-pack-data
```

认证、同步和数据库命令只应在明确确认的开发环境中运行。iOS 构建、Unit/UI、Hosted Smoke 和按改动选测试的规则见 [`docs/development/TESTING.md`](docs/development/TESTING.md)。

## 数据与隐私

- PWA 通过 `src/storage.js` 与 `S.keys` 访问 `localStorage`。
- iOS 使用 SwiftData 持久化业务数据，使用 Keychain 保存认证会话。
- AI 输出始终是草稿；小票、菜谱和库存变更需要校验与用户确认。
- 用户菜谱写 Overlay，不直接改写基础菜谱数据。
- 备份不得包含 API key、访问令牌或其他秘密。
- 同步写入必须走受控服务端/RPC/RLS 合约。

## 文档入口

- [`docs/README.md`](docs/README.md)：完整文档索引与信息归属规则
- [`PROJECT_STATUS.md`](PROJECT_STATUS.md)：当前 main 状态快照
- [`CHANGELOG.md`](CHANGELOG.md)：已进入 main 的重要变化
- [`docs/product/PRINCIPLES.md`](docs/product/PRINCIPLES.md)：稳定产品原则
- [`docs/architecture/OVERVIEW.md`](docs/architecture/OVERVIEW.md)：稳定架构概览
- [`docs/development/WORKFLOW.md`](docs/development/WORKFLOW.md)：开发与 Agent 增量工作流
- [`AGENTS.md`](AGENTS.md)：AI 编码代理入口

发生冲突时，以实际代码、配置、迁移和测试为准。

## 部署说明

- PWA 可由 GitHub Pages 等静态平台托管。
- Express hosted configuration 主要在仓库外管理；仓库没有完整后端 IaC。
- 开发环境验证不等于生产部署或上线。

## License

MIT
