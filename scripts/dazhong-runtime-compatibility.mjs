#!/usr/bin/env node
// Shared runtime-compatibility classification for 《大众川菜》1979 promotion work.
//
// Extracted verbatim from the verified Batch 1 runtime audit
// (scripts/build-dazhong-chuancai-batch1-runtime-audit.mjs) so Batch 2 reuses
// exactly the same probe / canonicalization / coverage logic. No new alias or
// unit conversion is introduced here; everything comes from the existing
// src/ingredients.js / src/inventory.js / recipe-sanitizer runtime.
//
// Every audited core ingredient gets exactly one compatibility result:
//   exact-compatible | expected-unit-confirmation | unresolved-name-match
// Non-core (seasoning / non-stock) ingredients never enter the classification.

import {
  INGREDIENT_FAMILIES,
  getCanonicalName,
  getIngredientFamilyCandidates,
  getIngredientFamilyKey,
  getIngredientMatchNames,
  guessKitchenUnit,
  isSmartIngredientMatch,
  normalizeIngredientAmount,
} from '../src/ingredients.js';
import { getStockCoverageAnalysis } from '../src/inventory.js';
import { classifyRecipeIngredient } from '../src/utils/recipe-sanitizer.js';

// User-realistic poultry stock names for chicken-like items; the recipe
// ingredient itself may not canonicalize to any of these.
export const POULTRY_PROBES = ['鸡肉', '仔鸡', '母鸡', '老母鸡', '土鸡', '公鸡', '三黄鸡'];

export function userRealisticProbes(item) {
  const canonical = getCanonicalName(item);
  const probes = new Set();
  if (canonical) probes.add(canonical);
  for (const name of getIngredientMatchNames(item)) {
    if (name) probes.add(name);
  }
  const familyKey = getIngredientFamilyKey(item);
  if (familyKey) {
    for (const candidate of getIngredientFamilyCandidates(item, { includeBroad: true })) {
      if (candidate) probes.add(candidate);
    }
  }
  // Any family whose names overlap the item get their broad/member names too.
  for (const group of Object.values(INGREDIENT_FAMILIES)) {
    const familyNames = [...(group.broad || []), ...(group.members || [])];
    if (familyNames.some((name) => name === item || name === canonical)) {
      for (const name of familyNames) probes.add(name);
    }
  }
  if (item.includes('鸡') || canonical.includes('鸡')) {
    for (const name of POULTRY_PROBES) probes.add(name);
  }
  probes.add(item); // identity probe, flagged separately
  return [...probes];
}

function simulateProbe(item, qty, unit, probeName, stockUnit) {
  const stock = [{ name: probeName, qty: 100, unit: stockUnit, stockStatus: 'ok' }];
  const analysis = getStockCoverageAnalysis(stock, item, qty, unit);
  return {
    probeName,
    strictNameMatch: isSmartIngredientMatch(item, probeName, { allowContains: false }),
    softNameMatch: isSmartIngredientMatch(item, probeName),
    coverageWithStockUnit: analysis.confidence,
  };
}

/**
 * Classify one production ingredient against the real inventory / recipe
 * canonicalization pipeline (read-only).
 *
 * @param {string} item  production ingredient name
 * @param {string|null} qty  production qty string
 * @param {string|null} unit production unit string
 * @returns {{
 *   role: string, canonical: string, familyKey: string|null,
 *   guessKitchenUnit: string, normalizedQuantity: {qty, unit, finite},
 *   compatibility: string|null, reasons: string[],
 *   identityMatch: object|null, probes: object[],
 *   observation: string|null,
 * }}
 * compatibility is null for non-core ingredients; observation carries the
 * scope note instead.
 */
