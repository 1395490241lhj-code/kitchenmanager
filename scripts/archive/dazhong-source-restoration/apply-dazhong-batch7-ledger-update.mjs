#!/usr/bin/env node
// Appends the Batch 7 entry to the production promotions ledger, keeping
// Batch 1/2/3/4/5/6's records untouched. Field shapes mirror the existing
// Batch 1-4 ledger entries exactly (entryId/productionId/name/sourceQuality/
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
const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch7-dry-run.v1.json');

if (ledger.batches.some((batch) => batch.batchId === 'dz1979-production-b07')) {
  console.error('dz1979-production-b07 already exists in the ledger. Aborting.');
  process.exit(1);
}
if (ledger.batches.length !== 6
  || ledger.batches[0].batchId !== 'dz1979-production-b01'
  || ledger.batches[1].batchId !== 'dz1979-production-b02'
  || ledger.batches[2].batchId !== 'dz1979-production-b03'
  || ledger.batches[3].batchId !== 'dz1979-production-b04'
  || ledger.batches[4].batchId !== 'dz1979-production-b05'
  || ledger.batches[5].batchId !== 'dz1979-production-b06') {
  console.error('Ledger does not contain exactly the expected Batch 1-6 entries. Aborting.');
  process.exit(1);
}

const BASELINE_COMMIT = '241b760c033dcc4b29352623665b274d5c6a84ff';

const batch7Entries = dryRun.items.map((item) => ({
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
      batchId: 'dz1979-production-b07',
      status: 'promoted',
      baselineCommit: BASELINE_COMMIT,
      dryRunArtifact: 'data/source-restoration/dazhong-chuancai-1979-promotion-batch7-dry-run.v1.json',
      quantityReviewArtifact: 'data/source-restoration/dazhong-chuancai-1979-promotion-batch7-quantity-review.v1.json',
      entries: batch7Entries,
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
console.log(`Batch 7 entries: ${batch7Entries.map((e) => e.productionId).join(', ')}`);
