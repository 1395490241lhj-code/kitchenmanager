// test/workflow-config.test.mjs
// CI 门禁回归：.github/workflows/deploy.yml 必须在 main push / PR 上都跑完整校验
// （npm ci → npm test → 两个菜谱包校验 → 生产依赖高危审计），Node 18/22 双跑，
// 且 GitHub Pages 的 build/deploy 必须依赖这个校验 job、且不在 PR 上部署。
//
// 没有引入 YAML 解析库（保持零新增依赖）：先做一个不依赖第三方库的结构性检查
// （不含 tab、块级缩进前后一致），再对具体内容做源码字符串断言——和本仓库其余
// "接线类" 测试的写法一致。
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = process.cwd();
const WORKFLOW_PATH = '.github/workflows/deploy.yml';

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

// 轻量结构检查：YAML 不允许用 tab 缩进；块级缩进要么比上一层深（新开一层），
// 要么和某一层已有的缩进完全相等（回到那一层），不允许"缩进量对不上任何已知层级"。
// 这足够抓住"手滑改错缩进"这类真实错误，但不是完整 YAML 1.2 语法校验。
function assertBlockIndentationIsConsistent(text) {
  const lines = text.split('\n');
  const stack = [0];
  lines.forEach((line, idx) => {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) return;
    const leading = line.match(/^[ \t]*/)[0];
    assert.ok(!leading.includes('\t'), `第 ${idx + 1} 行缩进包含 tab，YAML 不允许：${JSON.stringify(line)}`);
    const indent = leading.length;
    while (stack.length > 1 && indent < stack[stack.length - 1]) stack.pop();
    if (indent > stack[stack.length - 1]) {
      stack.push(indent);
    } else {
      assert.equal(indent, stack[stack.length - 1], `第 ${idx + 1} 行缩进量对不上任何已知层级：${JSON.stringify(line)}`);
    }
  });
}

test('deploy.yml：不含 tab、块级缩进层级前后一致（基础结构合法性）', () => {
  assertBlockIndentationIsConsistent(read(WORKFLOW_PATH));
});

test('deploy.yml：main push 和 PR 都会触发（workflow_dispatch 保留手动入口）', () => {
  const source = read(WORKFLOW_PATH);
  const onBlock = source.slice(source.indexOf('\non:'), source.indexOf('\npermissions:'));
  assert.match(onBlock, /push:\s*\n\s*branches:\s*\["main"\]/);
  assert.match(onBlock, /pull_request:\s*\n\s*branches:\s*\["main"\]/);
  assert.match(onBlock, /workflow_dispatch:/);
});

test('deploy.yml：并发组按 ref 区分，PR 校验跑不会取消 main 部署跑（反之亦然）', () => {
  const source = read(WORKFLOW_PATH);
  assert.match(source, /group:\s*"pages-\$\{\{\s*github\.ref\s*\}\}"/);
});

test('deploy.yml：test job 使用 Node 18/22 矩阵（package.json engines 与依赖都兼容 18，不能自行收窄）', () => {
  const pkg = JSON.parse(read('package.json'));
  assert.equal(pkg.engines?.node, '>=18', 'package.json 仍应声明兼容 Node 18');

  const source = read(WORKFLOW_PATH);
  const testJob = source.slice(source.indexOf('\n  test:'), source.indexOf('\n  build:'));
  assert.match(testJob, /node-version:\s*\[\s*'18'\s*,\s*'22'\s*\]/);
  assert.match(testJob, /fail-fast:\s*false/, '矩阵应该 fail-fast:false，两个 Node 版本的结果都要看到');
});

test('deploy.yml：test job 依次跑 npm ci / npm test / 两个菜谱包校验 / 生产依赖高危审计', () => {
  const source = read(WORKFLOW_PATH);
  const testJob = source.slice(source.indexOf('\n  test:'), source.indexOf('\n  build:'));

  assert.match(testJob, /uses:\s*actions\/setup-node@v4/);
  assert.match(testJob, /node-version:\s*\$\{\{\s*matrix\.node-version\s*\}\}/);
  assert.match(testJob, /cache:\s*'npm'/, '应该用 setup-node 内置的 npm cache');

  const stepOrder = ['run: npm ci', 'run: npm test', 'run: npm run validate:recipe-packs', 'run: npm run validate:recipe-pack-data', 'run: npm audit --omit=dev --audit-level=high'];
  let cursor = -1;
  for (const step of stepOrder) {
    const idx = testJob.indexOf(step);
    assert.ok(idx > cursor, `缺少或顺序不对: "${step}"`);
    cursor = idx;
  }
});

test('deploy.yml：npm scripts 与 workflow 里引用的一致（validate:recipe-packs / validate:recipe-pack-data 真实存在）', () => {
  const pkg = JSON.parse(read('package.json'));
  assert.equal(typeof pkg.scripts['validate:recipe-packs'], 'string');
  assert.equal(typeof pkg.scripts['validate:recipe-pack-data'], 'string');
  assert.equal(typeof pkg.scripts.test, 'string');
});

test('deploy.yml：build/deploy 都 needs 完整校验 job，且不在 PR 上跑', () => {
  const source = read(WORKFLOW_PATH);
  const buildJob = source.slice(source.indexOf('\n  build:'), source.indexOf('\n  deploy:'));
  const deployJob = source.slice(source.indexOf('\n  deploy:'));

  assert.match(buildJob, /needs:\s*test/);
  assert.match(buildJob, /if:\s*github\.event_name\s*!=\s*'pull_request'/);

  assert.match(deployJob, /needs:\s*build/);
  assert.match(deployJob, /if:\s*github\.event_name\s*!=\s*'pull_request'/);
});

test('deploy.yml：test job 不重复跑同一套命令两次（除了 Node 矩阵本身）——每条 run 在 test job 里只出现一次', () => {
  const source = read(WORKFLOW_PATH);
  const testJob = source.slice(source.indexOf('\n  test:'), source.indexOf('\n  build:'));
  const runLines = [...testJob.matchAll(/run:\s*(.+)/g)].map(m => m[1].trim());
  assert.deepEqual(runLines, [...new Set(runLines)], 'test job 内部不应该有重复的 run 命令');
});
