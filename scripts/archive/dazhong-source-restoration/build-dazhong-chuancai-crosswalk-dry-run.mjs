#!/usr/bin/env node
// Builds a dry-run crosswalk between the 147 《大众川菜》1979 source-restoration
// entries and the project's current Curated/Full recipe libraries.
//
// This is READ-ONLY with respect to canonical source-restoration files,
// name-matches, review overlays, and the Curated/Full/HOC recipe libraries.
// It produces one new artifact:
//   data/source-restoration/dazhong-chuancai-1979-crosswalk-dry-run.v1.json
//
// No production promotion, no applicationReady change, no mutation of any
// existing canonical file.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..', '..', '..');

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(path.join(repoRoot, relativePath), 'utf8'),
);

const catalog = readJson('data/source-restoration/dazhong-chuancai-1979-catalog.v1.json');
const recipes = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');
const nameMatches = readJson('data/source-restoration/dazhong-chuancai-1979-name-matches.v1.json');
const r1Results = readJson('data/source-restoration/dazhong-chuancai-1979-review-resolution-r1-results.v1.json');
const r2Results = readJson('data/source-restoration/dazhong-chuancai-1979-review-resolution-r2-results.v1.json');
const applyAudit = readJson('data/source-restoration/dazhong-chuancai-1979-apply-review-resolutions-audit.v1.json');
const probableReview = readJson('data/source-restoration/dazhong-chuancai-1979-crosswalk-probable-review.v1.json');

const curated = readJson('data/sichuan-recipes.curated.json');
const full = readJson('data/sichuan-recipes.json');

const curatedById = new Map(curated.recipes.map((r) => [r.id, r.name]));
const fullById = new Map(full.recipes.map((r) => [r.id, r.name]));

const libraryMapById = { curated: curatedById, full: fullById };

// -- Source-quality gate inputs -------------------------------------------

// B-class: entries the applied-resolutions audit already recorded as
// unchangedByDesign.alternateSourceRequired (12 entries, scan-page-blank /
// unrecoverable page-boundary content that needs an alternate physical
// source, independent of crosswalk classification).
const alternateSourceRequiredIds = new Set(
  applyAudit.unchangedByDesign?.alternateSourceRequired ?? [],
);

// R1/R2 resolutions that ended confirmed-unresolved remain open
// source-fidelity questions independent of the crosswalk mapping.
const r1ConfirmedUnresolvedIds = new Set(
  r1Results.items
    .filter((item) => item.status === 'confirmed-unresolved')
    .map((item) => item.entryId),
);
const r2ConfirmedUnresolvedIds = new Set(
  r2Results.items
    .filter((item) => item.status === 'confirmed-unresolved')
    .map((item) => item.entryId),
);

// Source-quality evaluates ONLY the fidelity of the restored source data:
// content completeness, residual uncertainties, sub-high recognition /
// conversion anywhere, unresolved old-term semantics, and R1/R2
// confirmed-unresolved. Crosswalk classification, candidateProjectName,
// projectMatch.reviewRequired, and unconfirmed name-matches are mapping
// concerns and never become source-quality reasons.
function sourceFidelityReasons(entryId, recipe) {
  const reasons = [];

  if (recipe.contentMissing === true) reasons.push('contentMissing=true');
  if (recipe.contentIncomplete === true) reasons.push('contentIncomplete=true');

  recipe.uncertainties?.forEach((uncertainty, index) => {
    reasons.push(`uncertainties[${index}].type=${uncertainty.type}`);
  });

  const confidence = recipe.confidence ?? {};
  if (confidence.recognition !== 'high') {
    reasons.push(`confidence.recognition=${String(confidence.recognition)}`);
  }
  if (confidence.conversion !== 'high') {
    reasons.push(`confidence.conversion=${String(confidence.conversion)}`);
  }

  const methodSummary = recipe.methodSummary ?? {};
  if (methodSummary.confidence !== 'high') {
    reasons.push(`methodSummary.confidence=${String(methodSummary.confidence)}`);
  }

  const titleVisualCheck = recipe.titleVisualCheck ?? {};
  if (titleVisualCheck.confidence !== 'high') {
    reasons.push(`titleVisualCheck.confidence=${String(titleVisualCheck.confidence)}`);
  }

  recipe.ingredients?.forEach((ingredient, index) => {
    const ingredientConfidence = ingredient.confidence ?? {};
    if (ingredientConfidence.recognition !== 'high') {
      reasons.push(`ingredients[${index}].confidence.recognition=${String(ingredientConfidence.recognition)}`);
    }
    if (ingredientConfidence.conversion !== 'high') {
      reasons.push(`ingredients[${index}].confidence.conversion=${String(ingredientConfidence.conversion)}`);
    }
  });

  methodSummary.dialectOrOldTerms?.forEach((term, index) => {
    if (term.modernSummary === null || term.modernSummary === undefined) {
      reasons.push(`methodSummary.dialectOrOldTerms[${index}].modernSummary=null`);
    }
    if (term.confidence !== 'high') {
      reasons.push(`methodSummary.dialectOrOldTerms[${index}].confidence=${String(term.confidence)}`);
    }
  });

  if (r1ConfirmedUnresolvedIds.has(entryId)) {
    reasons.push('R1-confirmed-unresolved');
  }
  if (r2ConfirmedUnresolvedIds.has(entryId)) {
    reasons.push('R2-confirmed-unresolved');
  }

  return reasons;
}

