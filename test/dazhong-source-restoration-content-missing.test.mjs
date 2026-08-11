import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
import { isVerifiedContentMissing } from '../scripts/lib/content-missing.mjs';

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8'),
);

const restored = readJson(
  'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
);

test('contentMissing exception only applies to a verified missing-source uncertainty', () => {
  // A recipe that merely has empty ingredients/steps, with no contentMissing
  // flag at all, must not be treated as verified missing content.
  assert.equal(isVerifiedContentMissing({
    contentMissing: undefined,
    ingredients: [],
    methodSummary: { steps: [] },
    uncertainties: [],
  }), false);

  // contentMissing=true with no uncertainties at all must not qualify.
  assert.equal(isVerifiedContentMissing({
    contentMissing: true,
    ingredients: [],
    methodSummary: { steps: [] },
    uncertainties: [],
  }), false);

  // contentMissing=true with a page-boundary uncertainty but an
  // unrecognized/unsanctioned reasonCode must not qualify.
  assert.equal(isVerifiedContentMissing({
    contentMissing: true,
    ingredients: [],
    methodSummary: { steps: [] },
    uncertainties: [{ type: 'page-boundary', reasonCode: 'worker-forgot-to-extract' }],
  }), false);

  // contentMissing=true with a page-boundary uncertainty of a different type
  // (e.g. unclear-glyph) must not qualify.
  assert.equal(isVerifiedContentMissing({
    contentMissing: true,
    ingredients: [],
    methodSummary: { steps: [] },
    uncertainties: [{ type: 'unclear-glyph', reasonCode: 'scan-page-blank' }],
  }), false);

  // The two sanctioned reasonCode values, with the required uncertainty
  // type, must qualify.
  assert.equal(isVerifiedContentMissing({
    contentMissing: true,
    ingredients: [],
    methodSummary: { steps: [] },
    uncertainties: [{ type: 'page-boundary', reasonCode: 'scan-page-blank' }],
  }), true);
  assert.equal(isVerifiedContentMissing({
    contentMissing: true,
    ingredients: [],
    methodSummary: { steps: [] },
    uncertainties: [{ type: 'page-boundary', reasonCode: 'source-content-missing' }],
  }), true);
});

test('dz1979-p122, dz1979-p138, dz1979-p152 are the verified-missing entries in the restored batch prefix', () => {
  const missingEntries = restored.recipes.filter((recipe) => recipe.contentMissing === true);
  assert.deepEqual(
    missingEntries.map((recipe) => recipe.entryId),
    ['dz1979-p122', 'dz1979-p138', 'dz1979-p152'],
  );
  for (const entry of missingEntries) {
    assert.equal(isVerifiedContentMissing(entry), true);
    assert.equal(entry.ingredients.length, 0);
    assert.equal(entry.methodSummary.steps.length, 0);
    const uncertainty = entry.uncertainties.find((u) => u.type === 'page-boundary');
    assert.equal(uncertainty.reasonCode, 'scan-page-blank');
    // The recorded fact must describe what the source proves (a blank page),
    // not assert an unproven cause such as a printing defect.
    assert.doesNotMatch(uncertainty.treatment, /判定为.{0,4}印刷缺页/);
    assert.match(uncertainty.treatment, /不对成因作出判断/);
  }
});

test('assembler rejects an ordinary recipe with empty ingredients/steps even when other batches are valid', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dz1979-assembler-test-'));
  const badWorkerPath = path.join(tmpDir, 'dz1979-b06-worker-bad.json');
  const goodWorker = readJson('data/source-restoration/dz1979-b06-worker.json');
  const badWorker = JSON.parse(JSON.stringify(goodWorker));
  const target = badWorker.recipes.find((recipe) => recipe.entryId === 'dz1979-p123');
  assert.ok(target, 'expected dz1979-p123 to exist in the b06 worker file');
  // Simulate an ordinary (non-verified) empty extraction: no contentMissing
  // flag, no qualifying uncertainty, just empty arrays.
  target.ingredients = [];
  target.methodSummary.steps = [];
  fs.writeFileSync(badWorkerPath, JSON.stringify(badWorker, null, 2));

  assert.throws(() => {
    execFileSync('node', [
      new URL('../scripts/assemble-dazhong-chuancai-recipes.mjs', import.meta.url).pathname,
      'data/source-restoration/dz1979-b05-worker.json',
      badWorkerPath,
    ], { cwd: new URL('..', import.meta.url).pathname, stdio: 'pipe' });
  }, /has no printed ingredients/);

  fs.rmSync(tmpDir, { recursive: true, force: true });
});

test('assembler accepts the real contentMissing exceptions across b05-b07', () => {
  // Re-running the assembler against the real (corrected) worker files
  // must succeed and must not change which entry is treated as missing.
  const repoRoot = new URL('..', import.meta.url).pathname;
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dz1979-assembler-test-'));
  try {
    const tempFiles = [
      'scripts/assemble-dazhong-chuancai-recipes.mjs',
      'scripts/lib/content-missing.mjs',
      'data/source-restoration/dazhong-chuancai-1979-batch-plan.v1.json',
      'data/source-restoration/dazhong-chuancai-1979-catalog.v1.json',
      'data/source-restoration/dazhong-chuancai-1979-crosswalk-probable-review.v1.json',
      'data/source-restoration/dazhong-chuancai-1979-name-matches.v1.json',
      'data/source-restoration/dazhong-chuancai-1979-pilot.v1.json',
      'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
      'data/source-restoration/dz1979-b05-worker.json',
      'data/source-restoration/dz1979-b06-worker.json',
      'data/source-restoration/dz1979-b07-worker.json',
    ];
    for (const relativePath of tempFiles) {
      const destination = path.join(tmpDir, relativePath);
      fs.mkdirSync(path.dirname(destination), { recursive: true });
      fs.copyFileSync(path.join(repoRoot, relativePath), destination);
    }

    execFileSync('node', [
      path.join(tmpDir, 'scripts/assemble-dazhong-chuancai-recipes.mjs'),
      path.join(tmpDir, 'data/source-restoration/dz1979-b05-worker.json'),
      path.join(tmpDir, 'data/source-restoration/dz1979-b06-worker.json'),
      path.join(tmpDir, 'data/source-restoration/dz1979-b07-worker.json'),
    ], { cwd: tmpDir, stdio: 'pipe' });
    const rebuilt = JSON.parse(fs.readFileSync(
      path.join(tmpDir, 'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json'),
      'utf8',
    ));

    const missingEntries = rebuilt.recipes.filter((recipe) => recipe.contentMissing === true);
    assert.deepEqual(
      missingEntries.map((recipe) => recipe.entryId),
      ['dz1979-p122', 'dz1979-p138', 'dz1979-p152'],
    );
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
