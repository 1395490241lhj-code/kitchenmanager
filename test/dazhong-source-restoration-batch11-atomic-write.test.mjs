import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repoRoot = fileURLToPath(new URL('..', import.meta.url));
const generator = 'scripts/build-dazhong-chuancai-batch11-quantity-review.mjs';
const reader = 'test/dazhong-source-restoration-promotion-batch11-quantity-review.test.mjs';
const artifact = 'data/source-restoration/dazhong-chuancai-1979-promotion-batch11-quantity-review.v1.json';
const dryRun = 'data/source-restoration/dazhong-chuancai-1979-promotion-batch11-dry-run.v1.json';

function fixture(t, hook) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'km-batch11-atomic-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const file of [generator, reader, artifact, dryRun]) {
    fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
    fs.copyFileSync(path.join(repoRoot, file), path.join(root, file));
  }
  const preload = path.join(root, 'write-boundary.cjs');
  fs.writeFileSync(preload, `
    const fs = require('node:fs');
    const assert = require('node:assert/strict');
    const { spawnSync } = require('node:child_process');
    const write = fs.writeFileSync;
    fs.writeFileSync = (file, data, ...options) => {
      // Force the exact truncate-before-write boundary, without timing/sleeps.
      const fd = fs.openSync(file, 'w');
      try {
        ${hook}
        return write(fd, data, ...options);
      } finally {
        fs.closeSync(fd);
      }
    };
  `);
  // Remove node:test's child-process marker so nested readers run normally.
  const env = { ...process.env };
  delete env.NODE_TEST_CONTEXT;
  return {
    root,
    run: () => spawnSync(process.execPath, ['--require', preload, generator], {
      cwd: root,
      encoding: 'utf8',
      env,
    }),
  };
}

test('Batch11 readers see complete published JSON while regeneration is writing', (t) => {
  const { root, run } = fixture(t, `
    const result = spawnSync(process.execPath, ['--test', ${JSON.stringify(reader)}], {
      cwd: process.cwd(), encoding: 'utf8',
    });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    process.stdout.write('reader-at-write-boundary: passed\\n');
  `);
  const before = fs.readFileSync(path.join(root, artifact));
  const result = run();
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /reader-at-write-boundary: passed/);
  assert.deepEqual(fs.readFileSync(path.join(root, artifact)), before);
  assert.deepEqual(fs.readdirSync(path.join(root, 'data/source-restoration')).sort(), [
    path.basename(dryRun), path.basename(artifact),
  ].sort());
});

test('Batch11 failed regeneration preserves published bytes and removes staging output', (t) => {
  const { root, run } = fixture(t, "throw new Error('injected write failure');");
  const before = fs.readFileSync(path.join(root, artifact));
  const result = run();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /injected write failure/);
  assert.deepEqual(fs.readFileSync(path.join(root, artifact)), before);
  assert.deepEqual(fs.readdirSync(path.join(root, 'data/source-restoration')).sort(), [
    path.basename(dryRun), path.basename(artifact),
  ].sort());
});
