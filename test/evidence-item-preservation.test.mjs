import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { preserveEvidenceItemsInRecipe } = require('../src/server/services/evidence-item-preservation');

test('补回 final AI 整体遗漏的结构化主料和调料并保持 method', () => {
  const recipe = {
    name: '青椒肉丝',
    ingredients: [],
    seasonings: [],
    method: ['控干肉丝水分。', '加入盐、小苏打和老抽。', '下肉丝翻炒。', '加入青椒和甜面酱。']
  };
  const method = [...recipe.method];
  const result = preserveEvidenceItemsInRecipe(recipe, {
    observedMainIngredients: ['青椒', '肉丝'],
    observedSeasonings: ['盐', '小苏打', '老抽', '土豆淀粉', '甜面酱']
  });

  assert.deepEqual(result.recipe.ingredients, [
    { item: '青椒', qty: '', unit: '' },
    { item: '肉丝', qty: '', unit: '' }
  ]);
  assert.deepEqual(result.recipe.seasonings, [
    { item: '盐', qty: '', unit: '' },
    { item: '小苏打', qty: '', unit: '' },
    { item: '老抽', qty: '', unit: '' },
    { item: '土豆淀粉', qty: '', unit: '' },
    { item: '甜面酱', qty: '', unit: '' }
  ]);
  assert.deepEqual(result.recipe.method, method);
  assert.equal(result.diagnostics.preservedMainIngredientCount, 2);
  assert.equal(result.diagnostics.preservedSeasoningCount, 5);
  assert.equal(result.diagnostics.finalModelOmittedEvidenceItems, true);
});

test('部分遗漏时只追加缺失项并保留模型用量、拼写和顺序', () => {
  const recipe = {
    ingredients: [{ item: '青椒', qty: '2', unit: '个' }],
    seasonings: [{ item: '食盐', name: 'ignored', qty: '2', unit: '克' }]
  };
  const result = preserveEvidenceItemsInRecipe(recipe, {
    observedMainIngredients: ['青椒', '肉丝'],
    observedSeasonings: ['食盐', '老抽']
  });

  assert.deepEqual(result.recipe.ingredients, [
    { item: '青椒', qty: '2', unit: '个' },
    { item: '肉丝', qty: '', unit: '' }
  ]);
  assert.deepEqual(result.recipe.seasonings, [
    { item: '食盐', name: 'ignored', qty: '2', unit: '克' },
    { item: '老抽', qty: '', unit: '' }
  ]);
  assert.equal(result.diagnostics.preservedMainIngredientCount, 1);
  assert.equal(result.diagnostics.preservedSeasoningCount, 1);
  assert.equal(result.diagnostics.evidenceItemRejectedDuplicateCount, 2);
});

test('模型完整时 recipe 保持深度等价且不报告遗漏', () => {
  const recipe = {
    ingredients: [{ item: '青椒', qty: '', unit: '' }],
    seasonings: [{ item: '盐', qty: '2', unit: '克' }],
    method: ['翻炒。']
  };
  const snapshot = structuredClone(recipe);
  const result = preserveEvidenceItemsInRecipe(recipe, {
    observedMainIngredients: ['青椒'],
    observedSeasonings: ['盐']
  });

  assert.deepEqual(result.recipe, snapshot);
  assert.strictEqual(result.recipe, recipe);
  assert.equal(result.diagnostics.preservedMainIngredientCount, 0);
  assert.equal(result.diagnostics.preservedSeasoningCount, 0);
  assert.equal(result.diagnostics.finalModelOmittedEvidenceItems, false);
});

test('跨数组存在等价名称时不移动也不重复添加', () => {
  const recipe = {
    ingredients: [{ item: '  Sweet   Sauce ', qty: '30', unit: '克' }],
    seasonings: []
  };
  const result = preserveEvidenceItemsInRecipe(recipe, {
    observedMainIngredients: [],
    observedSeasonings: ['sweet sauce']
  });

  assert.strictEqual(result.recipe, recipe);
  assert.deepEqual(result.recipe.ingredients, [{ item: '  Sweet   Sauce ', qty: '30', unit: '克' }]);
  assert.deepEqual(result.recipe.seasonings, []);
  assert.equal(result.diagnostics.evidenceItemRejectedDuplicateCount, 1);
  assert.equal(result.diagnostics.finalModelOmittedEvidenceItems, false);
});

