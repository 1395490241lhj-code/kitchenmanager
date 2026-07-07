/*
 * src/copy.js —— 高频 UI 文案的唯一事实源（S3 测试策略收敛的一部分）。
 *
 * 约定：
 *  - 这里只收「反复被测试锚定、且产品迭代中常改」的短文案（计划流 Toast、示例引导等）。
 *  - 代码一律引用常量；测试断言「代码引用了哪个常量」（接线检查），不再 grep 句子原文。
 *    这样改文案只动本文件一处，测试不会因 prose 变化而破裂。
 *  - 文案本身的把关放在 test/copy-constants.test.mjs：集中审阅关键词（如“记录消耗”）。
 */

export const PLAN_COPY = {
  // 加入计划的 Toast 家族（home-view 字面量位点）
  ADDED: '已加入计划',
  ADDED_WITH_SHOPPING: '已加入计划，缺的食材已加入买菜清单。',
  ADDED_SHOPPING_LATER: '已加入计划，缺的食材可稍后处理。',
  ALREADY_TODAY: '今天已经有这道菜',
  // 首次加入计划后的闭环引导
  FIRST_PLAN_GUIDE: '已加入计划。做完后点“记录消耗”，我会帮你更新剩余食材和待买清单。'
};

export const DEMO_COPY = {
  // 示例厨房分步引导文案（demo-kitchen 步骤机）
  STEP_RECS_BODY: '在下面的推荐里，点“加入计划”。缺的食材可以顺手放进买菜清单。',
  STEP_COOK_BODY: '计划里已经有菜了。做完后点“记录消耗”，我会帮你确认用掉了哪些食材。',
  DONE_BODY: '你已经体验了推荐、计划和饭后更新。现在可以开始记录自己的厨房。'
};
