import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { assertValidRecipeQuantitySemantics } from '../scripts/recipe-quantity-semantics.mjs';

const repoRoot = path.resolve(new URL('..', import.meta.url).pathname);
const readJson = (file) => JSON.parse(fs.readFileSync(path.join(repoRoot, file), 'utf8'));
const auditFile = 'data/source-restoration/dazhong-chuancai-1979-closeout-audit.v1.json';
const audit = readJson(auditFile);
const readiness = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-readiness.v1.json');
const ledger = readJson('data/source-restoration/dazhong-chuancai-1979-production-promotions.v1.json');
const curated = readJson('data/sichuan-recipes.curated.json');
const sidecar = readJson('data/recipe-quantity-semantics.json');

test('closeout is baseline-pinned, problem-free, and distinguishes its three final states', () => {
  assert.equal(audit.schema, 'kitchenmanager.source-restoration.closeout-audit.v1');
  assert.equal(audit.baseline.commit, '0116009dfd35f1fde3eeedcee9bae1771d8db965');
  assert.deepEqual(audit.verificationProblems, []);
  assert.equal(audit.promotionComplete, true);
  assert.equal(audit.sourceRestorationComplete, true);
  assert.equal(audit.applicationReady, false);
  assert.match(audit.finalStatusDefinitions.sourceRestorationComplete, /147/);
  assert.match(audit.finalStatusDefinitions.applicationReady, /direct application/);
});

test('147 accounting matrix is an exact unique partition of readiness', () => {
  const expected = {
    'existing-project-match': 50,
    'promoted-new-recipe-candidate': 39,
    'blocked-source-review': 45,
    'blocked-alternate-source': 12,
    'blocked-crosswalk': 1,
  };
  assert.deepEqual(Object.fromEntries(audit.accounting.matrix.map((row) => [row.status, row.count])), expected);
  const ids = audit.accounting.matrix.flatMap((row) => row.entryIds);
  assert.equal(ids.length, 147);
  assert.equal(new Set(ids).size, 147);
  assert.deepEqual(new Set(ids), new Set(readiness.entries.map((entry) => entry.entryId)));
  assert.equal(readiness.summary.promotedNewRecipeCount, 39);
  assert.equal(readiness.summary.remainingNewRecipeCandidateCount, 0);
});

test('Batch1-11 baseline chain and frozen promotion evidence close exactly 39 recipes', () => {
  assert.equal(audit.promotionSummary.batchCount, 11);
  assert.equal(audit.promotionSummary.promotedRecipeCount, 39);
  assert.equal(audit.promotionSummary.baselineChainValid, true);
  assert.deepEqual(audit.promotionSummary.batches.map((batch) => batch.batchId), Array.from(
    { length: 11 }, (_, index) => `dz1979-production-b${String(index + 1).padStart(2, '0')}`,
  ));
  assert.equal(audit.promotionSummary.batches.reduce((sum, batch) => sum + batch.entryCount, 0), 39);
  assert.equal(audit.promotionSummary.batches.reduce((sum, batch) => sum + batch.quantityReviewRecordCount, 0), 294);
  assert.ok(audit.promotionSummary.batches.every((batch) => (
    batch.baselineExists
    && batch.baselineAncestorOfPromotion
    && batch.previousPromotionAncestorOfBaseline
    && batch.dryRunBaselineAncestorOfLedgerBaseline
  )));
  assert.deepEqual(ledger.batches.map((batch) => batch.entries.map((entry) => entry.entryId)), audit.promotionSummary.batches.map((batch) => batch.entryIds));
});

test('production, reviewed quantities, narrow nulls, runtime baseline, and sidecar are exact', () => {
  assert.equal(audit.productionIntegrity.curatedCount, 165);
  assert.equal(audit.productionIntegrity.fullCount, 264);
  assert.equal(audit.productionIntegrity.exactPromotedDelta, 39);
  assert.equal(audit.productionIntegrity.existingPrePromotionRecipesAndMapsUnchanged, true);
  assert.ok(audit.productionIntegrity.prePromotionStableFiles.every((entry) => entry.byteEqual));
  assert.ok(audit.productionIntegrity.baselineIntegrity.every((entry) => entry.byteEqual));
  assert.equal(audit.quantityPolicy.promotedIngredientRowCount, 300);
  assert.equal(audit.quantityPolicy.sourceRestorationReviewedRecordCount, 294);
  assert.equal(audit.quantityPolicy.approvedNullCount, 6);
  assert.equal(audit.quantityPolicy.consumedFieldsAbsentFromBaseAndQuantityReview, true);
  assert.equal(audit.sidecarSummary.recipeCount, 3);
  assert.equal(audit.sidecarSummary.dualRecordCount, 4);
  assert.equal(audit.sidecarSummary.currentPwaIosConsumersLoadSidecar, false);
  assert.deepEqual(audit.sidecarSummary.consumerReferenceFiles, []);
  assert.equal(assertValidRecipeQuantitySemantics(sidecar, curated).joins.length, 4);
});

