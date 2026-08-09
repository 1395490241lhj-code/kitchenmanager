# 文档索引与治理规则

仓库事实优先于文档。当前状态、稳定规则、长期契约和历史证据必须分开维护。

## 当前权威文档

- 当前状态：[`PROJECT_STATUS.md`](../PROJECT_STATUS.md)
- 已进入 main 的重要变化：[`CHANGELOG.md`](../CHANGELOG.md)
- Agent 入口：[`AGENTS.md`](../AGENTS.md)
- 产品原则：[`product/PRINCIPLES.md`](product/PRINCIPLES.md)
- 架构概览：[`architecture/OVERVIEW.md`](architecture/OVERVIEW.md)
- 开发工作流：[`development/WORKFLOW.md`](development/WORKFLOW.md)
- 编码规则：[`development/CODING.md`](development/CODING.md)
- 测试规则与命令：[`development/TESTING.md`](development/TESTING.md)

## Focused docs

### Product

- [`product/PRINCIPLES.md`](product/PRINCIPLES.md)：稳定产品原则、信任与 AI 边界。
- [`IOS_HOME_DASHBOARD.md`](IOS_HOME_DASHBOARD.md)：Home 产品决策。
- [`IOS_RECIPE_COOKING_MODE.md`](IOS_RECIPE_COOKING_MODE.md)：Cooking Mode 行为边界。
- [`IOS_SHARE_IMPORT.md`](IOS_SHARE_IMPORT.md)：分享导入范围与限制。

### Architecture

- [`architecture/OVERVIEW.md`](architecture/OVERVIEW.md)：跨客户端与服务端总览。
- [`AUTH_SYNC_ARCHITECTURE.md`](AUTH_SYNC_ARCHITECTURE.md)：认证与同步架构。
- [`BACKEND_OBSERVABILITY.md`](BACKEND_OBSERVABILITY.md)：服务端可观测性。
- [`CRASH_REPORTING.md`](CRASH_REPORTING.md)：iOS crash-reporting 抽象。
- [`SUPABASE_ENVIRONMENT_TOPOLOGY.md`](SUPABASE_ENVIRONMENT_TOPOLOGY.md)：Supabase 环境拓扑决策记录。

### Development

- [`development/WORKFLOW.md`](development/WORKFLOW.md)：任务生命周期、增量测试和失败处理。
- [`development/CODING.md`](development/CODING.md)：编码与安全约束。
- [`development/TESTING.md`](development/TESTING.md)：测试矩阵和具体命令。
- [`mvp-regression-checklist.md`](mvp-regression-checklist.md)：PWA 手动回归清单。

### Contracts

长期契约目前仍保留在 `docs/` 根部，后续只在有独立迁移任务时移动：

- [`SYNC_API_CONTRACT.md`](SYNC_API_CONTRACT.md)
- [`INVENTORY_MERGE_CONTRACT.md`](INVENTORY_MERGE_CONTRACT.md)
- [`INVENTORY_MUTATION_COALESCING.md`](INVENTORY_MUTATION_COALESCING.md)
- [`ACCOUNT_DATA_LIFECYCLE.md`](ACCOUNT_DATA_LIFECYCLE.md)
- [`MINIMUM_APP_VERSION_ENFORCEMENT.md`](MINIMUM_APP_VERSION_ENFORCEMENT.md)
- [`SYNC_API_RATE_LIMITING.md`](SYNC_API_RATE_LIMITING.md)

新增长期 API、数据、备份或同步契约应放入 `docs/contracts/`。

### Runbooks

- [`ACCOUNT_DELETION_RUNBOOK.md`](ACCOUNT_DELETION_RUNBOOK.md)
- [`INVENTORY_SYNC_DOGFOOD_PLAYBOOK.md`](INVENTORY_SYNC_DOGFOOD_PLAYBOOK.md)
- [`INVENTORY_SYNC_ROLLBACK_PLAYBOOK.md`](INVENTORY_SYNC_ROLLBACK_PLAYBOOK.md)
- [`PRODUCTION_ROLLBACK_RUNBOOK.md`](PRODUCTION_ROLLBACK_RUNBOOK.md)
- [`TESTFLIGHT_ROLLOUT_PLAN.md`](TESTFLIGHT_ROLLOUT_PLAN.md)

新增长期发布、回滚、账号删除或事故操作步骤应放入 `docs/runbooks/`。

### Decisions

现有长期决策仍由其专题文档承载，例如 [`SUPABASE_ENVIRONMENT_TOPOLOGY.md`](SUPABASE_ENVIRONMENT_TOPOLOGY.md)。新的长期且难以逆转的架构决定使用 `docs/decisions/ADR-*.md`，记录背景、决定、后果和替代方案。

### Archive

- [`archive/README.md`](archive/README.md)：归档标准。
- 现有 `*PHASE*`、`*VALIDATION*`、物理设备结果和 closeout audit 是历史证据；本次不批量移动，以免破坏活动引用或开放 PR。
- 《大众川菜》当前来源范围的总证据：[`../data/source-restoration/dazhong-chuancai-1979-closeout-audit.v1.md`](../data/source-restoration/dazhong-chuancai-1979-closeout-audit.v1.md)。活动文档应优先链接该 closeout，而不是要求默认读取 Batch 1–11。

## 信息归属

- 当前项目状态 → `PROJECT_STATUS.md`
- 已进入 main 的重要变化 → `CHANGELOG.md`
- 稳定产品原则 → `docs/product/`
- 稳定架构 → `docs/architecture/`
- 开发、编码、测试流程 → `docs/development/`
- API、数据、备份、同步等长期契约 → `docs/contracts/`
- 发布、回滚、账号删除等操作步骤 → `docs/runbooks/`
- 长期且难以逆转的架构决定 → `docs/decisions/ADR-*.md`
- 单次任务、分支进度、临时调查 → PR 或 Issue，不新建仓库文档
- 可重新生成的报告 → `artifacts/` 或临时目录，默认不提交
- 已结束阶段的不可变证据 → `docs/archive/`

## 新建、替代与删除规则

1. 新建文件前先确认现有权威文件不能承载该信息。
2. 不因每个 Phase、Batch、PR 或小修复自动新建长期 Markdown。
3. 同一事实只能有一个权威文件；其他文档只能链接，不得复制。
4. 文档被替代后应删除或归档，不能继续与新文件并列为权威来源。
5. 当前状态不得写入历史证据；历史证据不得继续描述当前状态。
6. 可生成输出默认进入被 Git 忽略的目录；只有稳定、不可复现且有长期审计价值的证据才评估提交。
