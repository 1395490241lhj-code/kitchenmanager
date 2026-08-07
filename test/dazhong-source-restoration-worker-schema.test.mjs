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

// These entries have the same "unexplained gloss for an unresolved glyph"
// shape that dz1979-b10-p197 was found to have and was fixed for in the
// 2026-08-06 legacy-metadata cleanup, but each is out of THIS task's
// explicitly approved scope (only dz1979-b09-p177/p179/p193/p184/p181 and
// the b07-p149/b08-p157 uncertainty *shape* were named as fixes to make).
// Left untouched here and called out in the final report as follow-up
// candidates rather than silently fixed or silently ignored:
//  - b07-p149 "炬": modernSummary asserts a resolved meaning for a glyph
//    the uncertainty entry says is genuinely unclear (only p149's
//    uncertainty *object shape* was in scope for this task, not this
//    gloss content).
//  - b09-p184 "余两次": dialectOrOldTerms entry is missing the standard
//    confidence/modernSummary fields entirely (only p184's non-standard
//    uncertainty.type was in scope for this task).
//  - b09-p194 "烧至芋头炬时": same pattern as b10-p197 (medium confidence,
//    modernSummary + step-text bracket gloss for an unconfirmed glyph).
const uncorroboratedGlossExceptions = new Set([
  'dz1979-b07-worker.json:dz1979-p149',
  'dz1979-b09-worker.json:dz1979-p184',
  'dz1979-b09-worker.json:dz1979-p194',
]);

// As of the 2026-08-06 legacy-metadata cleanup, every batch worker file on
// disk (b05-b10) uses the standard schema shapes with no remaining
// allowlisted exceptions. Any drift found from here on should be fixed at
// the source rather than reintroducing a whitelist.

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

      // A dialect/old-term entry that is also the subject of an
      // unclear-glyph uncertainty (i.e. the raw character itself is not
      // confirmed, not just its modern meaning) must not carry a
      // modernSummary gloss, and the raw term must not appear in a step's
      // summary text wrapped in an explanatory "（...）" that was not
      // actually printed on the source page. This is narrower than "any
      // medium/low-confidence term" because plenty of legitimately
      // medium-confidence glosses (e.g. period vocabulary whose glyph is
      // clear but whose precise modern equivalent is inferred) are fine;
      // the drift this guards against is specifically inventing a
      // resolved-sounding gloss for a character the source itself could
      // not visually confirm.
      if (!uncorroboratedGlossExceptions.has(label)) {
        const unclearGlyphRawTexts = recipe.uncertainties
          .filter((u) => u.type === 'unclear-glyph')
          .map((u) => u.rawText);
        for (const term of recipe.methodSummary.dialectOrOldTerms) {
          const tiedToUnclearGlyph = unclearGlyphRawTexts
            .some((rawText) => rawText.includes(term.raw) || term.raw.includes(rawText));
          if (tiedToUnclearGlyph) {
            assert.equal(term.modernSummary, null,
              `${label} unresolved-glyph dialect term '${term.raw}' must not carry a modernSummary gloss`);
            for (const step of recipe.methodSummary.steps) {
              assert.ok(!step.summary.includes(`${term.raw}（`),
                `${label} step summary must not append an unauthenticated bracket gloss after unresolved-glyph term '${term.raw}'`);
            }
          }
        }
      }
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
        assert.ok(!printedNames.has(moi.rawItemText),
          `${label} methodOnlyIngredients must not duplicate printed ingredient '${moi.rawItemText}'`);
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
      assert.ok(allowedProjectClassifications.has(recipe.projectMatch.classification),
        `${label} projectMatch.classification '${recipe.projectMatch.classification}' is not a standard value`);
      assert.equal(typeof recipe.projectMatch.reviewRequired, 'boolean',
        `${label} projectMatch.reviewRequired must be boolean`);
      if (recipe.projectMatch.classification === 'probable-match-needs-review') {
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
