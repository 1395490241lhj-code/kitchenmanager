import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const {
  cleanRecipeSteps,
  isIngredientListOnly,
  isNoiseClause,
  isVagueStep,
  splitCompoundStep,
  stripNoiseClauses
} = require('../src/server/services/recipe-step-cleanup.js');
const { buildGroundedFallbackRecipe } = require('../src/server/services/grounded-recipe-fallback.js');

const steps = input => cleanRecipeSteps(input).steps;
const joined = input => steps(input).join(' ');

// ---------------------------------------------------------------------------
// 1. ASR 大量口语与重复
// ---------------------------------------------------------------------------

test('ASR 口语、语气词和主语被清掉，操作本身完整保留', () => {
  const out = steps([
    '那么我们先把猪肉切成肉丝啊',
    '我们再把青椒切丝呢'
  ]);
  assert.deepEqual(out, ['先把猪肉切成肉丝。', '再把青椒切丝。']);
});

test('同一动作的多次口语重复只保留一条', () => {
  const out = steps([
    '肉丝下锅翻炒',
    '肉丝下锅翻炒一下',
    '把肉丝下锅翻炒'
  ]);
  assert.equal(out.length, 1);
});

// ---------------------------------------------------------------------------
// 2. OCR 与 ASR 重复识别同一动作
// ---------------------------------------------------------------------------

test('OCR 与 ASR 对同一动作的不同措辞被近似去重', () => {
  const out = steps(['猪肉切成肉丝', '猪肉切丝']);
  assert.equal(out.length, 1, `期望去重，实际：${JSON.stringify(out)}`);
});

test('去重时保留信息更全的一条（时间/火候不会被短句顶掉）', () => {
  const out = steps(['小火煎3分钟', '煎一下']);
  assert.deepEqual(out, ['小火煎3分钟。']);
});

test('去重保留细节的方向与输入顺序无关', () => {
  const out = steps(['煎一下', '小火煎3分钟']);
  assert.deepEqual(out, ['小火煎3分钟。']);
});

test('动作已被更完整步骤覆盖的极短残片被删除', () => {
  const out = steps([
    '肉丝加入生抽和淀粉抓匀，腌制10分钟',
    '腌一下'
  ]);
  assert.equal(out.length, 1);
  assert.match(out[0], /腌制10分钟/u);
});

test('OCR 把 ASR 两步压成一句时，跨步骤重复也被识别', () => {
  const out = steps([
    '锅中倒油烧热',
    '下入肉丝炒至变色盛出',
    '倒油烧热下入肉丝' // OCR 版本：内容完全被上面两条覆盖
  ]);
  assert.equal(out.length, 2, `期望丢弃跨步骤重复，实际：${JSON.stringify(out)}`);
});

test('跨步骤覆盖判定不会删掉带来新信息的步骤', () => {
  const out = steps([
    '锅中倒油烧热',
    '下入肉丝炒至变色盛出',
    '倒油烧热下入肉丝煎3分钟' // 多了时间，必须保留
  ]);
  assert.equal(out.length, 3);
  assert.match(out.join(' '), /3分钟/u);
});

test('不同动作的短句不会被误当成重复', () => {
  const out = steps(['青椒切丝', '大蒜切末']);
  assert.equal(out.length, 1, '同阶段短句应合并为一步');
  assert.match(out[0], /青椒切丝/u);
  assert.match(out[0], /大蒜切末/u);
});

// ---------------------------------------------------------------------------
// 3. 食材介绍混入步骤
// ---------------------------------------------------------------------------

test('整条食材清单不会作为步骤保留', () => {
  const out = steps([
    '食材：猪肉、青椒、大蒜、生抽',
    '猪肉切丝'
  ]);
  assert.deepEqual(out, ['猪肉切丝。']);
});

test('无标签的纯食材罗列同样被剔除', () => {
  assert.equal(isIngredientListOnly('猪肉、青椒、大蒜、生抽、淀粉'), true);
  assert.equal(isIngredientListOnly('加入生抽、老抽和淀粉抓匀'), false, '带动作的句子不是配料表');
});

