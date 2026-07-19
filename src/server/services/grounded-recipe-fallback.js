'use strict';

const MAIN_TERMS = [
  '西红柿', '西兰花', '鸡胸肉', '里脊肉', '五花肉', '鸡腿', '鸡肉', '鸡胸', '鸡翅',
  '牛肉', '猪肉', '羊肉', '肉片', '肉丝', '肉末', '排骨', '鱼片', '虾仁', '番茄',
  '鸡蛋', '土豆', '青椒', '豆腐', '茄子', '白菜', '洋葱', '香菇', '米饭', '面条',
  '乌冬', '鱼', '虾'
];

const SEASONING_TERMS = [
  '土豆淀粉', '红薯淀粉', '玉米淀粉', '水淀粉', '白胡椒粉', '黑胡椒粉', '藤椒粉',
  '食用油', '植物油', '小苏打', '甜面酱', '豆瓣酱', '辣椒酱', '生抽', '老抽',
  '料酒', '黄酒', '蚝油', '鱼露', '鸡精', '味精', '淀粉', '鲜藤椒', '藤椒', '花椒',
  '辣椒', '白胡椒', '黑胡椒', '胡椒', '香油', '醋', '盐', '糖', '葱', '姜', '蒜',
  '油', '清水', '高汤', '水'
];

// These phrases carry a shorter food word without proving that the shorter word is
// an ingredient. They participate in longest-match span selection but never become rows.
const PROTECTED_COMPOUNDS = [
  '鱼香肉丝', '红烧牛肉面', '鸡精', '鱼露', '土豆淀粉', '红薯淀粉', '玉米淀粉', '水淀粉'
];

const COOKING_ACTION_RE = /清洗|洗净|去皮|去骨|切块|切片|切丝|改刀|腌制|抓匀|拌匀|加入|放入|倒入|下锅|起锅|热锅|倒油|烧油|翻炒|调味|收汁|出锅|装盘|洗|切|腌|加|放|倒|煎|炒|炸|烤|蒸|煮|焖|炖|撒|淋/u;
const INCIDENTAL_RE = /上次|之前|以前|曾经|对比|相比|讲过|说过|提过|这个问题|那道菜|另一道|推荐|评论区|点赞|收藏|关注|转发/u;
const CHATTER_RE = /大家|朋友们|姐妹们|家人们|好吃到|太香了|绝了|记得|欢迎|主页|链接|挑战/u;
const INCOMPLETE_ACTION_RE = /(?:还是|或者|这个问题|怎么|如何|讲过|说过|提过)[。.!！?？]*$/u;
const LIST_LABEL_RE = /食材|用料|配料|主料|辅料|调料|调味/u;
const UNIT_RE_SOURCE = '(克|千克|斤|两|个|只|块|份|根|把|棵|袋|盒|片|条|勺|茶匙|毫升|ml|mL|杯)';
const QUANTITY_RE_SOURCE = '(\\d+(?:\\.\\d+)?|一|二|两|三|四|五|六|七|八|九|十|半)';
const CHINESE_QUANTITIES = new Map([
  ['一', '1'], ['二', '2'], ['两', '2'], ['三', '3'], ['四', '4'], ['五', '5'],
  ['六', '6'], ['七', '7'], ['八', '8'], ['九', '9'], ['十', '10'], ['半', '0.5']
]);

const TERM_ENTRIES = [
  ...MAIN_TERMS.map(term => ({ term, category: 'main' })),
  ...SEASONING_TERMS.map(term => ({ term, category: 'seasoning' })),
  ...PROTECTED_COMPOUNDS.map(term => ({ term, category: 'protected' }))
].sort((a, b) => b.term.length - a.term.length || a.term.localeCompare(b.term, 'zh-CN'));

function uniqueStrings(values, limit = 24) {
  return [...new Set(values.map(value => String(value || '').trim()).filter(Boolean))].slice(0, limit);
}

