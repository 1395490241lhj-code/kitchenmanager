// test/date-utils.test.mjs
// 本地日期工具回归：todayISO / parseLocalDate / addDaysISO 必须按本地时区计算，
// 不能用 new Date().toISOString().slice(0,10)（那是 UTC 日期，负时区晚上会提前跨到明天）。
import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { todayISO, parseLocalDate, addDaysISO } from '../src/storage.js';

const root = process.cwd();
function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

const originalTZ = process.env.TZ;
afterEach(() => {
  if (originalTZ === undefined) delete process.env.TZ;
  else process.env.TZ = originalTZ;
});

// ── 一、todayISO 按本地时区，不按 UTC ────────────────────────────────────────

test('todayISO：America/Toronto 晚上 21:00 不会提前跨到明天', () => {
  process.env.TZ = 'America/Toronto';
  // 2026-07-09 21:00 多伦多时间（EDT，UTC-4）= 2026-07-10 01:00 UTC。
  const instant = new Date(Date.UTC(2026, 6, 10, 1, 0, 0));
  assert.equal(todayISO(instant), '2026-07-09');
});

test('todayISO：Asia/Shanghai 21:00 正常', () => {
  process.env.TZ = 'Asia/Shanghai';
  // 2026-07-09 21:00 上海时间（UTC+8）= 2026-07-09 13:00 UTC。
  const instant = new Date(Date.UTC(2026, 6, 9, 13, 0, 0));
  assert.equal(todayISO(instant), '2026-07-09');
});

test('todayISO：UTC 21:00 正常', () => {
  process.env.TZ = 'UTC';
  const instant = new Date(Date.UTC(2026, 6, 9, 21, 0, 0));
  assert.equal(todayISO(instant), '2026-07-09');
});

test('todayISO：无参数时默认取 new Date()，不破坏现有零参调用', () => {
  process.env.TZ = 'Asia/Shanghai';
  assert.match(todayISO(), /^\d{4}-\d{2}-\d{2}$/);
});

// ── 二、parseLocalDate 按本地字段解析，不经过 UTC 午夜 ──────────────────────

test('parseLocalDate："YYYY-MM-DD" 解析出的年月日与字符串一致（不受时区影响）', () => {
  for (const tz of ['America/Toronto', 'Asia/Shanghai', 'UTC']) {
    process.env.TZ = tz;
    const d = parseLocalDate('2026-07-09');
    assert.equal(d.getFullYear(), 2026, `TZ=${tz}`);
    assert.equal(d.getMonth(), 6, `TZ=${tz}`); // 0-indexed：7 月
    assert.equal(d.getDate(), 9, `TZ=${tz}`);
  }
});

// ── 三、addDaysISO：跨月/跨年/DST 边界都正确，且与时区无关 ───────────────────

test('addDaysISO：DST 边界（America/Toronto 2026-03-08 春季跳表日）加一天不跳错', () => {
  process.env.TZ = 'America/Toronto';
  assert.equal(addDaysISO('2026-03-08', 1), '2026-03-09');
});

test('addDaysISO：跨年年末 +1', () => {
  assert.equal(addDaysISO('2026-12-31', 1), '2027-01-01');
});

test('addDaysISO：跨年年初 -1', () => {
  assert.equal(addDaysISO('2026-01-01', -1), '2025-12-31');
});

test('addDaysISO：同一次加减在不同时区下结果一致', () => {
  for (const tz of ['America/Toronto', 'Asia/Shanghai', 'UTC']) {
    process.env.TZ = tz;
    assert.equal(addDaysISO('2026-07-09', 1), '2026-07-10', `TZ=${tz}`);
    assert.equal(addDaysISO('2026-07-09', -1), '2026-07-08', `TZ=${tz}`);
  }
});

// ── 四、源码接线：调用点统一到共享的本地日期工具，不再各自手搓 UTC 往返 ──────

test('源码接线：weekly-menu.js 不再自己定义 addDaysISO，改用 storage.js 的共享实现', () => {
  const source = read('src/views/home/weekly-menu.js');
  assert.match(source, /import \{ S, todayISO, addDaysISO \} from '\.\.\/\.\.\/storage\.js/);
  assert.doesNotMatch(source, /function addDaysISO\(/);
});

test('源码接线：recommendations.js / menu-plan.js / recipe-detail-view.js 的明天/后天计算改用 addDaysISO，不再手搓 toISOString().slice(0,10)', () => {
  const files = [
    'src/recommendations.js',
    'src/components/menu-plan.js',
    'src/views/recipe-detail-view.js'
  ];
  for (const rel of files) {
    const source = read(rel);
    assert.match(source, /addDaysISO\(today, 1\)/, rel);
    assert.match(source, /addDaysISO\(today, 2\)/, rel);
    assert.doesNotMatch(source, /toISOString\(\)\.slice\(0, ?10\)/, rel);
  }
});
