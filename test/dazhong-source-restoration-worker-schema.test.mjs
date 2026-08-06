import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

// This test guards the raw per-batch worker JSON files against the schema
// drift documented for batch dz1979-b10 (2026-08-06): a worker file that
// uses ad hoc shapes (methodSummary as a bare array, a legacy
// methodOnlyMentions field, snake_case projectMatch.classification values,
// top-level reviewRequired/contentIncomplete) can still make it through the
// assembler, because the assembler recomputes projectMatch and only
// validates a subset of fields. Worker files are the source of truth that
// downstream chunk regeneration and manual review rely on, so they must
// independently match docs/DAZHONG_CHUANCAI_1979_EXTRACTION_SCHEMA.md.
//
// Only batches with a worker JSON file checked into the repo are covered
// here (dz1979-b05 through dz1979-b10 as of this writing). Earlier batches
// (b01-b04) were assembled without leaving a standalone worker file on
// disk, so they are covered indirectly by the assembled-output tests in
// dazhong-source-restoration-recipes.test.mjs instead.

const workerDir = new URL('../data/source-restoration/', import.meta.url);
const workerFiles = fs.readdirSync(workerDir)
  .filter((name) => /^dz1979-b\d+-worker\.json$/.test(name))
  .sort();

assert.ok(workerFiles.length >= 6, 'expected at least the b05-b10 worker files to exist');

const readJson = (name) => JSON.parse(
  fs.readFileSync(new URL(name, workerDir), 'utf8'),
);

const allowedProjectClassifications = new Set([
  'exact-name',
  'confirmed-alias',
  'probable-match-needs-review',
  'book-only',
]);

const allowedUncertaintyTypes = new Set([
  'unclear-glyph',
  'unresolved-quantity',
  'allocation-unknown',
  'old-term',
  'page-boundary',
]);

// Pre-existing schema drift found in b05-b09 worker files during the
// 2026-08-06 b10 schema-normalization audit. These batches are out of scope
// for this fix (the task instructs not to touch b01-b09 without a separate,
// explicitly approved follow-up), so their known issues are allowlisted here
// by entryId + field rather than silently loosening the checks for every
// batch. Any NEW drift, in these batches or any other, still fails the test.
const legacyProjectClassificationExceptions = new Set([
  'dz1979-b09-worker.json:dz1979-p177', // projectMatch.classification 'suspected_match' (snake_case legacy value)
  'dz1979-b09-worker.json:dz1979-p179', // projectMatch.classification 'exact_name' (snake_case legacy value)
  'dz1979-b09-worker.json:dz1979-p193', // projectMatch.classification 'exact_name' (snake_case legacy value)
]);
const legacyUncertaintyShapeExceptions = new Set([
  'dz1979-b07-worker.json:dz1979-p149', // uncertainty object uses {raw,location,reasonCode,notes} instead of {location,type,rawText,candidates,treatment}
  'dz1979-b08-worker.json:dz1979-p157', // same legacy {raw,location,reasonCode,notes} shape
  'dz1979-b09-worker.json:dz1979-p184', // uncertainty.type 'ingredient-mismatch' is not a standard schema value
]);
// A printed ingredient (盐) also gets an explicit "另加盐少许" mention in the
// method text for a distinct, separately-quantified use; the extraction
// schema does not have a field for "same ingredient, a second unlisted
// use", so this was recorded as a second methodOnlyIngredients entry. Left
// as-is rather than silently deleted, since deleting it would erase a real
// visually-confirmed fact; flagged here so it is not mistaken for new drift.
const legacyMethodOnlyDuplicateExceptions = new Set([
  'dz1979-b09-worker.json:dz1979-p181',
]);