function splitSourceSentences(text) {
  return String(text || '')
    .replace(/[“”"']/gu, '')
    .split(/[。！？!?；;\n]+|(?<=[，,])|(?:这个时候|下一步|然后|接着|之后|最后|等到|直到)/u)
    .map(sentence => sentence.trim().replace(/^[，,：:\s]+|[，,：:\s]+$/gu, ''))
    .filter(Boolean);
}

function findLongestTermSpans(sentence) {
  const spans = [];
  let compoundCollisionCount = 0;
  for (let index = 0; index < sentence.length;) {
    const matches = TERM_ENTRIES.filter(entry => sentence.startsWith(entry.term, index));
    if (!matches.length) {
      index += 1;
      continue;
    }
    const selected = matches[0];
    const end = index + selected.term.length;
    const shorterMatches = TERM_ENTRIES.filter(entry =>
      entry.term.length < selected.term.length && selected.term.includes(entry.term)
    );
    compoundCollisionCount += shorterMatches.length;
    spans.push({ ...selected, start: index, end });
    index = end;
  }
  return { spans, compoundCollisionCount };
}

function normalizeQuantity(raw) {
  const value = String(raw || '').trim();
  if (/^\d+(?:\.\d+)?$/u.test(value)) return value;
  return CHINESE_QUANTITIES.get(value) || '';
}

function getExplicitQuantity(sentence, span) {
  const escapedTerm = span.term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const patterns = [
    new RegExp(`${escapedTerm}\\s*${QUANTITY_RE_SOURCE}\\s*${UNIT_RE_SOURCE}`, 'u'),
    new RegExp(`${QUANTITY_RE_SOURCE}\\s*${UNIT_RE_SOURCE}\\s*${escapedTerm}`, 'u')
  ];
  for (const pattern of patterns) {
    const match = sentence.match(pattern);
    if (!match) continue;
    return { qty: normalizeQuantity(match[1]), unit: String(match[2] || '') };
  }
  const suitablePatterns = [
    new RegExp(`${escapedTerm}\\s*(适量|少许)`, 'u'),
    new RegExp(`(适量|少许)\\s*${escapedTerm}`, 'u')
  ];
  for (const pattern of suitablePatterns) {
    const match = sentence.match(pattern);
    if (match) return { qty: '', unit: String(match[1] || '') };
  }
  return { qty: '', unit: '' };
}

function isIncidentalDishMention(sentence) {
  return INCIDENTAL_RE.test(String(sentence || ''));
}

function classifyFallbackSentence(sentence) {
  const text = String(sentence || '').trim();
  if (!text) return { type: 'empty', grounded: false };
  if (isIncidentalDishMention(text)) return { type: 'incidental', grounded: false };
  if (CHATTER_RE.test(text) && !COOKING_ACTION_RE.test(text)) return { type: 'chatter', grounded: false };
  if (COOKING_ACTION_RE.test(text) && !INCOMPLETE_ACTION_RE.test(text)) {
    const { spans } = findLongestTermSpans(text);
    if (spans.length && spans.every(span => span.category === 'protected')) {
      return { type: 'incidental', grounded: false };
    }
    const hasObject = spans.some(span => span.category !== 'protected') || /肉|菜|蛋|面|饭|锅|汁|块|片|丝/u.test(text);
    return { type: 'action', grounded: hasObject || /出锅|装盘|收汁/u.test(text) };
  }
  return { type: 'context', grounded: false };
}

function finishGroundedAction(sentence) {
  const text = String(sentence || '')
    .replace(/^[\s\-•·]*(?:第[一二三四五六七八九十百零\d]+步[:：]?|步骤[一二三四五六七八九十百零\d]+[:：]?|[一二三四五六七八九十]+[、.．。)）]\s*|\d+\s*[.、．。)）:：]\s*|\(\d+\)\s*)/u, '')
    .trim();
  if (!text) return '';
  return /[。.!！?？]$/u.test(text) ? text : `${text}。`;
}