test('操作里自然提到食材不会被误删', () => {
  const out = steps(['加入腌好的肉丝翻炒均匀']);
  assert.deepEqual(out, ['加入腌好的肉丝翻炒均匀。']);
});

// ---------------------------------------------------------------------------
// 4. 一个句子包含多个独立操作
// ---------------------------------------------------------------------------

test('一条文本里的多个独立主要动作被拆分', () => {
  const out = steps([
    '锅中倒油烧热，下入肉丝快速滑散，炒至变色后盛出，然后锅中留底油放入蒜末炒香，再加入青椒丝大火翻炒'
  ]);
  assert.ok(out.length >= 2, `期望拆分，实际：${JSON.stringify(out)}`);
  assert.match(out[0], /倒油烧热/u);
  assert.ok(out.some(step => /蒜末炒香/u.test(step)));
});

test('紧密连续的动作不会被切碎', () => {
  const out = splitCompoundStep('下入肉丝快速滑散，炒至变色后盛出');
  assert.deepEqual(out, ['下入肉丝快速滑散，炒至变色后盛出'], '同一阶段的连续动作应保持一步');
});

// ---------------------------------------------------------------------------
// 5. 多个零碎句子实际属于同一阶段
// ---------------------------------------------------------------------------

test('同阶段的零碎短句被合并成一步', () => {
  const out = steps(['青椒去籽切丝', '蒜切末备用']);
  assert.equal(out.length, 1);
  assert.equal(out[0], '青椒去籽切丝，蒜切末备用。');
});

test('不同阶段的短句不会被错误合并', () => {
  const out = steps(['青椒切丝', '锅中倒油']);
  assert.equal(out.length, 2);
});

// ---------------------------------------------------------------------------
// 6-9. 火候 / 时间 / 温度 / 状态判断不能丢失
// ---------------------------------------------------------------------------

test('火候被保留', () => {
  assert.match(joined(['大火快速翻炒30秒']), /大火/u);
  assert.match(joined(['转小火慢炖']), /小火/u);
});

test('时间被保留', () => {
  assert.match(joined(['腌制10分钟']), /10分钟/u);
  assert.match(joined(['盖盖焖15分钟']), /15分钟/u);
});

test('温度被保留', () => {
  assert.match(joined(['烤箱180度预热10分钟']), /180度/u);
  assert.match(joined(['油温烧到六成热']), /六成热/u);
});

test('状态判断被保留', () => {
  assert.match(joined(['翻炒至肉丝变色']), /变色/u);
  assert.match(joined(['煮至汤汁浓稠']), /浓稠/u);
  assert.match(joined(['青椒断生后放回肉丝']), /断生/u);
});

test('与操作直接相关的用量比例被保留', () => {
  assert.match(joined(['加入生抽2勺、老抽半勺炒匀']), /2勺/u);
});

// ---------------------------------------------------------------------------
// 10. 广告 / 点赞 / 收藏等社交话术被清理
// ---------------------------------------------------------------------------

test('纯社交话术整条被删除', () => {
  const out = steps([
    '大家好今天给大家分享一道青椒肉丝',
    '猪肉切丝',
    '好吃到爆，家人们记得点赞收藏关注，下期见'
  ]);
  assert.deepEqual(out, ['猪肉切丝。']);
});

test('同一句里的社交子句被删除，操作子句保留', () => {
  const out = steps(['肉丝放进去炒一下，大家记得点赞收藏']);
  assert.equal(out.length, 1);
  assert.match(out[0], /肉丝放进去炒一下/u);
  assert.doesNotMatch(out[0], /点赞|收藏/u);
});

test('背景故事被删除', () => {
  assert.equal(isNoiseClause('青椒非常有营养'), true);
  assert.equal(isNoiseClause('小时候我妈经常做这道菜'), true);
  assert.equal(isNoiseClause('加入青椒翻炒'), false);
});

test('提醒类文本不会留在步骤里', () => {
  const out = steps(['请人工确认调料用量', '加入盐调味']);
  assert.deepEqual(out, ['加入盐调味。']);
});