function sourceQualityFor(entryId, reasons) {
  if (alternateSourceRequiredIds.has(entryId)) return 'alternate-source-required';
  if (reasons.length > 0) return 'needs-source-review';
  return 'ready-for-later-promotion-review';
}

// -- Crosswalk classification (from canonical projectMatch, cross-checked
// against name-matches and real project IDs) ------------------------------

const catalogByEntryId = new Map(catalog.entries.map((e) => [e.entryId, e]));
const nameMatchByEntryId = new Map(nameMatches.bookMatches.map((e) => [e.entryId, e]));

const nameMatchClassificationMap = {
  exact_name: 'exact-name',
  clear_alias: 'confirmed-alias',
  suspected_match: 'probable-match-needs-review',
  book_only: 'book-only',
};

// Body-evidence adjudications from the probable-review artifact. name-matches
// remains the historical name-only baseline; only entries with a high
// confidence confirmed-alias or reject-candidate decision may diverge from
// that baseline in canonical/crosswalk classification.
const adjudicationByEntryId = new Map(
  (probableReview.items ?? []).map((item) => [item.entryId, item]),
);

function isExplainedBaselineDifference(entryId, classification) {
  const adjudication = adjudicationByEntryId.get(entryId);
  if (!adjudication) return false;
  if (classification === 'confirmed-alias') {
    return adjudication.decision === 'confirmed-alias' && adjudication.confidence === 'high';
  }
  if (classification === 'book-only') {
    return adjudication.decision === 'reject-candidate' && adjudication.confidence === 'high';
  }
  return false;
}

function verifyProjectIds(entryId, projectIds) {
  const verified = [];
  const problems = [];
  for (const { library, id } of projectIds) {
    const libMap = libraryMapById[library];
    if (!libMap) {
      problems.push(`unknown-library:${library}`);
      continue;
    }
    if (!libMap.has(id)) {
      problems.push(`dangling-id:${library}:${id}`);
      continue;
    }
    verified.push({ library, id });
  }
  return { verified, problems };
}

const collisionsByProjectId = new Map(); // key: `${library}:${id}` -> [{entryId, classification}]

function recordBinding(library, id, entryId, classification) {
  const key = `${library}:${id}`;
  if (!collisionsByProjectId.has(key)) collisionsByProjectId.set(key, []);
  collisionsByProjectId.get(key).push({ entryId, classification });
}

const entries = [];
const problemsFound = [];