test('58 unresolved entries are final current-scan dispositions with explicit reopening work', () => {
  assert.equal(audit.unresolvedSourceLimitations.totalCount, 58);
  assert.equal(audit.unresolvedSourceLimitations.blockedSourceReview.count, 45);
  assert.equal(audit.unresolvedSourceLimitations.blockedSourceReview.entriesWithRecordedUncertainty, 22);
  assert.equal(audit.unresolvedSourceLimitations.blockedAlternateSource.count, 12);
  assert.equal(audit.unresolvedSourceLimitations.blockedAlternateSource.contentMissingCount, 3);
  assert.equal(audit.unresolvedSourceLimitations.blockedAlternateSource.contentIncompleteCount, 6);
  assert.equal(audit.unresolvedSourceLimitations.blockedAlternateSource.otherSourceGapCount, 3);
  assert.deepEqual(audit.unresolvedSourceLimitations.blockedCrosswalk.entryIds, ['dz1979-p173']);
  assert.deepEqual(audit.remainingFollowUps.map((item) => item.count), [45, 12, 1]);
});

test('status fields retain their original artifact meanings and none is stale', () => {
  assert.deepEqual(Object.fromEntries(Object.entries(audit.statusFieldAudit).map(([key, value]) => [key, value.stale])), {
    ledgerPartialPromotion: false,
    readinessProductionPromotion: false,
    readinessSchemaExtensionNeeded: false,
    readinessApplicationReady: false,
    restorationApplicationReady: false,
  });
  assert.equal(audit.statusFieldAudit.ledgerPartialPromotion.value, true);
  assert.equal(audit.statusFieldAudit.readinessProductionPromotion.value, false);
  assert.equal(audit.statusFieldAudit.readinessSchemaExtensionNeeded.value, false);
  assert.equal(audit.statusFieldAudit.readinessApplicationReady.value, false);
  assert.equal(audit.statusFieldAudit.restorationApplicationReady.value, false);
  assert.ok(audit.historicalArtifactFields.length >= 5);
});

test('generator is deterministic and changes only the two closeout artifacts', () => {
  const artifactFiles = [auditFile, 'data/source-restoration/dazhong-chuancai-1979-closeout-audit.v1.md'];
  const protectedFiles = audit.productionIntegrity.baselineIntegrity.map((entry) => entry.file);
  const beforeArtifacts = artifactFiles.map((file) => fs.readFileSync(path.join(repoRoot, file)));
  const beforeProtected = protectedFiles.map((file) => fs.readFileSync(path.join(repoRoot, file)));
  execFileSync('node', ['scripts/build-dazhong-chuancai-closeout-audit.mjs'], { cwd: repoRoot });
  assert.deepEqual(artifactFiles.map((file) => fs.readFileSync(path.join(repoRoot, file))), beforeArtifacts);
  assert.deepEqual(protectedFiles.map((file) => fs.readFileSync(path.join(repoRoot, file))), beforeProtected);
});

test('the single status document and changelog describe the closeout without claiming 147 promotions', () => {
  const status = fs.readFileSync(path.join(repoRoot, 'PROJECT_STATUS.md'), 'utf8');
  const changelog = fs.readFileSync(path.join(repoRoot, 'CHANGELOG.md'), 'utf8');
  assert.match(status, /39\/39 source-ready new-recipe-candidates were promoted/);
  assert.match(status, /58 remain explicitly blocked/);
  assert.match(status, /applicationReady=false/);
  assert.doesNotMatch(status, /134 recipes remain and batch two has not started/);
  assert.match(changelog, /《大众川菜》1979 source-restoration closeout/);
  assert.doesNotMatch(status, /147 recipes.*promoted/i);
});