export function classifyIngredientCompatibility(item, qty, unit) {
  const canonical = getCanonicalName(item);
  const role = classifyRecipeIngredient(item).role;
  const guessUnit = guessKitchenUnit(item);
  const familyKey = getIngredientFamilyKey(item);
  const probes = userRealisticProbes(item).map((probeName) => {
    const isIdentity = probeName === item || probeName === canonical;
    return {
      probeName,
      isIdentity,
      ...simulateProbe(item, qty, unit, probeName, unit),
      withDefaultUnit: simulateProbe(item, qty, unit, probeName, guessUnit).coverageWithStockUnit,
    };
  });

  const userProbes = probes.filter((probe) => !probe.isIdentity);
  const identityProbe = probes.find((probe) => probe.isIdentity);
  const normalized = normalizeIngredientAmount(qty, unit);

  const base = {
    role,
    canonical,
    familyKey: familyKey || null,
    guessKitchenUnit: guessUnit,
    normalizedQuantity: {
      qty: normalized.qty,
      unit: normalized.unit,
      finite: Number.isFinite(Number(normalized.qty)),
    },
  };

  if (role !== 'core') {
    // Seasoning / non-stock items never enter the inventory compatibility
    // classification; keep them only for quantity provenance.
    return {
      ...base,
      compatibility: null,
      reasons: [],
      identityMatch: null,
      probes: [],
      observation: `role=${role}，不参与库存名称兼容三分类；qty/unit 仍受 quantity-review 质量门禁约束。`,
    };
  }

  const isPoultryLike = item.includes('鸡') || canonical.includes('鸡');
  // Name resolution rules:
  //  - family items: a strict match against a user-realistic family name is
  //    required (the family is the user-facing vocabulary).
  //  - poultry-like items without a family: a common poultry name must
  //    strictly resolve, otherwise the recipe name is invisible to users.
  //  - other items: their canonical name is already user-facing vocabulary.
  const familyResolved = getIngredientFamilyKey(item)
    ? userProbes.some((probe) => probe.strictNameMatch)
    : true;
  const poultryResolved = isPoultryLike
    ? userProbes.some((probe) => probe.strictNameMatch)
    : true;
  const strictResolved = familyResolved && poultryResolved;
  const unitNatural = unit === 'g' || unit === guessUnit;

  const canonicalProbe = probes.find((probe) => probe.isIdentity && probe.probeName === canonical);
  const evidenceProbes = canonicalProbe
    ? [canonicalProbe, ...userProbes]
    : [...userProbes];
  const exactEvidence = evidenceProbes.some((probe) => probe.coverageWithStockUnit === 'exact');

  let compatibility = null;
  const reasons = [];
  if (!strictResolved) {
    compatibility = 'unresolved-name-match';
    const containsOnly = userProbes.filter((probe) => probe.softNameMatch && !probe.strictNameMatch)
      .map((probe) => probe.probeName);
    reasons.push('现有 canonicalization 无法把该 production item 解析到任何常见用户库存名称（严格名称层失败）。');
    if (containsOnly.length > 0) {
      reasons.push(`仅存在 contains 级脆弱匹配（不可靠）：${containsOnly.join('、')}。`);
    }
  } else if (!unitNatural) {
    compatibility = 'expected-unit-confirmation';
    reasons.push(`名称可解析，但 production unit「${unit}」与常用库存单位「${guessUnit}」无可安全换算，需用户按 production unit 录入库存或人工确认。`);
  } else if (exactEvidence) {
    compatibility = 'exact-compatible';
    reasons.push('名称严格可解析，且存在 production unit 下真实 getStockCoverageAnalysis=exact 的证据（非仅因 unit=g 判定）。');
  } else {
    compatibility = 'expected-unit-confirmation';
    reasons.push('名称可解析且 unit 自然，但缺少真实 coverage=exact 证据，需人工确认。');
  }

  return {
    ...base,
    identityMatch: identityProbe ? {
      probeName: identityProbe.probeName,
      coverageWithProductionUnit: identityProbe.coverageWithStockUnit,
    } : null,
    probes: evidenceProbes.map((probe) => ({
      probeName: probe.probeName,
      strictNameMatch: probe.strictNameMatch,
      softNameMatch: probe.softNameMatch,
      coverageWithProductionUnit: probe.coverageWithStockUnit,
      coverageWithDefaultUnit: probe.withDefaultUnit,
    })),
    compatibility,
    reasons,
    observation: null,
  };
}