function extractGroundedActionSentences(sources) {
  const actions = [];
  let rejectedIncidentalCount = 0;
  for (const source of sources) {
    for (const sentence of splitSourceSentences(source.text)) {
      const classification = classifyFallbackSentence(sentence);
      if (classification.type === 'incidental') {
        rejectedIncidentalCount += 1;
        continue;
      }
      if (classification.type !== 'action' || !classification.grounded) continue;
      const action = finishGroundedAction(sentence);
      if (action && action.length <= 140) actions.push(action);
    }
  }
  return { actions: uniqueStrings(actions, 12), rejectedIncidentalCount };
}

function collectGroundedItems(sources) {
  const accepted = new Map();
  let rejectedIncidentalCount = 0;
  let rejectedCompoundCollisionCount = 0;

  for (const source of sources) {
    for (const sentence of splitSourceSentences(source.text)) {
      const { spans, compoundCollisionCount } = findLongestTermSpans(sentence);
      rejectedCompoundCollisionCount += compoundCollisionCount;
      if (!spans.length) continue;
      if (isIncidentalDishMention(sentence)) {
        rejectedIncidentalCount += 1;
        continue;
      }
      const outputSpans = spans.filter(span => span.category !== 'protected');
      const listLike = LIST_LABEL_RE.test(sentence) || (outputSpans.length >= 2 && /[、，,\/]/u.test(sentence));
      const actionLike = COOKING_ACTION_RE.test(sentence) && !INCOMPLETE_ACTION_RE.test(sentence);
      for (const span of outputSpans) {
        const quantity = getExplicitQuantity(sentence, span);
        const hasQuantity = Boolean(quantity.qty || quantity.unit);
        const waterIsGrounded = !/^(?:水|清水|高汤)$/u.test(span.term)
          || /加水|加入水|倒水|添水|清水|高汤|加汤|倒汤/u.test(sentence);
        if ((!listLike && !actionLike && !hasQuantity) || (!listLike && !hasQuantity && !waterIsGrounded)) continue;
        const current = accepted.get(span.term);
        const row = { item: span.term, qty: quantity.qty, unit: quantity.unit, category: span.category };
        if (!current || (!current.qty && !current.unit && (row.qty || row.unit))) accepted.set(span.term, row);
      }
    }
  }

  const rows = [...accepted.values()];
  return {
    ingredients: rows.filter(row => row.category === 'main').map(({ category: _category, ...row }) => row),
    seasonings: rows.filter(row => row.category === 'seasoning').map(({ category: _category, ...row }) => row),
    rejectedIncidentalCount,
    rejectedCompoundCollisionCount
  };
}

