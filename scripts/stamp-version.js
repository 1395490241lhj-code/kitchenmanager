#!/usr/bin/env node
/*
 * stamp-version.js —— 统一缓存版本号（Cache Busting）
 *
 * 背景：本项目是纯静态站点，靠 `文件名?v=<数字>` 查询参数让浏览器跳过强缓存。
 * 这些 `?v=` 散落在 index.html / 404.html / sw.v18.js 以及 src 下几十处 ES module
 * import 里，手动维护极易漏改、对不上号。
 *
 * 本脚本把全部 `?v=<数字>` 统一替换成同一个版本号，发布时一条命令即可：
 *
 *     node scripts/stamp-version.js 158        # 指定版本号
 *     node scripts/stamp-version.js            # 不带参数 = 在当前最大值上 +1
 *
 * 说明：
 * - `?v=` 仅用于缓存失效，服务器会忽略它并照常返回文件，所以把所有引用刷成同一个
 *   数字是安全的；代价只是一次性的全量缓存刷新（发布时本来就需要）。
 * - 只改 `?v=<数字>` 形式的查询参数；不会动 sw.v18.js / ingredients-list-patch.v15.js
 *   这类“文件名里的版本”，也不会动 app.js 里运行时读取的 URL 参数（默认 '23' 的数据包版本）。
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const SKIP_DIRS = new Set(['.git', 'node_modules', 'icons', 'scripts']);
const EXTENSIONS = new Set(['.html', '.js']);
const VERSION_RE = /\?v=(\d+)/g;

function walk(dir, files = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('.git')) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue;
      walk(full, files);
    } else if (EXTENSIONS.has(path.extname(entry.name))) {
      files.push(full);
    }
  }
  return files;
}

function currentMax(files) {
  let max = 0;
  for (const file of files) {
    const text = fs.readFileSync(file, 'utf8');
    let m;
    while ((m = VERSION_RE.exec(text)) !== null) {
      max = Math.max(max, Number(m[1]));
    }
  }
  return max;
}

function main() {
  const files = walk(ROOT);

  const arg = process.argv[2];
  let version;
  if (arg === undefined) {
    version = currentMax(files) + 1;
  } else if (/^\d+$/.test(arg)) {
    version = Number(arg);
  } else {
    console.error(`版本号必须是非负整数，收到："${arg}"`);
    process.exit(1);
  }

  let changedFiles = 0;
  let changedRefs = 0;
  for (const file of files) {
    const before = fs.readFileSync(file, 'utf8');
    let hits = 0;
    const after = before.replace(VERSION_RE, () => { hits++; return `?v=${version}`; });
    if (hits && after !== before) {
      fs.writeFileSync(file, after);
      changedFiles++;
      changedRefs += hits;
      console.log(`  ${path.relative(ROOT, file)} (${hits})`);
    }
  }

  console.log(`\n✓ 已将 ${changedRefs} 处 ?v= 引用统一为 v=${version}（${changedFiles} 个文件）。`);
  console.log('  提交后部署即可触发客户端与 Service Worker 的缓存刷新。');
}

main();
