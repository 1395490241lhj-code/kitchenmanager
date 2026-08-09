#!/usr/bin/env node
// Appends Batch 11 to the ledger and mechanically marks its three readiness entries promoted.

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const readJson = (file) => JSON.parse(fs.readFileSync(path.join(repoRoot, file), 'utf8'));
const ledgerPath = 'data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json';
const readinessPath = 'data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json';
const ledger = readJson(ledgerPath);
const readiness = readJson(readinessPath);
const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch11-dry-run.v1.json');
const ids = ['dz1979-p222', 'dz1979-p226', 'dz1979-p224'];
const expectedBatches = Array.from({ length: 10 }, (_, index) => `dz1979-production-b${String(index + 1).padStart(2, '0')}`);
const fail = (message) => { throw new Error(message); };

if (JSON.stringify(dryRun.items.map((item) => item.entryId)) !== JSON.stringify(ids) || dryRun.verificationProblems.length) fail('Frozen Batch11 mismatch.');
if (ledger.batches.some((batch) => batch.batchId === 'dz1979-production-b11')
  || JSON.stringify(ledger.batches.map((batch) => batch.batchId)) !== JSON.stringify(expectedBatches)) fail('Ledger baseline mismatch.');
if (readiness.summary.promotedNewRecipeCount !== 36
  || readiness.summary.remainingNewRecipeCandidateCount !== 3
  || readiness.applicationReady !== false) fail('Readiness baseline mismatch.');

const readinessById = new Map(readiness.entries.map((entry) => [entry.entryId, entry]));
for (const id of ids) {
  const entry = readinessById.get(id);
  if (entry?.promotionDisposition !== 'new-recipe-candidate' || entry.promotionState !== 'not-promoted') fail(`Readiness entry mismatch: ${id}`);
}
const entries = dryRun.items.map((item) => {
  const source = readinessById.get(item.entryId);
  return {
    entryId: item.entryId,
    productionId: item.productionId,
    name: item.name,
    sourceQuality: source.sourceQuality,
    originalClassification: source.classification,
    promotedFromDryRun: true,
    provenanceRecord: {
      entryId: item.provenanceRecord.entryId,
      bookName: source.bookName,
      bookPage: item.provenanceRecord.bookPage,
      pdfPage: item.provenanceRecord.pdfPage,
      category: source.category,
      sourceFile: item.provenanceRecord.sourceFile,
    },
    productionTargets: ['recipe-completion-overlay.json', 'sichuan-recipes.curated.json', 'recipe-quantity-semantics.json'],
  };
});
const nextLedger = {
  ...ledger,
  batches: [...ledger.batches, {
    batchId: 'dz1979-production-b11',
    status: 'promoted',
    baselineCommit: '09e8bd44c421b87f435e373f6dad9726acfe3c53',
    dryRunArtifact: 'data/source-restoration/dazhong-chuancai-1979-promotion-batch11-dry-run.v1.json',
    quantityReviewArtifact: 'data/source-restoration/dazhong-chuancai-1979-promotion-batch11-quantity-review.v1.json',
    entries,
  }],
};
if (nextLedger.applicationReady !== false || nextLedger.partialPromotion !== true) fail('Ledger readiness invariant mismatch.');

const ledgerBytes = fs.readFileSync(path.join(repoRoot, ledgerPath));
const readinessBytes = fs.readFileSync(path.join(repoRoot, readinessPath));
try {
  fs.writeFileSync(path.join(repoRoot, ledgerPath), `${JSON.stringify(nextLedger, null, 2)}\n`);
  execFileSync('node', [path.join(repoRoot, 'scripts/build-dazhong-chuancai-promotion-readiness.mjs')], { cwd: repoRoot, stdio: 'pipe' });
  const nextReadiness = readJson(readinessPath);
  if (nextReadiness.summary.promotedNewRecipeCount !== 39
    || nextReadiness.summary.remainingNewRecipeCandidateCount !== 0
    || nextReadiness.applicationReady !== false
    || nextReadiness.productionPromotion !== false) fail('Generated readiness invariant mismatch.');
  console.log('Ledger 10 -> 11 batches; readiness 36/3 -> 39/0; applicationReady=false.');
} catch (error) {
  fs.writeFileSync(path.join(repoRoot, ledgerPath), ledgerBytes);
  fs.writeFileSync(path.join(repoRoot, readinessPath), readinessBytes);
  throw error;
}