function cleanDishName(value) {
  return String(value || '')
    .replace(/https?:\/\/\S+/giu, ' ')
    .replace(/#\S+/gu, ' ')
    .replace(/小红书|复制打开|详细版教程|详细教程|教程|做法|分享|收藏|点赞|关注/gu, ' ')
    .replace(/[｜|【】\[\]()（）]/gu, ' ')
    .replace(/\s+/gu, ' ')
    .trim()
    .split(/[。！？!?，,；;：:\n]/u)[0]
    .trim()
    .slice(0, 18);
}

function extractGroundedDishName({ sourceMetadata = {}, trustedPageText = '', transcriptText = '', ocrText = '' } = {}) {
  const candidates = [
    sourceMetadata.sourceTitle,
    trustedPageText,
    ocrText,
    transcriptText
  ].map(cleanDishName).filter(Boolean);
  const knownDish = candidates.map(value => value.match(/[\p{Script=Han}]{0,6}(?:肉丝|炒蛋|鸡丁|鸡腿|排骨|豆腐|拌面|炒饭)/u)?.[0]).find(Boolean);
  return knownDish || candidates[0] || '未命名视频菜谱';
}

function buildGroundedFallbackEvidence({ trustedPageText = '', transcriptText = '', ocrText = '', userText = '', sourceMetadata = {} } = {}) {
  const hasMediaEvidence = Boolean(String(transcriptText || ocrText).trim());
  const sources = [
    { type: 'transcript', text: transcriptText },
    { type: 'ocr', text: ocrText },
    ...(!hasMediaEvidence ? [{ type: 'page', text: trustedPageText }] : []),
    { type: 'user', text: userText }
  ].filter(source => String(source.text || '').trim());
  const items = collectGroundedItems(sources);
  const actions = extractGroundedActionSentences(sources);
  return {
    dishNameCandidates: [extractGroundedDishName({ sourceMetadata, trustedPageText, transcriptText, ocrText })],
    observedMainIngredients: items.ingredients.map(row => row.item),
    observedSeasonings: items.seasonings.map(row => row.item),
    observedAromatics: [],
    observedLiquids: [],
    observedActions: actions.actions.map((action, index) => ({
      order: index + 1,
      action,
      ingredients: findLongestTermSpans(action).spans
        .filter(span => span.category !== 'protected')
        .map(span => span.term),
      evidenceText: action,
      confidence: 'medium'
    })),
    observedTimes: [],
    observedTools: [],
    uncertainItems: [],
    missingInfo: ['AI evidence JSON 解析失败，当前 evidence 仅保留可信来源中的明确内容。'],
    sourceConfidence: actions.actions.length >= 2 ? 'medium' : 'low'
  };
}

function buildGroundedFallbackRecipe({
  trustedPageText = '',
  transcriptText = '',
  ocrText = '',
  userText = '',
  sourceMetadata = {},
  mediaDiagnostics = {},
  fallbackReason = 'recipe_json_failed'
} = {}) {
  const hasMediaEvidence = Boolean(String(transcriptText || ocrText).trim());
  const sources = [
    { type: 'transcript', text: transcriptText },
    { type: 'ocr', text: ocrText },
    ...(!hasMediaEvidence ? [{ type: 'page', text: trustedPageText }] : []),
    { type: 'user', text: userText }
  ].filter(source => String(source.text || '').trim());
  const items = collectGroundedItems(sources);
  const actions = extractGroundedActionSentences(sources);
  const warnings = [
    'AI 整理暂时不可用，当前草稿仅保留来源中明确识别到的信息。',
    '部分食材用量和完整步骤未能可靠识别，请人工确认。'
  ];
  if (!actions.actions.length) warnings.push('未能可靠提取做法步骤，请参考来源并手动补充。');
  if (Array.isArray(mediaDiagnostics.warnings)) warnings.push(...mediaDiagnostics.warnings);
  const diagnostics = {
    fallbackUsed: true,
    fallbackReason,
    fallbackGroundedActionCount: actions.actions.length,
    fallbackGroundedIngredientCount: items.ingredients.length,
    fallbackGroundedSeasoningCount: items.seasonings.length,
    fallbackRejectedIncidentalCount: items.rejectedIncidentalCount + actions.rejectedIncidentalCount,
    fallbackRejectedCompoundCollisionCount: items.rejectedCompoundCollisionCount,
    fallbackUsedPageText: sources.some(source => source.type === 'page'),
    fallbackUsedTranscript: sources.some(source => source.type === 'transcript'),
    fallbackUsedOcr: sources.some(source => source.type === 'ocr'),
    fallbackUsedUserText: sources.some(source => source.type === 'user'),
    fallbackFabricatedQuantityCount: 0
  };
  return {
    name: extractGroundedDishName({ sourceMetadata, trustedPageText, transcriptText, ocrText }),
    tags: ['AI草稿', '视频导入'],
    ingredients: items.ingredients,
    seasonings: items.seasonings,
    method: actions.actions,
    warnings: uniqueStrings(warnings, 12),
    needsReview: true,
    sourceType: 'xiaohongshu',
    diagnostics
  };
}

module.exports = {
  buildGroundedFallbackEvidence,
  buildGroundedFallbackRecipe,
  classifyFallbackSentence,
  extractGroundedActionSentences,
  findLongestTermSpans,
  isIncidentalDishMention
};
