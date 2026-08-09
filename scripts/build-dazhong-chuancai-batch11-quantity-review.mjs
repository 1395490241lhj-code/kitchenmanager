#!/usr/bin/env node
// Copies only base input qty/unit records from the frozen Batch11 dry-run.
// consumed semantics remain exclusively in proposedQuantitySemanticsSidecar.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const readJson = (file) => JSON.parse(fs.readFileSync(path.join(repoRoot, file), 'utf8'));
const dryRunFile = 'data/source-restoration/dazhong-chuancai-1979-promotion-batch11-dry-run.v1.json';
const dryRun = readJson(dryRunFile);
const records = dryRun.quantityReviewPreview.records.map((record) => ({ ...record }));
const problems = [];
const keys = new Set();

for (const record of records) {
  const key = `${record.productionId}:${record.item}`;
  if (keys.has(key)) problems.push(`duplicate-key:${key}`);
  keys.add(key);
  if (!Number.isFinite(Number(record.qty)) || Number(record.qty) <= 0 || !record.unit) {
    problems.push(`invalid-qty-unit:${key}`);
  }
  if (!['exact-mass', 'exact-count'].includes(record.normalizedQuantity?.kind)) {
    problems.push(`non-exact-kind:${key}`);
  }
  if (record.qty !== String(record.normalizedQuantity?.qty)) problems.push(`qty-not-input:${key}`);
  if (Object.keys(record.normalizedQuantity ?? {}).some((field) => field.startsWith('consumed'))
    || Object.keys(record).some((field) => field.startsWith('consumed'))) {
    problems.push(`consumed-field-leak:${key}`);
  }
  if (record.evidenceType !== 'source-restoration' || record.reviewStatus !== 'approved') {
    problems.push(`unapproved-record:${key}`);
  }
}
if (records.length !== dryRun.quantityReviewPreview.recordCount) problems.push('record-count-mismatch');
if (dryRun.sidecarValidation?.valid !== true || dryRun.sidecarValidation.joins.length !== 4) {
  problems.push('sidecar-validation-not-frozen');
}

const unitCounts = {};
for (const record of records) unitCounts[record.unit] = (unitCounts[record.unit] ?? 0) + 1;
const output = {
  schema: 'kitchenmanager.source-restoration.promotion-batch11-quantity-review.v1',
  generatedAt: new Date().toISOString().slice(0, 10),
  purpose: 'Batch11 proposed base production qty/unit source-restoration review. All values are copied mechanically from dry-run input records; consumed semantics are excluded and remain in the proposed sidecar.',
  applicationReady: false,
  evidencePolicy: 'qty/unit means source-backed required input; consumed 100/200g is not a quantity-review field.',
  dryRunArtifact: dryRunFile,
  proposedSidecarLocation: `${dryRunFile}#proposedQuantitySemanticsSidecar`,
  summary: {
    recordCount: records.length,
    unitCounts,
    productionRecipeCount: new Set(records.map((record) => record.productionId)).size,
    keys: [...keys].sort(),
  },
  records,
  verificationProblems: problems,
};

const outPath = path.join(
  repoRoot,
  'data/source-restoration/dazhong-chuancai-1979-promotion-batch11-quantity-review.v1.json',
);
fs.writeFileSync(outPath, `${JSON.stringify(output, null, 2)}\n`);
console.log(`Wrote ${outPath}`);
console.log(`records: ${records.length}, units: ${JSON.stringify(unitCounts)}`);
console.log(`verificationProblems: ${problems.length}`);
if (problems.length > 0) process.exitCode = 1;
