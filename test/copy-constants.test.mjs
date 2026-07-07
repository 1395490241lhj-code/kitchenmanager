import test from 'node:test';
import assert from 'node:assert/strict';

import { DEMO_COPY, PLAN_COPY } from '../src/copy.js';

// S3 约定：高频文案的 prose 只在 src/copy.js 审阅一次；其余测试只做「接线检查」
// （断言代码引用了哪个常量），不再 grep 句子原文，避免每次改文案连坐一串测试。

test('计划流文案常量齐全且非空', () => {
  for (const [key, value] of Object.entries({ ...PLAN_COPY, ...DEMO_COPY })) {
    assert.equal(typeof value, 'string', `${key} 应为字符串`);
    assert.ok(value.trim().length >= 4, `${key} 不应为空`);
  }
});

test('文案与产品口径一致：说“计划/记录消耗”，不再说“今日计划”', () => {
  const all = Object.values({ ...PLAN_COPY, ...DEMO_COPY }).join('\n');
  // 记录消耗是饭后扣库存按钮的名字，引导文案必须与按钮一致。
  assert.match(PLAN_COPY.FIRST_PLAN_GUIDE, /记录消耗/);
  assert.match(DEMO_COPY.STEP_COOK_BODY, /记录消耗/);
  assert.match(DEMO_COPY.STEP_RECS_BODY, /加入计划/);
  // 弱化目标：这批常量里不允许再出现“今日计划”。
  assert.doesNotMatch(all, /今日计划/);
});
