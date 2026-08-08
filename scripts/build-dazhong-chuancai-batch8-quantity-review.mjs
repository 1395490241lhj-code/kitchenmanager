#!/usr/bin/env node
// Builds the Batch 8 quantity review artifact by mechanically extracting
// every qty/unit ingredient from the frozen Batch 8 dry-run's
// quantityReviewPreview. The records are the source-restoration-backed
// reviewed quantities that make the promoted curated ingredient qty/unit
// entries eligible for the runtime qty/unit allowlist. No qty/unit value is
// recomputed here; every field is copied verbatim from the frozen dry-run.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(path.join(repoRoot, relativePath), 'utf8'),
);

const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch8-dry-run.v1.json');

const records = dryRun.quantityReviewPreview.records.map((record) => ({
  entryId: record.entryId,
  productionId: record.productionId,
  recipeName: record.recipeName,
  item: record.item,
  qty: record.qty,
  unit: record.unit,
  evidenceType: record.evidenceType,
  canonicalSourceFile: record.canonicalSourceFile,
  sourceRawQuantityText: record.sourceRawQuantityText,
  normalizedQuantity: record.normalizedQuantity,
  dryRunArtifact: 'data/source-restoration/dazhong-chuancai-1979-promotion-batch8-dry-run.v1.json',
  reviewStatus: record.reviewStatus,
}));

// -- Verification ------------------------------------------------------------

const problems = [];
const expectedRecordCount = dryRun.quantityReviewPreview.recordCount;
if (records.length !== expectedRecordCount) problems.push(`record-count-mismatch:${records.length}!=${expectedRecordCount}`);

const keys = new Set();
for (const record of records) {
  const key = `${record.productionId}:${record.item}`;
  if (keys.has(key)) problems.push(`duplicate-key:${key}`);
  keys.add(key);
  if (record.qty === null || record.unit === null) problems.push(`missing-qty-unit:${key}`);
  if (record.evidenceType !== 'source-restoration') problems.push(`evidence-type-not-source-restoration:${key}`);
  if (record.reviewStatus !== 'approved') problems.push(`review-status-not-approved:${key}`);
  if (!['exact-mass', 'exact-count'].includes(record.normalizedQuantity.kind)) {
    problems.push(`non-exact-kind:${key}:${record.normalizedQuantity.kind}`);
  }
  if (record.normalizedQuantity.kind === 'exact-mass' && record.unit !== 'g') {
    problems.push(`exact-mass-not-g:${key}:${record.unit}`);
  }
  if (record.normalizedQuantity.kind === 'exact-count' && !record.unit) {
    problems.push(`exact-count-no-unit:${key}`);
  }
  const expectedQty = String(record.normalizedQuantity.qty);
  if (record.qty !== expectedQty) problems.push(`qty-recomputed:${key}:${record.qty}!=${expectedQty}`);
  if (!/^(g|ml|个|只|颗|枚|根|条|片|块|瓣|张|把|棵|头|支|份|盒|袋|包|瓶|罐|听)$/.test(record.unit)) {
    problems.push(`unit-not-whitelisted:${key}:${record.unit}`);
  }
  // Cross-check against the frozen dry-run source values field-for-field.
  const source = dryRun.quantityReviewPreview.records.find((r) => (
    r.productionId === record.productionId && r.item === record.item
  ));
  if (!source) {
    problems.push(`missing-dry-run-source:${key}`);
  } else {
    if (source.qty !== record.qty) problems.push(`qty-mismatch-vs-dry-run:${key}`);
    if (source.unit !== record.unit) problems.push(`unit-mismatch-vs-dry-run:${key}`);
    if (source.sourceRawQuantityText !== record.sourceRawQuantityText) problems.push(`raw-text-mismatch-vs-dry-run:${key}`);
    if (JSON.stringify(source.normalizedQuantity) !== JSON.stringify(record.normalizedQuantity)) {
      problems.push(`normalized-quantity-mismatch-vs-dry-run:${key}`);
    }
  }
}

const productionIdsInBatch = new Set(records.map((r) => r.productionId));
const expectedProductionIdCount = dryRun.selection.selectedEntryIds.length;
if (productionIdsInBatch.size !== expectedProductionIdCount) problems.push(`production-ids-count-mismatch:${productionIdsInBatch.size}!=${expectedProductionIdCount}`);

const unitCounts = {};
for (const record of records) {
  unitCounts[record.unit] = (unitCounts[record.unit] ?? 0) + 1;
}

const output = {
  schema: 'kitchenmanager.source-restoration.promotion-batch8-quantity-review.v1',
  generatedAt: new Date().toISOString().slice(0, 10),
  purpose: 'Batch 8 promotion 引入的 curated qty/unit 的 source-restoration-reviewed 登记。qty/unit 逐字段取自冻结 Batch 8 dry-run quantityReviewPreview.records，raw/normalized 数量取自 canonical source，evidenceType=source-restoration。不重新推算、不手改数值。',
  applicationReady: false,
  evidencePolicy: '证据来源为已审阅 source-restoration canonical quantity，不声称来自 production method 文本。',
  summary: {
    recordCount: records.length,
    unitCounts,
    keys: [...keys].sort(),
  },
  records,
  verificationProblems: problems,
};

const outPath = path.join(
  repoRoot,
  'data/source-restoration/dazhong-chuancai-1979-promotion-batch8-quantity-review.v1.json',
);
fs.writeFileSync(outPath, `${JSON.stringify(output, null, 2)}\n`);

console.log(`Wrote ${outPath}`);
console.log(`records: ${records.length}, units: ${JSON.stringify(unitCounts)}`);
console.log(`verificationProblems: ${problems.length}`);
if (problems.length > 0) {
  console.log(problems);
  process.exitCode = 1;
}
