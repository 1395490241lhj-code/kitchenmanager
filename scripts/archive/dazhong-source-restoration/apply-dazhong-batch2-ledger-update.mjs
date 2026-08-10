#!/usr/bin/env node
// Appends the Batch 2 entry to the production promotions ledger, keeping
// Batch 1's record untouched. Field shapes mirror the existing Batch 1
// ledger entry exactly (entryId/productionId/name/sourceQuality/
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
const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch2-dry-run.v1.json');

if (ledger.batches.some((batch) => batch.batchId === 'dz1979-production-b02')) {
  console.error('dz1979-production-b02 already exists in the ledger. Aborting.');
  process.exit(1);
}
if (ledger.batches.length !== 1 || ledger.batches[0].batchId !== 'dz1979-production-b01') {
  console.error('Ledger does not contain exactly the expected Batch 1 entry. Aborting.');
  process.exit(1);
}

const batch2Entries = dryRun.items.map((item) => ({
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
      batchId: 'dz1979-production-b02',
      status: 'promoted',
      baselineCommit: 'f794e475bdd32e9c372ff5abe012b5c75164e988',
      dryRunArtifact: 'data/source-restoration/dazhong-chuancai-1979-promotion-batch2-dry-run.v1.json',
      quantityReviewArtifact: 'data/source-restoration/dazhong-chuancai-1979-promotion-batch2-quantity-review.v1.json',
      entries: batch2Entries,
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
console.log(`Batch 2 entries: ${batch2Entries.map((e) => e.productionId).join(', ')}`);