test('空 evidence 时 recipe 完全不变且 diagnostics 为有界零值', () => {
  const recipe = { name: '测试菜', ingredients: [], seasonings: [], method: ['完成。'] };
  const result = preserveEvidenceItemsInRecipe(recipe, {});

  assert.strictEqual(result.recipe, recipe);
  assert.deepEqual(result.diagnostics, {
    evidenceMainIngredientInputCount: 0,
    evidenceSeasoningInputCount: 0,
    evidenceMainIngredientCount: 0,
    evidenceSeasoningCount: 0,
    evidenceItemCheckedCount: 0,
    evidenceItemRejectedInvalidCount: 0,
    evidenceItemRejectedTooLongCount: 0,
    evidenceItemRejectedDuplicateCount: 0,
    evidenceItemRejectedOverLimitCount: 0,
    evidenceItemLimitApplied: false,
    preservedNameCodepointCount: 0,
    sanitizedIngredientCountBeforePreservation: 0,
    sanitizedSeasoningCountBeforePreservation: 0,
    preservedMainIngredientCount: 0,
    preservedSeasoningCount: 0,
    finalIngredientCount: 0,
    finalSeasoningCount: 0,
    finalModelOmittedEvidenceItems: false
  });
});

test('非法、空白和重复 evidence 值被安全过滤', () => {
  const result = preserveEvidenceItemsInRecipe({ ingredients: [], seasonings: [] }, {
    observedMainIngredients: ['', '   ', null, 42, '青  椒', ' 青 椒 '],
    observedSeasonings: [undefined, {}, '盐', ' 盐 ']
  });

  assert.deepEqual(result.recipe.ingredients, [{ item: '青 椒', qty: '', unit: '' }]);
  assert.deepEqual(result.recipe.seasonings, [{ item: '盐', qty: '', unit: '' }]);
  assert.equal(result.diagnostics.evidenceMainIngredientCount, 1);
  assert.equal(result.diagnostics.evidenceSeasoningCount, 1);
  assert.equal(result.diagnostics.evidenceItemRejectedInvalidCount, 6);
  assert.equal(result.diagnostics.evidenceItemRejectedDuplicateCount, 2);
});

test('只保留 evidence 原词，不从肉丝或土豆淀粉推断其他材料', () => {
  const result = preserveEvidenceItemsInRecipe({ ingredients: [], seasonings: [] }, {
    observedMainIngredients: ['肉丝'],
    observedSeasonings: ['土豆淀粉']
  });
  const names = [...result.recipe.ingredients, ...result.recipe.seasonings].map(row => row.item);

  assert.deepEqual(names, ['肉丝', '土豆淀粉']);
  assert.ok(!names.includes('猪肉'));
  assert.ok(!names.includes('土豆'));
  assert.ok(!names.includes('淀粉'));
});

test('不从菜名、method、动作或 uncertainItems 推断材料', () => {
  const result = preserveEvidenceItemsInRecipe({
    name: '青椒肉丝',
    ingredients: [],
    seasonings: [],
    method: ['加入料酒和淀粉。']
  }, {
    observedActions: [{ action: '加入生抽。', ingredients: ['生抽'] }],
    uncertainItems: ['盐'],
    dishNameCandidates: ['青椒肉丝']
  });

  assert.deepEqual(result.recipe.ingredients, []);
  assert.deepEqual(result.recipe.seasonings, []);
});

test('名称只做 NFKC、控制字符移除、空格折叠和大小写去重', () => {
  const result = preserveEvidenceItemsInRecipe({ ingredients: [], seasonings: [] }, {
    observedMainIngredients: ['  ＡＢ\u200b  Sauce  ', 'ab sauce', '肉丝', '猪肉'],
    observedSeasonings: ['土豆淀粉', '淀粉', '水', '清水']
  });

  assert.deepEqual(result.recipe.ingredients.map(row => row.item), ['AB Sauce', '肉丝', '猪肉']);
  assert.deepEqual(result.recipe.seasonings.map(row => row.item), ['土豆淀粉', '淀粉', '水', '清水']);
  assert.equal(result.diagnostics.evidenceItemRejectedDuplicateCount, 1);
});

test('模型的 name 字段也用于保守去重', () => {
  const recipe = { ingredients: [{ name: '青椒', qty: '2', unit: '个' }], seasonings: [] };
  const result = preserveEvidenceItemsInRecipe(recipe, { observedMainIngredients: ['青椒'] });

  assert.strictEqual(result.recipe, recipe);
  assert.equal(result.diagnostics.preservedMainIngredientCount, 0);
});

