import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const {
  assessPageRecipeCompleteness,
  decidePageTextPreference,
  hasContinuousRecipeSteps
} = require('../src/server/services/page-source');

const sparseSocialPageText = [
  '家常料理挑战，今天介绍常见食材和切配技巧。',
  '主料展示完成，先切片再切丝。',
  '第一段讲切片要均匀。',
  '第二段继续改刀，大小保持一致。',
  '第三段说明切配准备。',
  '页面还包含系列介绍、作者说明、标签和推荐内容，篇幅很长但没有可执行内容。'.repeat(3)
].join('\n');

const completeRecipeText = [
  '食材：鸡腿2只、土豆1个。',
  '调料：生抽2勺、盐2克、淀粉1勺。',
  '做法：',
  '1. 鸡腿洗净擦干，土豆去皮切块。',
  '2. 鸡腿加入生抽、盐和淀粉抓匀腌制。',
  '3. 锅中热油，放入鸡腿煎熟，再放入土豆翻炒后出锅。',
  '以上步骤按顺序操作，页面正文已经给出明确对象、用量和完整烹饪过程。'.repeat(4)
].join('\n');

test('稀疏社交页面可通过旧动作词门槛，但不能通过多阶段完整度判断', () => {
  assert.ok(sparseSocialPageText.length > 180);
  assert.equal(hasContinuousRecipeSteps(sparseSocialPageText), true);

  const assessment = assessPageRecipeCompleteness(sparseSocialPageText);
  assert.equal(assessment.isComplete, false);
  assert.equal(assessment.hasPreparationStage, true);
  assert.equal(assessment.hasCookingStage, false);
  assert.equal(assessment.reason, 'missing_cooking_stage');

  const preference = decidePageTextPreference({
    text: sparseSocialPageText,
    sourceType: 'xiaohongshu',
    hasVideoCandidate: true
  });
  assert.equal(preference.pageTextPreferred, false);
});

test('有视频的完整小红书页面可以继续优先使用页面文字', () => {
  const preference = decidePageTextPreference({
    text: completeRecipeText,
    sourceType: 'xiaohongshu',
    hasVideoCandidate: true
  });

  assert.equal(preference.pageTextPreferred, true);
  assert.equal(preference.reason, 'page_complete');
  assert.ok(preference.completeness.actionSegmentCount >= 3);
  assert.ok(preference.completeness.stageCount >= 3);
  assert.equal(preference.completeness.hasPreparationStage, true);
  assert.equal(preference.completeness.hasSeasoningStage, true);
  assert.equal(preference.completeness.hasCookingStage, true);
  assert.equal(preference.completeness.hasIngredientSection, true);
  assert.equal(preference.completeness.hasInstructionSection, true);
});

test('多个同类切配动作不能冒充多阶段完整菜谱', () => {
  const assessment = assessPageRecipeCompleteness([
    '第一步：根茎类食材洗净。',
    '第二步：全部切片。',
    '第三步：再改刀切丝。'
  ].join('\n'));

  assert.equal(assessment.actionSegmentCount, 3);
  assert.equal(assessment.stageCount, 1);
  assert.equal(assessment.hasCookingStage, false);
  assert.equal(assessment.isComplete, false);
});

test('准备和调味充分但缺少实际烹饪时仍不完整', () => {
  const assessment = assessPageRecipeCompleteness([
    '食材：鸡蛋2个、豆腐1块。',
    '鸡蛋打散，豆腐切块。',
    '加入盐和生抽拌匀。',
    '继续抓匀腌制入味。'
  ].join('\n'));

  assert.ok(assessment.actionSegmentCount >= 3);
  assert.equal(assessment.hasPreparationStage, true);
  assert.equal(assessment.hasSeasoningStage, true);
  assert.equal(assessment.hasCookingStage, false);
  assert.equal(assessment.isComplete, false);
  assert.equal(assessment.reason, 'missing_cooking_stage');
});

test('只有一个模糊烹饪句不能判定页面完整', () => {
  const assessment = assessPageRecipeCompleteness('食材已经准备完成，下锅炒熟即可。');

  assert.equal(assessment.hasCookingStage, true);
  assert.equal(assessment.actionSegmentCount, 1);
  assert.equal(assessment.isComplete, false);
  assert.equal(assessment.reason, 'insufficient_action_segments');
});

test('普通网页继续沿用既有页面优先门槛', () => {
  const preference = decidePageTextPreference({
    text: sparseSocialPageText,
    sourceType: 'web',
    hasVideoCandidate: true
  });

  assert.equal(preference.pageTextPreferred, true);
  assert.equal(preference.reason, 'page_complete');
});

test('没有视频候选时不尝试媒体且保留页面 fallback 决策', () => {
  const preference = decidePageTextPreference({
    text: '页面只有一道菜的标题。',
    sourceType: 'xiaohongshu',
    hasVideoCandidate: false
  });

  assert.equal(preference.pageTextPreferred, false);
  assert.equal(preference.reason, 'no_video_candidate');
});