for (const fileName of workerFiles) {
  test(`${fileName} recipes use the standard extraction schema shapes`, () => {
    const worker = readJson(fileName);
    assert.equal(worker.applicationReady, false, `${fileName} must stay applicationReady=false`);
    assert.ok(Array.isArray(worker.recipes), `${fileName}.recipes must be an array`);
    assert.ok(worker.recipes.length > 0, `${fileName}.recipes must be non-empty`);

    for (const recipe of worker.recipes) {
      const label = `${fileName}:${recipe.entryId}`;
      const contentMissingVerified = recipe.contentMissing === true
        && Array.isArray(recipe.uncertainties)
        && recipe.uncertainties.some((u) => u.type === 'page-boundary');
      const contentIncompleteVerified = recipe.contentIncomplete === true
        && recipe.contentMissing !== true
        && Array.isArray(recipe.uncertainties)
        && recipe.uncertainties.some((u) => u.type === 'page-boundary');
      // A verified page-boundary exception (fully blank scan, or a
      // genuinely truncated printed page) has no reliable conversion
      // confidence to report for the missing portion.
      const relaxedConfidence = contentMissingVerified || contentIncompleteVerified;

      // methodSummary must be the standard { steps, dialectOrOldTerms,
      // confidence } object, not a bare array of strings/objects.
      assert.equal(typeof recipe.methodSummary, 'object', `${label} methodSummary must be an object`);
      assert.ok(!Array.isArray(recipe.methodSummary), `${label} methodSummary must not be a bare array`);
      assert.ok(Array.isArray(recipe.methodSummary.steps), `${label} methodSummary.steps must be an array`);
      for (const step of recipe.methodSummary.steps) {
        assert.equal(typeof step, 'object', `${label} each method step must be an object`);
        assert.equal(typeof step.order, 'number', `${label} step.order must be a number`);
        assert.equal(typeof step.summary, 'string', `${label} step.summary must be a string`);
        assert.ok(step.summary.trim() !== '', `${label} step.summary must be non-empty`);
        assert.ok(Array.isArray(step.measureMentions), `${label} step.measureMentions must be an array`);
      }
      assert.ok(Array.isArray(recipe.methodSummary.dialectOrOldTerms),
        `${label} methodSummary.dialectOrOldTerms must be an array`);
      if (relaxedConfidence) {
        // A verified fully-blank scanned page has nothing to be confident
        // about; confidence may legitimately be null in this narrow case.
        assert.ok(recipe.methodSummary.confidence === null
          || ['high', 'medium', 'low'].includes(recipe.methodSummary.confidence),
          `${label} methodSummary.confidence must be null or high/medium/low for a verified-missing page`);
      } else {
        assert.ok(['high', 'medium', 'low'].includes(recipe.methodSummary.confidence),
          `${label} methodSummary.confidence must be high/medium/low`);
      }

      // The legacy methodOnlyMentions field must not linger; the standard
      // field name is methodOnlyIngredients.
      assert.equal(recipe.methodOnlyMentions, undefined,
        `${label} must not carry legacy methodOnlyMentions (use methodOnlyIngredients)`);
      assert.ok(Array.isArray(recipe.methodOnlyIngredients),
        `${label} methodOnlyIngredients must be an array`);

      // methodOnlyIngredients must not duplicate an ingredient that is
      // already printed in the ingredients column; a raw item that already
      // has a printed-column entry belongs in the step text / a
      // confirmedReadings note, not in methodOnlyIngredients, unless it is a
      // genuinely separate use (schema explicitly scopes this field to
      // "原料栏未列、只在做法中出现的可食用内容").
      const printedNames = new Set(recipe.ingredients.map((i) => i.rawItemText));
      for (const moi of recipe.methodOnlyIngredients) {
        if (!legacyMethodOnlyDuplicateExceptions.has(label)) {
          assert.ok(!printedNames.has(moi.rawItemText),
            `${label} methodOnlyIngredients must not duplicate printed ingredient '${moi.rawItemText}'`);
        }
        assert.equal(typeof moi.rawItemText, 'string');
        assert.equal(typeof moi.use, 'string');
        assert.equal(typeof moi.quantityHandling, 'string');
        assert.ok(['high', 'medium', 'low'].includes(moi.confidence));
      }

      // reviewRequired is only valid inside projectMatch; it must never
      // appear as a top-level recipe field (that was the b10 drift).
      assert.equal(recipe.reviewRequired, undefined,
        `${label} must not carry a top-level reviewRequired field`);

      // projectMatch and confidence are required top-level objects.
      assert.equal(typeof recipe.projectMatch, 'object', `${label} projectMatch must be an object`);
      assert.ok(recipe.projectMatch, `${label} projectMatch must be present`);
      if (!legacyProjectClassificationExceptions.has(label)) {
        assert.ok(allowedProjectClassifications.has(recipe.projectMatch.classification),
          `${label} projectMatch.classification '${recipe.projectMatch.classification}' is not a standard value`);
      }
      assert.equal(typeof recipe.projectMatch.reviewRequired, 'boolean',
        `${label} projectMatch.reviewRequired must be boolean`);
      if (!legacyProjectClassificationExceptions.has(label)
        && recipe.projectMatch.classification === 'probable-match-needs-review') {
        assert.equal(recipe.projectMatch.projectName, null,
          `${label} probable-match-needs-review must not bind a projectName`);
        assert.deepEqual(recipe.projectMatch.projectIds, [],
          `${label} probable-match-needs-review must not bind projectIds`);
        assert.ok(recipe.projectMatch.candidateProjectName,
          `${label} probable-match-needs-review must carry a candidateProjectName`);
      }

      assert.equal(typeof recipe.confidence, 'object', `${label} confidence must be an object`);
      if (relaxedConfidence) {
        assert.ok(recipe.confidence.recognition === null
          || ['high', 'medium', 'low'].includes(recipe.confidence.recognition));
        assert.ok(recipe.confidence.conversion === null
          || ['high', 'medium', 'low', 'unresolved'].includes(recipe.confidence.conversion));
      } else {
        assert.ok(['high', 'medium', 'low'].includes(recipe.confidence.recognition));
        assert.ok(['high', 'medium', 'low', 'unresolved'].includes(recipe.confidence.conversion));
      }

      // nonIngredientMaterials must carry all five standard arrays.
      assert.equal(typeof recipe.nonIngredientMaterials, 'object',
        `${label} nonIngredientMaterials must be an object`);
      for (const key of ['tools', 'containers', 'fuels', 'cleaningMaterials', 'nonEdiblePackaging']) {
        assert.ok(Array.isArray(recipe.nonIngredientMaterials?.[key]),
          `${label} nonIngredientMaterials.${key} must be an array`);
      }

      assert.ok(Array.isArray(recipe.confirmedReadings), `${label} confirmedReadings must be an array`);
      assert.ok(Array.isArray(recipe.uncertainties), `${label} uncertainties must be an array`);
      for (const uncertainty of recipe.uncertainties) {
        if (legacyUncertaintyShapeExceptions.has(label)) {
          continue;
        }
        assert.ok(allowedUncertaintyTypes.has(uncertainty.type),
          `${label} uncertainty.type '${uncertainty.type}' is not a standard value`);
        assert.equal(typeof uncertainty.location, 'string');
        assert.equal(typeof uncertainty.rawText, 'string');
        assert.ok(Array.isArray(uncertainty.candidates));
        assert.equal(typeof uncertainty.treatment, 'string');
      }

      // contentIncomplete/contentMissing, when present, must be booleans,
      // never left as stray non-boolean sentinel values.
      if ('contentIncomplete' in recipe) {
        assert.equal(typeof recipe.contentIncomplete, 'boolean', `${label} contentIncomplete must be boolean`);
      }
      if ('contentMissing' in recipe) {
        assert.equal(typeof recipe.contentMissing, 'boolean', `${label} contentMissing must be boolean`);
      }
    }
  });
}