for (const catalogEntry of catalog.entries) {
  const { entryId, bookName } = catalogEntry;
  const recipe = recipes.recipes.find((r) => r.entryId === entryId);
  const nameMatch = nameMatchByEntryId.get(entryId);

  if (!recipe) {
    problemsFound.push(`missing-in-recipes:${entryId}`);
    continue;
  }
  if (!nameMatch) {
    problemsFound.push(`missing-in-name-matches:${entryId}`);
  }
  if (nameMatch && nameMatch.bookName !== bookName) {
    problemsFound.push(`bookName-mismatch-catalog-vs-name-matches:${entryId}`);
  }
  if (recipe.bookName !== bookName) {
    problemsFound.push(`bookName-mismatch-catalog-vs-recipes:${entryId}`);
  }

  const pm = recipe.projectMatch;
  let classification = pm.classification;

  // Cross-check against name-matches classification when available.
  if (nameMatch) {
    const nmClass = nameMatchClassificationMap[nameMatch.classification?.id];
    if (nmClass && nmClass !== classification) {
      if (!isExplainedBaselineDifference(entryId, classification)) {
        problemsFound.push(
          `classification-conflict-recipes-vs-name-matches:${entryId}:${classification}!=${nmClass}`,
        );
      }
    }
  }

  const sourceProjectMatchBefore = {
    classification: pm.classification,
    projectName: pm.projectName,
    projectIds: pm.projectIds ?? [],
    candidateProjectName: pm.candidateProjectName ?? null,
    reviewRequired: pm.reviewRequired ?? false,
  };

  let projectName = null;
  let projectIds = [];
  let candidateProjectName = null;
  let candidateProjectIds = [];
  let reviewRequired = false;
  const evidence = [];
  const adjudication = adjudicationByEntryId.get(entryId);

  if (classification === 'exact-name' || classification === 'confirmed-alias') {
    const { verified, problems } = verifyProjectIds(entryId, pm.projectIds ?? []);
    if (problems.length > 0) {
      problemsFound.push(`${entryId}:${problems.join(',')}`);
    }
    if (verified.length === 0) {
      problemsFound.push(`confirmed-classification-without-verified-project-id:${entryId}`);
    }
    projectName = pm.projectName;
    projectIds = verified;
    for (const { library, id } of verified) {
      recordBinding(library, id, entryId, classification);
    }
    if (classification === 'exact-name') {
      evidence.push('书名与项目菜名规范化后逐字相同（名称证据，优先级1）。');
    } else {
      if (adjudication?.decision === 'confirmed-alias') {
        evidence.push(
          `正文证据确认同菜异名（依据 crosswalk-probable-review，decision=confirmed-alias，confidence=${adjudication.confidence}）。`,
        );
        if (nameMatch?.basis) evidence.push(nameMatch.basis);
      } else {
        evidence.push(nameMatch?.basis ?? '仓库既有证据判定为同菜明确别名（名称/历史名证据，优先级1）。');
      }
    }
  } else if (classification === 'probable-match-needs-review') {
    reviewRequired = true;
    candidateProjectName = pm.candidateProjectName ?? nameMatch?.projectName ?? null;
    const nmProjectIds = nameMatch
      ? Object.entries(nameMatch.projectIds ?? {}).map(([library, id]) => ({ library, id }))
      : [];
    const { verified, problems } = verifyProjectIds(entryId, nmProjectIds);
    if (problems.length > 0) {
      problemsFound.push(`${entryId}:candidate:${problems.join(',')}`);
    }
    candidateProjectIds = verified;
    for (const { library, id } of verified) {
      recordBinding(library, id, entryId, classification);
    }
    evidence.push(nameMatch?.basis ?? '存在合理候选但无法无歧义证明为同一道菜，需人工复核（未确认绑定）。');
  } else if (classification === 'book-only') {
    if (adjudication?.decision === 'reject-candidate') {
      evidence.push(
        `候选经正文复核不成立（依据 crosswalk-probable-review，decision=reject-candidate，confidence=${adjudication.confidence}），回到book-only。`,
      );
    }
    evidence.push('当前项目Curated/Full库中未找到可靠对应菜谱，未强行配对。');
  } else {
    problemsFound.push(`unknown-classification:${entryId}:${classification}`);
  }

  const sourceQualityReasons = sourceFidelityReasons(entryId, recipe);
  const sourceQuality = sourceQualityFor(entryId, sourceQualityReasons);
  if (sourceQuality === 'alternate-source-required') {
    sourceQualityReasons.unshift(
      'apply-review-resolutions-audit.unchangedByDesign.alternateSourceRequired',
    );
  }

  entries.push({
    entryId,
    bookName,
    sourceProjectMatchBefore,
    proposedClassification: classification,
    projectName,
    projectIds,
    candidateProjectName,
    candidateProjectIds,
    evidence,
    sourceQuality,
    sourceQualityReasons,
    reviewRequired,
    manyToOne: null, // filled below
    collision: null, // filled below
  });
}

