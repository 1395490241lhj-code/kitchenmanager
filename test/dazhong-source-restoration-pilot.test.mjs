import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const pilotFile = new URL(
  '../data/source-restoration/dazhong-chuancai-1979-pilot.v1.json',
  import.meta.url
);
const data = JSON.parse(fs.readFileSync(pilotFile, 'utf8'));

function recipe(name) {
  const match = data.pilots.find((entry) => entry.name === name);
  assert.ok(match, `missing pilot recipe: ${name}`);
  return match;
}

function ingredient(recipeName, rawItemText) {
  const match = recipe(recipeName).ingredients.find(
    (entry) => entry.rawItemText === rawItemText
  );
  assert.ok(match, `missing ingredient: ${recipeName} / ${rawItemText}`);
  return match;
}

test('pilot remains intermediate-only and application-ineligible', () => {
  assert.equal(data.status, 'pilot-approved-corrected-intermediate-only');
  assert.equal(data.applicationReady, false);
  assert.equal(data.reviewProcess.productionRecipeWrite, false);
  assert.equal(data.reviewProcess.servingScale, 'none');
  assert.equal(data.reviewProcess.cacheStampUpdated, false);
  assert.equal(data.pilotGate.status, 'approved-corrections-verified');
  assert.equal(data.pilotGate.catalogIndexCreated, true);
  assert.equal(data.pilotGate.nameMatchingCreated, true);
  assert.equal(data.pilotGate.batchPlanCreated, true);
  assert.match(data.standardizationMeaning, /source-equivalent conversions only/);
});

test('approved source corrections are recorded exactly', () => {
  const soupSeasoning = ingredient('豌豆肥肠汤', '味精、胡椒');
  assert.equal(soupSeasoning.rawQuantityText, '各三分');
  assert.deepEqual(soupSeasoning.normalizedQuantity, {
    kind: 'exact-mass',
    qty: 1.5,
    unit: 'g',
    appliesTo: 'each-item',
    qualifier: null
  });
  assert.deepEqual(soupSeasoning.members, [
    { item: '味精', qty: 1.5, unit: 'g' },
    { item: '胡椒', qty: 1.5, unit: 'g' }
  ]);

  const saltFriedPork = recipe('炒盐煎肉');
  assert.deepEqual(saltFriedPork.confirmedReadings, [
    {
      location: '做法第3步',
      raw: '待肉片炒干水汽现油时',
      treatment: '原文已确认；摘要仍概括为水汽收干并出油。'
    }
  ]);
  assert.deepEqual(saltFriedPork.uncertainties, []);

  const gingerPigFeet = recipe('姜汁蹄花');
  assert.deepEqual(gingerPigFeet.confirmedReadings, [
    {
      location: '做法第1步',
      raw: '煮耙捞起',
      treatment: '保留方言原文；结构摘要仍写煮至软烂。'
    }
  ]);
  assert.deepEqual(gingerPigFeet.uncertainties, []);
  assert.match(gingerPigFeet.methodSummary.steps[0].summary, /煮至软烂/);
});

test('grouped ingredients encode each-member and group-total semantics safely', () => {
  const grouped = data.pilots
    .flatMap((entry) => entry.ingredients)
    .filter((entry) => Array.isArray(entry.members));

  assert.equal(grouped.length, 4);

  for (const entry of grouped) {
    assert.equal(typeof entry.rawItemText, 'string');
    assert.equal(typeof entry.rawQuantityText, 'string');

    if (entry.memberQuantityMode === 'same-for-each') {
      assert.equal(entry.groupTotal, undefined);
      for (const member of entry.members) {
        assert.equal(member.qty, entry.normalizedQuantity.qty);
        assert.equal(member.unit, entry.normalizedQuantity.unit);
      }
      continue;
    }

    assert.equal(entry.memberQuantityMode, 'unallocated-group-total');
    assert.deepEqual(entry.groupTotal, {
      qty: entry.normalizedQuantity.qty,
      unit: entry.normalizedQuantity.unit
    });
    for (const member of entry.members) {
      assert.equal(member.qty, null);
      assert.equal(member.unit, null);
    }
  }

  const gingerGarlic = ingredient('糖醋排骨', '姜、蒜片');
  assert.deepEqual(gingerGarlic.groupTotal, { qty: 25, unit: 'g' });
  assert.deepEqual(gingerGarlic.members, [
    { item: '姜', qty: null, unit: null },
    { item: '蒜片', qty: null, unit: null }
  ]);
});

test('all raw quantities remain traceable and unsafe precision stays absent', () => {
  const ingredients = data.pilots.flatMap((entry) => entry.ingredients);
  assert.equal(ingredients.length, 39);

  for (const entry of ingredients) {
    assert.ok(entry.rawItemText);
    assert.ok(entry.rawQuantityText);
    assert.ok(entry.conversionBasis);
    assert.ok(entry.confidence?.recognition);
    assert.ok(entry.confidence?.conversion);
  }

  const approximateCounts = ingredients.filter(
    (entry) => entry.normalizedQuantity.kind === 'approximate-count'
  );
  assert.ok(approximateCounts.length > 0);
  assert.ok(approximateCounts.every((entry) => entry.normalizedQuantity.qty === null));

  const unresolved = ingredient('糖醋排骨', '醋');
  assert.equal(unresolved.rawQuantityText, '一两二');
  assert.equal(unresolved.normalizedQuantity.qty, null);
  assert.equal(unresolved.normalizedQuantity.unit, null);
  assert.equal(unresolved.conversionCandidate.accepted, false);
});