test('2 个主料与 14 个调料在 final 空数组时全部保留', () => {
  const observedSeasonings = [
    '盐', '小苏打', '老抽', '土豆淀粉', '甜面酱', '生抽', '料酒',
    '胡椒粉', '食用油', '白糖', '豆瓣酱', '香油', '蒜', '清水'
  ];
  const result = preserveEvidenceItemsInRecipe({ ingredients: [], seasonings: [], method: ['翻炒。'] }, {
    observedMainIngredients: ['青椒', '肉丝'],
    observedSeasonings
  });

  assert.equal(result.recipe.ingredients.length, 2);
  assert.equal(result.recipe.seasonings.length, 14);
  assert.deepEqual(result.recipe.seasonings.map(row => row.item), observedSeasonings);
  assert.ok([...result.recipe.ingredients, ...result.recipe.seasonings].every(row => row.qty === '' && row.unit === ''));
  assert.equal(result.diagnostics.preservedMainIngredientCount, 2);
  assert.equal(result.diagnostics.preservedSeasoningCount, 14);
  assert.equal(result.diagnostics.evidenceItemLimitApplied, false);
  assert.equal(result.diagnostics.finalModelOmittedEvidenceItems, true);
});

test('每类只读取前 128 项且 1000 加 1000 输入产生有界输出', () => {
  function boundedArray(prefix) {
    const target = new Array(1000);
    for (let index = 0; index < 128; index += 1) target[index] = `${prefix}${index}`;
    let accessedCount = 0;
    const values = new Proxy(target, {
      get(array, property, receiver) {
        if (/^\d+$/.test(String(property))) {
          const index = Number(property);
          assert.ok(index < 128, `unexpected access at index ${index}`);
          accessedCount += 1;
        }
        return Reflect.get(array, property, receiver);
      }
    });
    return { values, getAccessedCount: () => accessedCount };
  }

  const main = boundedArray('主料');
  const seasoning = boundedArray('调料');
  const result = preserveEvidenceItemsInRecipe({ ingredients: [], seasonings: [] }, {
    observedMainIngredients: main.values,
    observedSeasonings: seasoning.values
  });

  assert.equal(main.getAccessedCount(), 128);
  assert.equal(seasoning.getAccessedCount(), 128);
  assert.equal(result.diagnostics.evidenceMainIngredientInputCount, 1000);
  assert.equal(result.diagnostics.evidenceSeasoningInputCount, 1000);
  assert.equal(result.diagnostics.evidenceItemCheckedCount, 256);
  assert.equal(result.diagnostics.preservedMainIngredientCount, 32);
  assert.equal(result.diagnostics.preservedSeasoningCount, 16);
  assert.equal(result.recipe.ingredients.length + result.recipe.seasonings.length, 48);
  assert.equal(result.diagnostics.evidenceItemRejectedOverLimitCount, 1952);
  assert.equal(result.diagnostics.evidenceItemLimitApplied, true);
});

test('超过 80 code points 的名称被拒绝且不截断', () => {
  const tooLong = '菜'.repeat(81);
  const result = preserveEvidenceItemsInRecipe({ ingredients: [], seasonings: [] }, {
    observedMainIngredients: [tooLong]
  });

  assert.deepEqual(result.recipe.ingredients, []);
  assert.equal(result.diagnostics.evidenceItemRejectedTooLongCount, 1);
  assert.equal(result.diagnostics.preservedNameCodepointCount, 0);
});

test('纯零宽与纯控制字符名称被拒绝', () => {
  const result = preserveEvidenceItemsInRecipe({ ingredients: [], seasonings: [] }, {
    observedMainIngredients: ['\u200b', '\u200d', '\u2060', '\ufeff'],
    observedSeasonings: ['\u0000', '\u0001', '\n\t']
  });

  assert.deepEqual(result.recipe.ingredients, []);
  assert.deepEqual(result.recipe.seasonings, []);
  assert.equal(result.diagnostics.evidenceItemRejectedInvalidCount, 7);
});

test('混合名称移除控制和格式字符后保留可见内容', () => {
  const result = preserveEvidenceItemsInRecipe({ ingredients: [], seasonings: [] }, {
    observedMainIngredients: [' 青\u0000\u200b椒 ', '肉\u00a0  丝', '\t番\n茄']
  });

  assert.deepEqual(result.recipe.ingredients.map(row => row.item), ['青椒', '肉 丝', '番茄']);
});

