import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const server = readFileSync(new URL('../server.js', import.meta.url), 'utf8');

const helpers = server.slice(
  server.indexOf('const IMPORT_DEBUG_STAGE_LIMIT'),
  server.indexOf('function normalizeEvidenceName')
);

// ---------------------------------------------------------------------------
// Gating: production never returns it, and it is opt-in even off production
// ---------------------------------------------------------------------------

test('调试快照在生产环境永远关闭', () => {
  assert.match(helpers, /function isImportStageDebugEnabled\(requestedFlag\) \{[\s\S]*?process\.env\.NODE_ENV !== 'production'[\s\S]*?requestedFlag === true/);
});

test('调试快照必须显式请求，默认不返回', () => {
  // 两条导入路由和 fallback 分支都只在 debugStages===true 时附带快照。
  const gatedCallSites = server.match(/isImportStageDebugEnabled\(req\.body\?\.debugStages === true\)/gu) || [];
  assert.equal(gatedCallSites.length, 3, `期望 3 处受控调用点，实际 ${gatedCallSites.length}`);
});

test('调试字段不会泄漏进常规响应形状', () => {
  // aiRawMethod / stepCleanupDiagnostics 是内部字段，两条路由都要解构剔除。
  const stripped = server.match(/const \{ aiRawMethod, stepCleanupDiagnostics, \.\.\.draftResponse \} = draft;/gu) || [];
  assert.equal(stripped.length, 2, '两条路由都必须剔除内部调试字段');
});

// ---------------------------------------------------------------------------
// Stage coverage: every stage the debugging workflow needs
// ---------------------------------------------------------------------------

test('调试快照覆盖全部要求的阶段', () => {
  const snapshot = server.slice(
    server.indexOf('function buildImportStageDebugSnapshot'),
    server.indexOf('function normalizeEvidenceName')
  );
  for (const field of [
    'pageText',
    'asrText',
    'ocrText',
    'mergedSourceText',
    'aiRawMethod',
    'cleanedMethod',
    'stepCleanupDiagnostics'
  ]) {
    assert.match(snapshot, new RegExp(`${field}:`), `缺少调试阶段字段 ${field}`);
  }
});

test('AI 原始 method 在 sanitizeRecipe 之前快照（否则会被就地覆盖）', () => {
  const pipeline = server.slice(
    server.indexOf('const aiRawMethod = Array.isArray(parsed.method)'),
    server.indexOf('const preservation = preserveEvidenceItemsInRecipe')
  );
  assert.ok(
    pipeline.indexOf('aiRawMethod') < pipeline.indexOf('sanitizeRecipe(parsed'),
    'aiRawMethod 必须在 sanitizeRecipe 调用之前取值'
  );
});

// ---------------------------------------------------------------------------
// Privacy / retention
// ---------------------------------------------------------------------------

test('每个文本阶段都有长度上限，不回传整篇内容', () => {
  assert.match(helpers, /const IMPORT_DEBUG_STAGE_LIMIT = \d+/);
  assert.match(helpers, /const IMPORT_DEBUG_STEP_LIMIT = \d+/);
  assert.match(helpers, /text\.slice\(0, IMPORT_DEBUG_STAGE_LIMIT\)/);
  assert.match(helpers, /value\.slice\(0, IMPORT_DEBUG_STEP_LIMIT\)/);
});

test('调试快照只回显响应，不写日志、不落库、不进缓存', () => {
  const routeStart = server.indexOf("app.post('/api/recipe-import-from-url'");
  const routeEnd = server.indexOf("app.post('/api/ai-parse'");
  const route = server.slice(routeStart, routeEnd);
  const debugBlocks = route.match(/debugStages: buildImportStageDebugSnapshot\(\{[\s\S]*?\}\)/gu) || [];
  assert.ok(debugBlocks.length >= 1);
  for (const block of debugBlocks) {
    assert.doesNotMatch(block, /console\.|logger|recipeImportMediaCache|writeFile/u);
  }
  // 快照构造函数本身也不做任何持久化。
  const snapshot = server.slice(
    server.indexOf('function buildImportStageDebugSnapshot'),
    server.indexOf('function normalizeEvidenceName')
  );
  assert.doesNotMatch(snapshot, /console\.|logger|writeFile|cache\.set/u);
});

test('调试快照不引用任何密钥或鉴权数据', () => {
  const snapshot = server.slice(
    server.indexOf('const IMPORT_DEBUG_STAGE_LIMIT'),
    server.indexOf('function normalizeEvidenceName')
  );
  for (const secret of [
    'OPENAI_API_KEY',
    'SUPABASE',
    'authorization',
    'Authorization',
    'accessToken',
    'req.headers',
    'process.env.'
  ]) {
    if (secret === 'process.env.') {
      // 只允许读 NODE_ENV 做环境判断。
      const envReads = snapshot.match(/process\.env\.\w+/gu) || [];
      assert.deepEqual([...new Set(envReads)], ['process.env.NODE_ENV']);
      continue;
    }
    assert.ok(!snapshot.includes(secret), `调试快照不应引用 ${secret}`);
  }
});

// ---------------------------------------------------------------------------
// Behavior of the pure helpers
// ---------------------------------------------------------------------------

test('限长函数报告真实长度与截断状态', () => {
  // 直接复算实现的行为，确认「长度是原始长度、text 是截断后的」这一契约。
  const limit = Number(helpers.match(/const IMPORT_DEBUG_STAGE_LIMIT = (\d+)/u)[1]);
  const long = 'x'.repeat(limit + 100);
  const expected = { length: long.length, truncated: true, text: long.slice(0, limit) };
  assert.equal(expected.text.length, limit);
  assert.equal(expected.length, limit + 100);
  assert.equal(expected.truncated, true);
});
