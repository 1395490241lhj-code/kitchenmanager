import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8'),
);

const queue = readJson(
  'data/source-restoration/dazhong-chuancai-1979-review-queue.v1.json',
);

const assembled = readJson(
  'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
);

const recipesById = new Map(assembled.recipes.map((r) => [r.entryId, r]));

const getByPath = (root, fieldPath) => {
  const parts = fieldPath.replace(/\]/g, '').split('.');
  let cur = root;
  for (const part of parts) {
    if (cur === undefined || cur === null) return undefined;
    const bracketIdx = part.indexOf('[');
    if (bracketIdx !== -1) {
      const key = part.slice(0, bracketIdx);
      const idx = Number(part.slice(bracketIdx + 1));
      cur = cur[key];
      if (!Array.isArray(cur) || idx >= cur.length) return undefined;
      cur = cur[idx];
    } else {
      if (typeof cur !== 'object' || !(part in cur)) return undefined;
      cur = cur[part];
    }
  }
  return cur;
};

test('review queue schema and top-level shape', () => {
  assert.equal(queue.schema, 'kitchenmanager.source-restoration.review-queue.v1');
  assert.equal(queue.scope.assembledRecipeCount, 147);
  assert.equal(queue.scope.completedBatchCount, 11);
  assert.equal(queue.scope.applicationReady, false);
  assert.equal(queue.scope.crosswalkOrPromotionPerformed, false);
  assert.ok(Array.isArray(queue.items));
});

test('review queue is deduplicated by entryId', () => {
  const ids = queue.items.map((it) => it.entryId);
  const uniqueIds = new Set(ids);
  assert.equal(uniqueIds.size, ids.length, 'entryId must be unique across the review queue');
});

test('every queue item entryId exists in the assembled 147-recipe source', () => {
  for (const item of queue.items) {
    assert.ok(
      recipesById.has(item.entryId),
      `queue item ${item.entryId} must correspond to a recipe in the assembled source`,
    );
  }
});

test('every evidenceFieldPath in the queue resolves to an existing field in the assembled source', () => {
  for (const item of queue.items) {
    assert.ok(Array.isArray(item.evidenceFieldPaths) && item.evidenceFieldPaths.length > 0,
      `${item.entryId} must carry at least one evidenceFieldPath`);
    for (const evidencePath of item.evidenceFieldPaths) {
      const match = evidencePath.match(/^recipes\[entryId=([^\]]+)\]\.(.+)$/);
      assert.ok(match, `evidence path malformed: ${evidencePath}`);
      const [, entryId, fieldPath] = match;
      assert.equal(entryId, item.entryId);
      const recipe = recipesById.get(entryId);
      assert.ok(recipe, `evidence path references unknown entryId ${entryId}`);
      const resolved = getByPath(recipe, fieldPath);
      assert.notEqual(
        resolved,
        undefined,
        `evidence path ${evidencePath} did not resolve against assembled source`,
      );
    }
  }
});

test('priority is one of high/medium/low and counts match summary', () => {
  const counts = { high: 0, medium: 0, low: 0 };
  for (const item of queue.items) {
    assert.ok(['high', 'medium', 'low'].includes(item.priority), `unexpected priority for ${item.entryId}`);
    counts[item.priority] += 1;
  }
  assert.equal(queue.summary.dedupedReviewItemCount, queue.items.length);
  for (const level of ['high', 'medium', 'low']) {
    assert.equal(queue.summary.priorityCounts[level] ?? 0, counts[level]);
  }
  assert.equal(counts.high + counts.medium + counts.low, queue.items.length);
});

test('needsScanRecheck and crosswalk-only counts match summary', () => {
  const rescanCount = queue.items.filter((it) => it.needsScanRecheck === true).length;
  const crosswalkOnlyCount = queue.items.filter((it) => it.needsScanRecheck === false).length;
  assert.equal(queue.summary.needsScanRecheckCount, rescanCount);
  assert.equal(queue.summary.crosswalkOnlyCount, crosswalkOnlyCount);
  assert.equal(rescanCount + crosswalkOnlyCount, queue.items.length);
});

test('every queue item has at least one traceable review reason', () => {
  for (const item of queue.items) {
    assert.ok(Array.isArray(item.reviewReasons) && item.reviewReasons.length > 0,
      `${item.entryId} must have at least one reviewReasons entry`);
    assert.ok(Array.isArray(item.reviewReasonKeys) && item.reviewReasonKeys.length > 0,
      `${item.entryId} must have at least one reviewReasonKeys entry`);
  }
});

test('contentMissing / scan-page-blank items only assert current-scan absence, not original-book absence', () => {
  const missingItems = queue.items.filter((it) => it.reviewReasonKeys.includes('contentMissing'));
  assert.ok(missingItems.length > 0, 'expected at least one contentMissing item in this dataset');
  for (const item of missingItems) {
    const recipe = recipesById.get(item.entryId);
    assert.equal(recipe.contentMissing, true);
    const pageBoundaryNotes = (recipe.uncertainties || [])
      .filter((u) => u.type === 'page-boundary')
      .map((u) => `${u.rawText || ''} ${u.treatment || ''}`);
    assert.ok(pageBoundaryNotes.length > 0, `${item.entryId} should carry a page-boundary uncertainty`);
    for (const note of pageBoundaryNotes) {
      assert.ok(
        !/原书.*(缺页|遗漏)|book.*missing/i.test(note) || /不对成因作出判断|不断言/.test(note),
        `${item.entryId} contentMissing note must not assert original-book page loss without a hedge: ${note}`,
      );
    }
  }
});

test('review queue metadata confirms no promotion/crosswalk was performed', () => {
  assert.equal(queue.scope.crosswalkOrPromotionPerformed, false);
});