// -- Many-to-one / collision detection -------------------------------------
// Known, previously-documented many-to-one alias bindings (book entries
// that legitimately share one project recipe as the same historical dish).
// None currently exist in the canonical data (verified below), but the
// detection logic stays generic so any future collision is still surfaced
// rather than silently accepted.
const manyToOneReasons = {};

for (const [key, bindings] of collisionsByProjectId.entries()) {
  if (bindings.length <= 1) continue;
  const entryIds = bindings.map((b) => b.entryId);
  const allConfirmed = bindings.every((b) => b.classification === 'exact-name' || b.classification === 'confirmed-alias');
  const info = {
    projectIdKey: key,
    entryIds,
    classifications: bindings.map((b) => b.classification),
  };
  for (const b of bindings) {
    const entry = entries.find((e) => e.entryId === b.entryId);
    if (!entry) continue;
    if (allConfirmed && manyToOneReasons[key]) {
      entry.manyToOne = { ...info, reason: manyToOneReasons[key] };
    } else if (allConfirmed) {
      // No pre-documented many-to-one reason exists for this binding; do
      // not auto-resolve. Mark as collision requiring manual review.
      entry.collision = { ...info, note: '多个source entry绑定同一project recipe，且无既有many-to-one依据，不自动解决。' };
    } else {
      entry.collision = { ...info, note: '候选与确认绑定混合指向同一project recipe，不自动解决。' };
    }
  }
}

// -- Summary counts ----------------------------------------------------------

const classificationCounts = {
  'exact-name': 0,
  'confirmed-alias': 0,
  'probable-match-needs-review': 0,
  'book-only': 0,
};
for (const e of entries) classificationCounts[e.proposedClassification] += 1;

const sourceQualityCounts = {
  'ready-for-later-promotion-review': 0,
  'needs-source-review': 0,
  'alternate-source-required': 0,
};
for (const e of entries) sourceQualityCounts[e.sourceQuality] += 1;

const confirmedTotal = classificationCounts['exact-name'] + classificationCounts['confirmed-alias'];

const probableCandidates = entries
  .filter((e) => e.proposedClassification === 'probable-match-needs-review')
  .map((e) => ({
    entryId: e.entryId,
    bookName: e.bookName,
    candidateProjectName: e.candidateProjectName,
    candidateProjectIds: e.candidateProjectIds,
  }));

const collisions = entries.filter((e) => e.collision).map((e) => ({ entryId: e.entryId, bookName: e.bookName, collision: e.collision }));
const manyToOnes = entries.filter((e) => e.manyToOne).map((e) => ({ entryId: e.entryId, bookName: e.bookName, manyToOne: e.manyToOne }));

const alternateSourceRequiredList = entries
  .filter((e) => e.sourceQuality === 'alternate-source-required')
  .map((e) => ({ entryId: e.entryId, bookName: e.bookName }));

const adjudicatedEntryIds = entries
  .filter((e) => adjudicationByEntryId.has(e.entryId))
  .map((e) => e.entryId)
  .sort();

if (alternateSourceRequiredList.length !== 12) {
  problemsFound.push(`alternate-source-required-count-not-12:${alternateSourceRequiredList.length}`);
}

for (const e of entries) {
  if (e.sourceQuality === 'ready-for-later-promotion-review' && e.sourceQualityReasons.length !== 0) {
    problemsFound.push(`ready-with-reasons:${e.entryId}`);
  }
  if (e.sourceQuality !== 'ready-for-later-promotion-review' && e.sourceQualityReasons.length === 0) {
    problemsFound.push(`non-ready-without-reasons:${e.entryId}`);
  }
  const mappingTaintedReason = e.sourceQualityReasons.some((reason) =>
    /projectMatch|reviewRequired|candidateProject|name-match|crosswalk/i.test(reason),
  );
  if (mappingTaintedReason) {
    problemsFound.push(`mapping-tainted-source-quality-reason:${e.entryId}`);
  }
}

const uniqueEntryIds = new Set(entries.map((e) => e.entryId));
if (uniqueEntryIds.size !== 147 || entries.length !== 147) {
  problemsFound.push(`entry-count-mismatch:total=${entries.length}:unique=${uniqueEntryIds.size}`);
}

