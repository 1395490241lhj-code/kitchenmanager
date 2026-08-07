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
const repoRoot = path.resolve(__dirname, '..');

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(path.join(repoRoot, relativePath), 'utf8'),
);

const catalog = readJson('data/source-restoration/dazhong-chuancai-1979-catalog.v1.json');
const recipes = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');
const nameMatches = readJson('data/source-restoration/dazhong-chuancai-1979-name-matches.v1.json');
const reviewQueue = readJson('data/source-restoration/dazhong-chuancai-1979-review-queue.v1.json');
const r1Results = readJson('data/source-restoration/dazhong-chuancai-1979-review-resolution-r1-results.v1.json');
const r2Results = readJson('data/source-restoration/dazhong-chuancai-1979-review-resolution-r2-results.v1.json');
const applyAudit = readJson('data/source-restoration/dazhong-chuancai-1979-apply-review-resolutions-audit.v1.json');

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

// Review-queue entryIds (deduped) mark entries with an open source-fidelity
// question (reviewRequired, contentMissing, contentIncomplete, non-empty
// uncertainties, or sub-high confidence anywhere). Entries in the queue but
// NOT in the alternate-source-required set are "needs-source-review".
// Everything else is "ready-for-later-promotion-review".
const reviewQueueIds = new Set(reviewQueue.items.map((item) => item.entryId));

function sourceQualityFor(entryId) {
  if (alternateSourceRequiredIds.has(entryId)) return 'alternate-source-required';
  if (reviewQueueIds.has(entryId)) return 'needs-source-review';
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
      problemsFound.push(
        `classification-conflict-recipes-vs-name-matches:${entryId}:${classification}!=${nmClass}`,
      );
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
      evidence.push(nameMatch?.basis ?? '仓库既有证据判定为同菜明确别名（名称/历史名证据，优先级1）。');
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
    evidence.push('当前项目Curated/Full库中未找到可靠对应菜谱，未强行配对。');
  } else {
    problemsFound.push(`unknown-classification:${entryId}:${classification}`);
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
    sourceQuality: sourceQualityFor(entryId),
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

if (alternateSourceRequiredList.length !== 12) {
  problemsFound.push(`alternate-source-required-count-not-12:${alternateSourceRequiredList.length}`);
}

const uniqueEntryIds = new Set(entries.map((e) => e.entryId));
if (uniqueEntryIds.size !== 147 || entries.length !== 147) {
  problemsFound.push(`entry-count-mismatch:total=${entries.length}:unique=${uniqueEntryIds.size}`);
}

const output = {
  schema: 'kitchenmanager.source-restoration.crosswalk-dry-run.v1',
  generatedAt: new Date().toISOString().slice(0, 10),
  purpose: '《大众川菜》1979 147道source-restoration entryId与项目Curated/Full真实菜谱ID之间的crosswalk dry-run审计。仅审计/映射，不做production promotion，不修改canonical147道worker/chunk/assembled、name-matches、review overlay/audit、Curated/Full/HOC或applicationReady。',
  scope: {
    totalEntries: 147,
    sourceCatalog: 'data/source-restoration/dazhong-chuancai-1979-catalog.v1.json',
    sourceRecipes: 'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
    sourceNameMatches: 'data/source-restoration/dazhong-chuancai-1979-name-matches.v1.json',
    sourceReviewQueue: 'data/source-restoration/dazhong-chuancai-1979-review-queue.v1.json',
    sourceR1Results: 'data/source-restoration/dazhong-chuancai-1979-review-resolution-r1-results.v1.json',
    sourceR2Results: 'data/source-restoration/dazhong-chuancai-1979-review-resolution-r2-results.v1.json',
    sourceApplyAudit: 'data/source-restoration/dazhong-chuancai-1979-apply-review-resolutions-audit.v1.json',
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
    { id: 'ready-for-later-promotion-review', note: '不在review queue且不属于B类，source侧无已知开放问题。' },
    { id: 'needs-source-review', note: '在review queue中记录了开放的source保真问题（confirmedFacts之外的unresolvedQuestions），非B类。' },
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
