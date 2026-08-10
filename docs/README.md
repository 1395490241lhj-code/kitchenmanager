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
- [`IOS_SHOPPING_EXPERIENCE.md`](IOS_SHOPPING_EXPERIENCE.md)：Shopping 体验范围。

### Architecture

- [`architecture/OVERVIEW.md`](architecture/OVERVIEW.md)：跨客户端与服务端总览。
- [`architecture/AUTH_SYNC_ARCHITECTURE.md`](architecture/AUTH_SYNC_ARCHITECTURE.md)：认证与同步架构。
- [`architecture/BACKEND_OBSERVABILITY.md`](architecture/BACKEND_OBSERVABILITY.md)：服务端可观测性。
- [`architecture/CRASH_REPORTING.md`](architecture/CRASH_REPORTING.md)：iOS crash-reporting 抽象。

### Development

- [`development/WORKFLOW.md`](development/WORKFLOW.md)：任务生命周期、增量测试和失败处理。
- [`development/CODING.md`](development/CODING.md)：编码与安全约束。
- [`development/TESTING.md`](development/TESTING.md)：测试矩阵和具体命令。
- [`mvp-regression-checklist.md`](mvp-regression-checklist.md)：PWA 手动回归清单。

### Contracts

长期有效的数据、API、同步和兼容性契约：

- [`contracts/SYNC_API_CONTRACT.md`](contracts/SYNC_API_CONTRACT.md)
- [`contracts/INVENTORY_MERGE_CONTRACT.md`](contracts/INVENTORY_MERGE_CONTRACT.md)
- [`contracts/INVENTORY_MUTATION_COALESCING.md`](contracts/INVENTORY_MUTATION_COALESCING.md)
- [`contracts/ACCOUNT_DATA_LIFECYCLE.md`](contracts/ACCOUNT_DATA_LIFECYCLE.md)
- [`contracts/ACCOUNT_DELETION_DESIGN.md`](contracts/ACCOUNT_DELETION_DESIGN.md)
- [`contracts/MINIMUM_APP_VERSION_ENFORCEMENT.md`](contracts/MINIMUM_APP_VERSION_ENFORCEMENT.md)
- [`contracts/SYNC_API_RATE_LIMITING.md`](contracts/SYNC_API_RATE_LIMITING.md)

新增长期 API、数据、备份或同步契约应放入 `docs/contracts/`。

### Runbooks

- [`runbooks/ACCOUNT_DELETION_RUNBOOK.md`](runbooks/ACCOUNT_DELETION_RUNBOOK.md)
- [`runbooks/INVENTORY_SYNC_DOGFOOD_PLAYBOOK.md`](runbooks/INVENTORY_SYNC_DOGFOOD_PLAYBOOK.md)
- [`runbooks/INVENTORY_SYNC_ROLLBACK_PLAYBOOK.md`](runbooks/INVENTORY_SYNC_ROLLBACK_PLAYBOOK.md)
- [`runbooks/PRODUCTION_ROLLBACK_RUNBOOK.md`](runbooks/PRODUCTION_ROLLBACK_RUNBOOK.md)
- [`runbooks/PRODUCTION_ROLLOUT_PLAN.md`](runbooks/PRODUCTION_ROLLOUT_PLAN.md)
- [`runbooks/IOS_RELEASE_PIPELINE.md`](runbooks/IOS_RELEASE_PIPELINE.md)
- [`runbooks/TESTFLIGHT_ROLLOUT_PLAN.md`](runbooks/TESTFLIGHT_ROLLOUT_PLAN.md)
- [`runbooks/APP_STORE_METADATA_TEMPLATE.md`](runbooks/APP_STORE_METADATA_TEMPLATE.md)
- [`runbooks/APP_STORE_REVIEW_CHECKLIST.md`](runbooks/APP_STORE_REVIEW_CHECKLIST.md)

新增长期发布、回滚、账号删除或事故操作步骤应放入 `docs/runbooks/`。

### Decisions

- [`decisions/SUPABASE_ENVIRONMENT_TOPOLOGY.md`](decisions/SUPABASE_ENVIRONMENT_TOPOLOGY.md)：Supabase 环境拓扑决策记录。

新的长期且难以逆转的架构决定使用 `docs/decisions/ADR-*.md`，记录背景、决定、后果和替代方案。没有真正的决策文档时不为了目录结构创建占位文件。

### Archive

- [`archive/README.md`](archive/README.md)：归档标准。
- `archive/ios/`、`archive/sync/`、`archive/release/`、`archive/production/`：按主题分类的已完成 Phase、Validation、物理设备结果和 readiness/go-no-go 历史工程证据。
- `archive/source-restoration/`：已完成的《大众川菜》来源恢复阶段方法/索引证据（阶段文档、目录索引与名称匹配过程）。当前最终状态以 `data/source-restoration/dazhong-chuancai-1979-closeout-audit.v1.md` 为准。
- `archive/recipe-method-completion/`：已完成的菜谱做法补全阶段文档（全库/剩余候选人工审核、补全状态与工作流）。这些是历史过程证据，不再描述当前实现。
- archive 中的文件是历史证据，不代表当前实现；当前行为以代码、测试及 active documentation 为准。
- 部分开放 PR 正在修改的文档（如 `IOS_SHARE_IMPORT.md`）本轮暂留在 `docs/` 根部，避免增加 rebase 冲突。
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