test('空泛步骤被删除', () => {
  assert.equal(isVagueStep('准备食材'), true);
  assert.equal(isVagueStep('开始烹饪'), true);
  assert.equal(isVagueStep('猪肉切丝'), false);
  assert.deepEqual(steps(['准备所有食材备用', '开始烹饪', '猪肉切丝']), ['猪肉切丝。']);
});

// ---------------------------------------------------------------------------
// 11. 原始文本顺序有噪声
// ---------------------------------------------------------------------------

test('明显错位的备料步骤被前移到第一个下锅步骤之前', () => {
  const out = steps([
    '锅中倒油烧热下入肉丝翻炒',
    '青椒去籽切丝',
    '加入青椒丝翻炒均匀'
  ]);
  assert.equal(out[0], '青椒去籽切丝。');
  assert.match(out[1], /倒油烧热/u);
});

test('纯收尾步骤被移到末尾', () => {
  const out = steps([
    '出锅装盘',
    '锅中倒油烧热下入肉丝翻炒',
    '加入青椒丝继续翻炒'
  ]);
  assert.match(out[out.length - 1], /出锅装盘/u);
});

test('同时包含真实烹饪动作的收尾句不会被移动（保守边界）', () => {
  // 「炒匀后出锅」既是调味也是收尾，位置由来源决定，不做推测性重排。
  const input = ['炒匀后出锅装盘', '锅中倒油烧热下入肉丝翻炒'];
  const result = cleanRecipeSteps(input);
  assert.equal(result.diagnostics.stepCleanupReorderedCount, 0);
});

test('本来就有序的步骤不会被重排', () => {
  const input = ['猪肉切丝', '锅中倒油烧热下入肉丝翻炒', '加入青椒丝翻炒均匀', '调味后出锅装盘'];
  const result = cleanRecipeSteps(input);
  assert.equal(result.diagnostics.stepCleanupReorderedCount, 0);
  assert.equal(result.steps.length, 4);
});

// ---------------------------------------------------------------------------
// 12. 信息不足时不得编造
// ---------------------------------------------------------------------------

test('信息很少时保持简略，不补全任何动作', () => {
  const out = steps(['猪肉切丝']);
  assert.deepEqual(out, ['猪肉切丝。']);
});

test('后处理不会引入原文没有的时间、温度或调味料', () => {
  const input = ['猪肉切丝', '下锅炒熟'];
  const out = joined(input);
  assert.doesNotMatch(out, /分钟|小时|度|℃/u);
  assert.doesNotMatch(out, /生抽|老抽|盐|糖|料酒/u);
});

test('输出内容始终是输入内容的子集（纯减法与重排）', () => {
  const input = [
    '大家好今天分享青椒肉丝',
    '猪肉切成肉丝，加入生抽、淀粉抓匀腌制10分钟',
    '锅中倒油烧热下入肉丝炒至变色'
  ];
  const sourceChars = new Set(input.join('').replace(/\s/gu, ''));
  for (const step of steps(input)) {
    for (const char of step.replace(/[。\s]/gu, '')) {
      assert.ok(sourceChars.has(char), `输出出现了原文没有的字符：${char}`);
    }
  }
});

// ---------------------------------------------------------------------------
// 13. AI 返回格式不规范
// ---------------------------------------------------------------------------

test('各种序号前缀被剥掉', () => {
  const out = steps([
    '1. 猪肉切丝',
    '第二步：青椒切丝',
    '步骤3：蒜切末',
    '(4) 下锅翻炒',
    '五、出锅装盘'
  ]);
  for (const step of out) {
    assert.doesNotMatch(step, /^(?:\d|第[一二三四五六七八九十]|步骤|[一二三四五六七八九十][、.])/u, `残留序号：${step}`);
  }
});

test('叠加的序号前缀与字幕时间码被一并剥掉', () => {
  const out = steps(['1. 第二步：猪肉切丝', '00:12 青椒切丝']);
  assert.match(out[0], /^猪肉切丝/u);
  assert.doesNotMatch(joined(['00:12 青椒切丝']), /00:12|\d{1,2}:\d{2}/u);
});

