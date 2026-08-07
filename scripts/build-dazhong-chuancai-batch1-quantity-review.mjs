#!/usr/bin/env node
// Builds the Batch 1 quantity review artifact by mechanically extracting
// every qty/unit ingredient from the frozen Batch 1 dry-run. The records
// are the source-restoration-backed reviewed quantities that make the
// promoted curated ingredient qty/unit entries eligible for the runtime
// qty/unit allowlist.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');

const readJson = (relativePath) => JSON.parse(
  fs.readFileSync(path.join(repoRoot, relativePath), 'utf8'),
);

const dryRun = readJson('data/source-restoration/dazhong-chuancai-1979-promotion-batch1-dry-run.v1.json');
const canonical = readJson('data/source-restoration/dazhong-chuancai-1979-recipes.v1.json');

const canonicalByEntryId = new Map(
  canonical.recipes.map((recipe) => [recipe.entryId, recipe]),
);

const records = [];
for (const item of dryRun.items) {
  const sourceRecipe = canonicalByEntryId.get(item.entryId);
  const planIngredients = item.proposedOverlayIngredients[item.productionId];
  // Match proposed production ingredients back to canonical raw ingredients
  // by productionItem name so the raw quantity / normalized quantity are
  // sourced from the canonical file, never recomputed here.
  const canonicalIngredientByItem = new Map(
    (sourceRecipe.ingredients ?? []).map((ingredient) => [
      ingredient.rawItemText,
      ingredient,
    ]),
  );
  for (const productionIngredient of planIngredients) {
    if (productionIngredient.qty === null || productionIngredient.unit === null) continue;
    const canonicalIngredient = canonicalIngredientByItem.get(productionIngredient.item)
      ?? (sourceRecipe.ingredients ?? []).find((ingredient) => (
        ingredient.rawItemText === productionIngredient.item
      ));
    if (!canonicalIngredient) {
      throw new Error(`no canonical ingredient for ${item.entryId}:${productionIngredient.item}`);
    }
    const normalizedQuantity = canonicalIngredient.normalizedQuantity ?? {};
    records.push({
      entryId: item.entryId,
      productionId: item.productionId,
      recipeName: item.name,
      item: productionIngredient.item,
      qty: productionIngredient.qty,
      unit: productionIngredient.unit,
      evidenceType: 'source-restoration',
      canonicalSourceFile: 'data/source-restoration/dazhong-chuancai-1979-recipes.v1.json',
      sourceRawQuantityText: canonicalIngredient.rawQuantityText,
      normalizedQuantity: {
        kind: normalizedQuantity.kind,
        qty: normalizedQuantity.qty,
        unit: normalizedQuantity.unit,
      },
      dryRunArtifact: 'data/source-restoration/dazhong-chuancai-1979-promotion-batch1-dry-run.v1.json',
      reviewStatus: 'approved',
    });
  }
}

// -- Verification ----------------------------------------------------------

const problems = [];
if (records.length !== 19) problems.push(`record-count-not-19:${records.length}`);

const keys = new Set();
for (const record of records) {
  const key = `${record.productionId}:${record.item}`;
  if (keys.has(key)) problems.push(`duplicate-key:${key}`);
  keys.add(key);
  if (record.qty === null || record.unit === null) problems.push(`missing-qty-unit:${key}`);
  if (!['exact-mass', 'exact-count'].includes(record.normalizedQuantity.kind)) {
    problems.push(`non-exact-kind:${key}:${record.normalizedQuantity.kind}`);
  }
  if (record.normalizedQuantity.kind === 'exact-mass' && record.unit !== 'g') {
    problems.push(`exact-mass-not-g:${key}:${record.unit}`);
  }
  if (record.normalizedQuantity.kind === 'exact-count' && !record.unit) {
    problems.push(`exact-count-no-unit:${key}`);
  }
  const expectedQty = String(record.normalizedQuantity.qty);
  if (record.qty !== expectedQty) problems.push(`qty-recomputed:${key}:${record.qty}!=${expectedQty}`);
  if (record.normalizedQuantity.kind === 'exact-mass' && record.unit !== 'g') {
    problems.push(`mass-unit-not-g:${key}`);
  }
  if (!/^(g|ml|个|只|颗|枚|根|条|片|块|瓣|张|把|棵|头|支|份|盒|袋|包|瓶|罐|听)$/.test(record.unit)) {
    problems.push(`unit-not-whitelisted:${key}:${record.unit}`);
  }
}

const unitCounts = {};
for (const record of records) {
  unitCounts[record.unit] = (unitCounts[record.unit] ?? 0) + 1;
}

const output = {
  schema: 'kitchenmanager.source-restoration.promotion-batch1-quantity-review.v1',
  generatedAt: new Date().toISOString().slice(0, 10),
  purpose: 'Batch 1 promotion 引入的 curated qty/unit 的 source-restoration-reviewed 登记。qty/unit 逐字段取自冻结 dry-run proposedOverlayIngredients，raw/normalized 数量取自 canonical source，evidenceType=source-restoration。',
  applicationReady: false,
  evidencePolicy: '证据来源为已审阅 source-restoration canonical quantity，不声称来自 production method 文本。',
  summary: {
    recordCount: records.length,
    unitCounts,
    keys: [...keys].sort(),
  },
  records,
  verificationProblems: problems,
};

const outPath = path.join(
  repoRoot,
  'data/source-restoration/dazhong-chuancai-1979-promotion-batch1-quantity-review.v1.json',
);
fs.writeFileSync(outPath, `${JSON.stringify(output, null, 2)}\n`);

console.log(`Wrote ${outPath}`);
console.log(`records: ${records.length}, units: ${JSON.stringify(unitCounts)}`);
console.log(`verificationProblems: ${problems.length}`);
if (problems.length > 0) {
  console.log(problems);
  process.exitCode = 1;
}