const output = {
  schema: 'kitchenmanager.source-restoration.crosswalk-dry-run.v1',
  generatedAt: new Date().toISOString().slice(0, 10),
  purpose: '《大众川菜》1979 147道source-restoration entryId与项目Curated/Full真实菜谱ID之间的crosswalk dry-run审计。仅审计/映射，不做production promotion，不修改canonical147道worker/chunk/assembled、name-matches、review overlay/audit、Curated/Full/HOC或applicationReady。正文复核结论来自 crosswalk-probable-review artifact；name-matches 仅作为历史 name-only baseline。',
  scope: {
    totalEntries: 147,
    sourceCatalog: 'data/source-restoration/dazhong-chuancai-1979-catalog.v1.json',
    sourceRecipes: 'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
    sourceNameMatches: 'data/source-restoration/dazhong-chuancai-1979-name-matches.v1.json',
    sourceReviewQueue: 'data/source-restoration/dazhong-chuancai-1979-review-queue.v1.json',
    sourceR1Results: 'data/source-restoration/dazhong-chuancai-1979-review-resolution-r1-results.v1.json',
    sourceR2Results: 'data/source-restoration/dazhong-chuancai-1979-review-resolution-r2-results.v1.json',
    sourceApplyAudit: 'data/source-restoration/dazhong-chuancai-1979-apply-review-resolutions-audit.v1.json',
    sourceProbableReview: 'data/source-restoration/dazhong-chuancai-1979-crosswalk-probable-review.v1.json',
    targetCuratedLibrary: 'data/sichuan-recipes.curated.json',
    targetFullLibrary: 'data/sichuan-recipes.json',
  },
  applicationReady: false,
  productionPromotion: false,
  classificationDefinitions: [
    { id: 'exact-name', reviewRequired: false, note: '书名与项目菜名规范化后实质完全一致，绑定真实project ID。' },
    { id: 'confirmed-alias', reviewRequired: false, note: '名称不同但仓库证据确认为同一道菜的明确别名，绑定真实project ID。' },
    { id: 'probable-match-needs-review', reviewRequired: true, note: '有合理候选但不能无歧义证明，candidate单独记录，不作为confirmed绑定。' },
    { id: 'book-only', reviewRequired: false, note: '当前项目找不到可靠对应，不强行配对。' },
  ],
  sourceQualityDefinitions: [
    { id: 'ready-for-later-promotion-review', note: '非B类且当前canonical不存在来源层保真问题（contentMissing/contentIncomplete、uncertainties、sub-high recognition/conversion、旧词modernSummary未解、R1/R2 confirmed-unresolved）。crosswalk仍可能为probable，映射风险由reviewRequired单独表达。' },
    { id: 'needs-source-review', note: '当前canonical仍存在来源层保真问题，非B类。来源问题以sourceQualityReasons逐项列出；不因projectMatch.reviewRequired/probable/candidate/name-match未确认而判定。' },
    { id: 'alternate-source-required', note: '既有apply-review-resolutions审计中记录的unchangedByDesign.alternateSourceRequired 12道，需要替代来源，与crosswalk分类无关。' },
  ],
  summary: {
    totalEntries: entries.length,
    classificationCounts,
    confirmedProjectMappingTotal: confirmedTotal,
    probableCandidateCount: classificationCounts['probable-match-needs-review'],
    bookOnlyCount: classificationCounts['book-only'],
    sourceQualityCounts,
    collisionCount: collisions.length,
    manyToOneCount: manyToOnes.length,
    consistencyProblemsCount: problemsFound.length,
    adjudicatedEntryIds,
  },
  probableCandidates,
  collisions,
  manyToOnes,
  alternateSourceRequiredList,
  consistencyProblems: problemsFound,
  entries,
};

const outPath = path.join(
  repoRoot,
  'data/source-restoration/dazhong-chuancai-1979-crosswalk-dry-run.v1.json',
);
fs.writeFileSync(outPath, `${JSON.stringify(output, null, 2)}\n`);

console.log(`Wrote ${outPath}`);
console.log(`classificationCounts: ${JSON.stringify(classificationCounts)}`);
console.log(`sourceQualityCounts: ${JSON.stringify(sourceQualityCounts)}`);
console.log(`consistencyProblems: ${problemsFound.length}`);
if (problemsFound.length > 0) {
  console.log(problemsFound);
  process.exitCode = 1;
}