test('method 传入字符串而非数组时按行解析', () => {
  const out = steps('猪肉切丝\n锅中倒油烧热下入肉丝翻炒');
  assert.equal(out.length, 2);
});

test('空值与非法类型安全返回空数组', () => {
  assert.deepEqual(steps(null), []);
  assert.deepEqual(steps(undefined), []);
  assert.deepEqual(steps(123), []);
  assert.deepEqual(steps([]), []);
  assert.deepEqual(steps(['', '   ']), []);
});

test('全是噪声时回退到归一化文本而不是清空做法', () => {
  const result = cleanRecipeSteps(['记得点赞收藏关注']);
  assert.equal(result.diagnostics.stepCleanupFellBack, true);
  assert.ok(result.steps.length >= 1, '绝不返回空做法');
});

// ---------------------------------------------------------------------------
// 14. AI 不可用时 fallback 仍能生成基本可用步骤
// ---------------------------------------------------------------------------

test('fallback 步骤同样经过整理：无社交话术、无重复', () => {
  const recipe = buildGroundedFallbackRecipe({
    transcriptText: '今天分享青椒肉丝，记得点赞收藏关注。猪肉切成肉丝。加入生抽和淀粉抓匀腌制10分钟。锅中倒油烧热，下入肉丝炒至变色。',
    ocrText: '猪肉切丝。倒油烧热下入肉丝。',
    sourceMetadata: { sourceTitle: '青椒肉丝' }
  });

  assert.ok(recipe.method.length >= 2, `fallback 应产出可用步骤：${JSON.stringify(recipe.method)}`);
  for (const step of recipe.method) {
    assert.doesNotMatch(step, /点赞|收藏|关注/u, `fallback 步骤混入社交话术：${step}`);
  }
  assert.match(recipe.method.join(' '), /10分钟/u, 'fallback 也必须保留时间');
  assert.ok(
    !recipe.method.some(step => /^倒油烧热下入肉丝/u.test(step)),
    `fallback 不应保留 OCR 与 ASR 的跨步骤重复：${JSON.stringify(recipe.method)}`
  );
  assert.equal(new Set(recipe.method).size, recipe.method.length, 'fallback 步骤不应重复');
});

test('fallback 保留只带时间/火候的操作子句（腌制10分钟不会被丢掉）', () => {
  const recipe = buildGroundedFallbackRecipe({
    transcriptText: '猪肉切成肉丝，加入生抽抓匀，腌制10分钟。锅中倒油，小火煎3分钟。',
    sourceMetadata: { sourceTitle: '青椒肉丝' }
  });
  const method = recipe.method.join(' ');
  assert.match(method, /10分钟/u, '时间不能丢');
  assert.match(method, /小火|3分钟/u, '火候/时间不能丢');
});

test('fallback 暴露步骤整理诊断字段', () => {
  const recipe = buildGroundedFallbackRecipe({
    transcriptText: '猪肉切丝。锅中倒油烧热下入肉丝翻炒。',
    sourceMetadata: { sourceTitle: '青椒肉丝' }
  });
  assert.equal(typeof recipe.diagnostics.stepCleanupOutputCount, 'number');
  assert.equal(recipe.diagnostics.fallbackUsed, true);
});

// ---------------------------------------------------------------------------
// 15-16. 菜名 / 食材 / 用量识别不受影响
// ---------------------------------------------------------------------------

test('步骤整理不改变 fallback 的菜名与食材识别结果', () => {
  const args = {
    transcriptText: '今天分享青椒肉丝，记得点赞。猪肉200克切丝，加入生抽2勺抓匀。锅中倒油烧热下入肉丝翻炒。',
    sourceMetadata: { sourceTitle: '青椒肉丝' }
  };
  const recipe = buildGroundedFallbackRecipe(args);

  assert.equal(recipe.name, '青椒肉丝');
  assert.ok(recipe.ingredients.some(row => row.item === '猪肉'), JSON.stringify(recipe.ingredients));
  assert.ok(recipe.seasonings.some(row => row.item === '生抽'), JSON.stringify(recipe.seasonings));
  const pork = recipe.ingredients.find(row => row.item === '猪肉');
  assert.equal(pork.qty, '200');
  assert.equal(pork.unit, '克');
});