test('名称长度按 Unicode code points 而不是 UTF-16 code units 计算', () => {
  const accepted = `${'菜'.repeat(79)}😀`;
  const rejected = `${'菜'.repeat(80)}😀`;
  const result = preserveEvidenceItemsInRecipe({ ingredients: [], seasonings: [] }, {
    observedMainIngredients: [accepted, rejected]
  });

  assert.deepEqual(result.recipe.ingredients.map(row => row.item), [accepted]);
  assert.equal(result.diagnostics.evidenceItemRejectedTooLongCount, 1);
  assert.equal(result.diagnostics.preservedNameCodepointCount, 80);
});

test('非字符串对象和数值不触发隐式转换', () => {
  const explosive = { toString() { throw new Error('must not stringify'); } };
  const result = preserveEvidenceItemsInRecipe({ ingredients: [], seasonings: [] }, {
    observedMainIngredients: [42, true, explosive, [], null, undefined, '青椒']
  });

  assert.deepEqual(result.recipe.ingredients.map(row => row.item), ['青椒']);
  assert.equal(result.diagnostics.evidenceItemRejectedInvalidCount, 6);
});

test('每类 32 项与总计 48 项追加上限按主料后调料顺序生效', () => {
  const result = preserveEvidenceItemsInRecipe({ ingredients: [], seasonings: [] }, {
    observedMainIngredients: Array.from({ length: 40 }, (_, index) => `主料${index}`),
    observedSeasonings: Array.from({ length: 40 }, (_, index) => `调料${index}`)
  });

  assert.equal(result.recipe.ingredients.length, 32);
  assert.equal(result.recipe.seasonings.length, 16);
  assert.equal(result.diagnostics.evidenceItemRejectedOverLimitCount, 32);
  assert.equal(result.diagnostics.evidenceItemLimitApplied, true);
});

test('累计名称预算达到 2048 code points 后停止追加后续项', () => {
  const names = Array.from(
    { length: 32 },
    (_, index) => `${String(index).padStart(2, '0')}${'菜'.repeat(78)}`
  );
  const result = preserveEvidenceItemsInRecipe({ ingredients: [], seasonings: [] }, {
    observedMainIngredients: names
  });

  assert.equal(result.recipe.ingredients.length, 25);
  assert.equal(result.diagnostics.preservedNameCodepointCount, 2000);
  assert.equal(result.diagnostics.evidenceItemRejectedOverLimitCount, 7);
  assert.equal(result.diagnostics.evidenceItemLimitApplied, true);
});

test('模型现有数组超过追加阈值时不裁剪不改写且追加预算独立', () => {
  const recipe = {
    ingredients: Array.from({ length: 40 }, (_, index) => ({ item: `已有主料${index}`, qty: '1', unit: '份' })),
    seasonings: Array.from({ length: 40 }, (_, index) => ({ item: `已有调料${index}`, qty: '1', unit: '克' }))
  };
  const originalIngredients = structuredClone(recipe.ingredients);
  const originalSeasonings = structuredClone(recipe.seasonings);
  const result = preserveEvidenceItemsInRecipe(recipe, {
    observedMainIngredients: ['新增主料'],
    observedSeasonings: ['新增调料']
  });

  assert.deepEqual(result.recipe.ingredients.slice(0, 40), originalIngredients);
  assert.deepEqual(result.recipe.seasonings.slice(0, 40), originalSeasonings);
  assert.deepEqual(result.recipe.ingredients[40], { item: '新增主料', qty: '', unit: '' });
  assert.deepEqual(result.recipe.seasonings[40], { item: '新增调料', qty: '', unit: '' });
  assert.equal(result.diagnostics.sanitizedIngredientCountBeforePreservation, 40);
  assert.equal(result.diagnostics.sanitizedSeasoningCountBeforePreservation, 40);
});

test('主料与调料 evidence 之间执行精确规范化去重', () => {
  const result = preserveEvidenceItemsInRecipe({ ingredients: [], seasonings: [] }, {
    observedMainIngredients: ['青椒'],
    observedSeasonings: [' 青椒 ', '盐']
  });

  assert.deepEqual(result.recipe.ingredients.map(row => row.item), ['青椒']);
  assert.deepEqual(result.recipe.seasonings.map(row => row.item), ['盐']);
  assert.equal(result.diagnostics.evidenceItemRejectedDuplicateCount, 1);
});
