#!/usr/bin/env node
// Appends the Batch 9 entry to the production promotions ledger, keeping
// Batch 1-8's records untouched. Field shapes mirror the existing Batch 1-8
// ledger entries exactly (entryId/productionId/name/sourceQuality/
// originalClassification/promotedFromDryRun/provenanceRecord/
// productionTargets).

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..', '..', '..');

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(path.join(repoRoot, relativePath), 'utf8'),
);

const ledgerPath = path.join(repoRoot, 'data', 'source-restoration', 'dazhong-chuancai-1979-production-promotions.v1.json');
const ledger = readJson('data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json');
const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch9-dry-run.v1.json');

if (ledger.batches.some((batch) => batch.batchId === 'dz1979-production-b09')) {
  console.error('dz1979-production-b09 already exists in the ledger. Aborting.');
  process.exit(1);
}
const expectedBatchIds = [
  'dz1979-production-b01',
  'dz1979-production-b02',
  'dz1979-production-b03',
  'dz1979-production-b04',
  'dz1979-production-b05',
  'dz1979-production-b06',
  'dz1979-production-b07',
  'dz1979-production-b08',
];
if (ledger.batches.length !== expectedBatchIds.length
  || ledger.batches.some((batch, i) => batch.batchId !== expectedBatchIds[i])) {
  console.error('Ledger does not contain exactly the expected Batch 1-8 entries. Aborting.');
  process.exit(1);
}

const BASELINE_COMMIT = '532f19f37d76193e266bfd459d78a07cbeebf032';

const batch9Entries = dryRun.items.map((item) => ({
  entryId: item.entryId,
  productionId: item.productionId,
  name: item.name,
  sourceQuality: item.provenanceRecord.sourceQuality,
  originalClassification: item.provenanceRecord.classification,
  promotedFromDryRun: true,
  provenanceRecord: {
    entryId: item.provenanceRecord.entryId,
    bookName: item.provenanceRecord.bookName,
    bookPage: item.provenanceRecord.bookPage,
    pdfPage: item.provenanceRecord.pdfPage,
    category: item.provenanceRecord.category,
    sourceFile: item.provenanceRecord.sourceFile,
  },
  productionTargets: [
    'recipe-completion-overlay.json',
    'sichuan-recipes.curated.json',
  ],
}));

const nextLedger = {
  ...ledger,
  batches: [
    ...ledger.batches,
    {
      batchId: 'dz1979-production-b09',
      status: 'promoted',
      baselineCommit: BASELINE_COMMIT,
      dryRunArtifact: 'data/source-restoration/dazhong-chuancai-1979-promotion-batch9-dry-run.v1.json',
      quantityReviewArtifact: 'data/source-restoration/dazhong-chuancai-1979-promotion-batch9-quantity-review.v1.json',
      entries: batch9Entries,
    },
  ],
};

// applicationReady / partialPromotion must stay exactly as before.
if (nextLedger.applicationReady !== false || nextLedger.partialPromotion !== true) {
  console.error('Ledger applicationReady/partialPromotion invariants violated. Aborting.');
  process.exit(1);
}

fs.writeFileSync(ledgerPath, `${JSON.stringify(nextLedger, null, 2)}\n`);

console.log(`Ledger updated: ${ledger.batches.length} -> ${nextLedger.batches.length} batches.`);
console.log(`Batch 9 entries: ${batch9Entries.map((e) => e.productionId).join(', ')}`);