// ---------------------------------------------------------------------------
// 17. 中文菜谱的自然语言质量
// ---------------------------------------------------------------------------

test('每一步以句号收尾且不以标点或语气词开头', () => {
  const out = steps([
    '，猪肉切丝',
    '锅中倒油烧热下入肉丝翻炒'
  ]);
  for (const step of out) {
    assert.match(step, /[。！？]$/u, `缺少句尾标点：${step}`);
    assert.doesNotMatch(step, /^[，,。；;：:、]/u, `以标点开头：${step}`);
  }
});

test('端到端：杂乱的小红书 ASR/OCR 整理成清晰步骤', () => {
  const result = cleanRecipeSteps([
    '大家好今天给大家分享一道超级好吃的青椒肉丝，青椒非常有营养，记得点赞收藏关注哦',
    '食材：猪肉、青椒、大蒜、生抽、淀粉',
    '1. 猪肉切成肉丝',
    '00:12 猪肉切丝',
    '肉丝里加入生抽、淀粉和少量食用油抓匀，腌制10分钟',
    '腌一下',
    '青椒去籽切丝',
    '蒜切末备用',
    '锅中倒油烧热，下入肉丝快速滑散，炒至变色后盛出，然后锅中留底油放入蒜末炒香，再加入青椒丝大火翻炒',
    '第二步：青椒断生后放回肉丝，加入调味料炒匀即可出锅',
    '好吃到爆，家人们记得三连，下期见'
  ]);

  assert.deepEqual(result.steps, [
    '猪肉切成肉丝。',
    '肉丝里加入生抽、淀粉和少量食用油抓匀，腌制10分钟。',
    '青椒去籽切丝，蒜切末备用。',
    '锅中倒油烧热，下入肉丝快速滑散，炒至变色后盛出。',
    '锅中留底油放入蒜末炒香，再加入青椒丝大火翻炒。',
    '青椒断生后放回肉丝，加入调味料炒匀即可出锅。'
  ]);
  assert.equal(result.diagnostics.stepCleanupNoiseRemovedCount, 2);
  assert.equal(result.diagnostics.stepCleanupIngredientListRemovedCount, 1);
  assert.equal(result.diagnostics.stepCleanupDuplicateRemovedCount, 2);
  assert.equal(result.diagnostics.stepCleanupFellBack, false);
});

// ---------------------------------------------------------------------------
// 18. 非小红书导入渠道不受意外影响
// ---------------------------------------------------------------------------

test('干净的手写/网页菜谱步骤原样通过（只补句号）', () => {
  const input = [
    '猪肉切丝，加入生抽、淀粉和少量食用油抓匀，腌制10分钟。',
    '青椒去籽切丝，蒜切末备用。',
    '锅中倒油烧热，下入肉丝快速滑散，炒至变色后盛出。',
    '锅中留底油，放入蒜末炒香，再加入青椒丝大火翻炒。',
    '青椒断生后放回肉丝，加入调味料炒匀即可。'
  ];
  const result = cleanRecipeSteps(input);
  assert.deepEqual(result.steps, input, '正常菜谱不应被改写');
  assert.equal(result.diagnostics.stepCleanupNoiseRemovedCount, 0);
  assert.equal(result.diagnostics.stepCleanupDuplicateRemovedCount, 0);
  assert.equal(result.diagnostics.stepCleanupReorderedCount, 0);
});

test('烘焙类（非中式炒菜）步骤不会被误删或误合并', () => {
  const input = [
    '黄油室温软化后加入细砂糖打发至颜色变浅。',
    '分三次加入蛋液，每次搅拌均匀后再加下一次。',
    '筛入低筋面粉翻拌至无干粉。',
    '烤箱预热180度，中层烤25分钟。'
  ];
  assert.deepEqual(cleanRecipeSteps(input).steps, input);
});

test('子句降噪对没有噪声的句子是恒等变换', () => {
  const sentence = '锅中倒油烧热，下入肉丝快速滑散，炒至变色后盛出。';
  assert.equal(stripNoiseClauses(sentence), sentence);
});
