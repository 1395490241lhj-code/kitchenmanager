'use strict';

/*
 * recipe-step-cleanup.js —— 菜谱步骤的确定性后处理（纯函数，无网络/无 AI/无 DOM）。
 *
 * 定位：AI（或 fallback）产出的 method 数组进入 sanitizeRecipe 之后、落库之前的
 * 最后一道整理工序。它只做「减法与重排」，永远不会凭空补充原文没有的动作、时间、
 * 温度或调味料：
 *
 *   1. 归一化：剥序号 / 时间码 / 字幕残片 / 语气词 / 口语主语。
 *   2. 子句级降噪：删掉广告、寒暄、点赞收藏、背景故事等「没有烹饪动作」的子句，
 *      但保留同一句里真正的操作子句。
 *   3. 食材清单剔除：整条只是食材罗列（无动作）时删除，避免配料表混进步骤。
 *   4. 拆分：一条文本里存在多个独立主要动作时按阶段边界拆开。
 *   5. 近似去重：OCR 与 ASR 对同一动作的重复识别合并，保留信息更全的一条。
 *   6. 合并：连续的零碎短句若属于同一阶段则合并成一步。
 *   7. 保守重排：明显的备料步骤前移到第一个下锅步骤之前，收尾步骤后移到末尾。
 *
 * 保守原则：任何一步若会把步骤清空，则回退到上一阶段的结果，并记录 diagnostics。
 */

// ---------------------------------------------------------------------------
// 词表 / 正则
// ---------------------------------------------------------------------------

// 烹饪动作。只要子句命中它，就一定不会被当成噪声删除。
const COOKING_ACTION_RE = /清洗|洗净|沥干|擦干|去皮|去籽|去骨|去筋|改刀|切块|切片|切丝|切段|切末|切碎|拍碎|剁|腌制|腌|抓匀|拌匀|上浆|裹粉|焯水|过油|热锅|起锅|下锅|倒油|烧油|烧热|下入|放入|加入|倒入|淋入|撒入|撒|淋|翻炒|爆香|煸|滑散|滑炒|炒|煎|炸|烤|蒸|煮|焖|炖|烧|收汁|勾芡|调味|出锅|装盘|盛出|盛入|备用|静置|冷藏|解冻|泡发|浸泡|搅拌|揉|擀|包|捏|摆盘/u;

// 社交平台话术 / 广告 / 寒暄 / 口头禅。仅在同一子句没有烹饪动作时才删除。
const SOCIAL_NOISE_RE = /点赞|收藏|关注|转发|三连|一键|投币|评论区|评论下|主页|置顶|下方链接|上链接|购物车|橱窗|下单|优惠|团购|抽奖|涨粉|新粉|老铁|家人们|姐妹们|宝子们|兄弟们|朋友们|谢谢观看|感谢观看|下期见|下期|拜拜|不迷路|求个|求关注|打卡|直播间|视频号|小红书|抖音|B站|我的账号|欢迎大家|大家好|哈喽|hello/iu;

// 背景故事 / 引入语 / 效果吹捧。同样只在没有烹饪动作时才删除。
const CHATTER_RE = /今天(?:给大家|教大家|分享|做)?|教大家|分享(?:一道|一个)?|做法来了|安排上|非常有营养|特别有营养|超级好吃|好吃到|太香了|绝了|真的绝|巨好吃|我最爱|我最喜欢|小时候|我妈|我婆婆|上次|之前|以前|曾经|不用我多说|废话不多说|直接开始|话不多说/u;

// 纯提醒 / 免责，不是操作。
const REMINDER_RE = /请确认|请人工确认|仅供参考|因人而异|按个人口味|视情况而定/u;

// 配料表标签。
const INGREDIENT_LABEL_RE = /^(?:食材|用料|配料|主料|辅料|调料|调味料|材料)(?:清单|准备)?[：:、]?/u;

// 空泛步骤：既没有具体对象也没有具体动作。
const VAGUE_STEP_RE = /^(?:准备(?:好)?(?:所有)?(?:食材|材料|配料)(?:备用)?|开始(?:烹饪|制作|做菜)|进行烹饪|按步骤操作|完成制作|大功告成)[。！!，,]*$/u;

// 需要在去重时优先保留的「信息量」标记：时间、温度、火候、状态判断、用量。
const DETAIL_TOKEN_RE = /\d|分钟|小时|秒|度|℃|大火|中火|小火|中小火|大火快炒|微火|文火|变色|断生|微黄|金黄|浓稠|收干|上色|冒泡|沸腾|软烂|七分熟|八分熟/u;

// 阶段分类。顺序即优先级（先命中先算）。
const STAGE_PATTERNS = [
  { stage: 'finish', rank: 4, re: /出锅|装盘|盛出|盛入|摆盘|即可(?:食用|享用)?|完成/u },
  { stage: 'marinade', rank: 1, re: /腌制|腌|抓匀|拌匀|上浆|裹粉|码味/u },
  { stage: 'cook', rank: 2, re: /热锅|起锅|下锅|倒油|烧油|烧热|下入|翻炒|爆香|煸|滑散|滑炒|炒|煎|炸|烤|蒸|煮|焖|炖|烧|收汁|勾芡|锅中|锅里/u },
  { stage: 'prep', rank: 0, re: /清洗|洗净|沥干|擦干|去皮|去籽|去骨|去筋|改刀|切块|切片|切丝|切段|切末|切碎|拍碎|剁|泡发|浸泡|解冻|备用/u },
  { stage: 'season', rank: 3, re: /加入|放入|倒入|淋入|撒|淋|调味/u }
];

// 「一定不在锅上」的备料特征，用于保守前移判断。
const PURE_PREP_RE = /^(?!.*(?:锅|油温|开火|大火|中火|小火|翻炒|爆香|下锅))(?=.*(?:清洗|洗净|沥干|擦干|去皮|去籽|去骨|去筋|改刀|切块|切片|切丝|切段|切末|切碎|拍碎|剁|泡发|浸泡|解冻)).*$/u;

// 行首序号 / 时间码 / 字幕残片。
const LEADING_MARKER_RE = /^[\s\-–—•·*>》]*(?:第[一二三四五六七八九十百零\d]+步[:：]?\s*|步骤[一二三四五六七八九十百零\d]+[:：]?\s*|[（(]\s*\d+\s*[)）]\s*|\d+\s*[.、．。)）:：]\s*|[一二三四五六七八九十]+\s*[、.．。)）:：]\s*)/u;
const TIMECODE_RE = /(?:^|[\s（(\[【])\d{1,2}[:：]\d{2}(?:[:：]\d{2})?(?:[)\]】）])?/gu;
// 口语语气词。只删「独立成分」的语气词，不碰「哈密瓜」「呀米」这类词内字符：
// 要求前面是句读或句首，或后面是句读或句末。
const FILLER_RE = /(?:^|(?<=[，,。；;、：:]))\s*(?:那么|然后呢|就是说|其实呢|反正|对吧|你知道的|我跟你说|我们来看看|我们来|我来|咱们|大家)\s*/gu;
const TRAILING_PARTICLE_RE = /(?:[哈呵嘿嘻]{2,}|[啊呀哦噢喔嘛呢啦咯嘞哟耶])+(?=[，,。！!？?；;]|$)/gu;
// 只剥口语主语和纯填充助动词。「先」「再」「把」是菜谱里有意义的顺序/处置标记，
// 必须留下，否则步骤之间的先后关系会被削掉。
const SUBJECT_PREFIX_RE = /^(?:我们|我|你|您|大家)(?:就|来|要|可以|需要)?\s*/u;

// 子句切分：保留分隔符信息，便于重新拼接。
const CLAUSE_SPLIT_RE = /(?<=[，,。！!？?；;])/u;

// 阶段推进词，用于拆分长步骤。
const STAGE_BREAK_RE = /(?:然后|接着|之后|随后|最后|接下来|紧接着|等到|直到|再来)/u;

const MAX_STEP_LENGTH = 90;
const SPLIT_LENGTH_THRESHOLD = 34;
const MERGE_LENGTH_THRESHOLD = 11;
const MERGED_MAX_LENGTH = 52;
const NEAR_DUPLICATE_THRESHOLD = 0.72;

// ---------------------------------------------------------------------------
// 基础工具
// ---------------------------------------------------------------------------

function toText(value) {
  return String(value == null ? '' : value).trim();
}

function stripLeadingMarkers(text) {
  let out = toText(text);
  let previous = '';
  // OCR 常见「1. 第二步：…」这类叠加前缀，循环剥到不动为止（最多 3 轮）。
  for (let i = 0; i < 3 && out !== previous; i += 1) {
    previous = out;
    out = out.replace(LEADING_MARKER_RE, '').trim();
  }
  return out;
}

function normalizeStepText(text) {
  let out = toText(text)
    .replace(/\r/gu, '')
    .replace(/[​﻿]/gu, '')
    .replace(TIMECODE_RE, ' ')
    .replace(/[“”"'『』「」]/gu, '')
    .replace(/\s+/gu, ' ');
  out = stripLeadingMarkers(out);
  out = out.replace(FILLER_RE, '');
  out = out.replace(TRAILING_PARTICLE_RE, '');
  out = out.replace(SUBJECT_PREFIX_RE, '');
  out = out
    .replace(/\s*([，,。！!？?；;：:])\s*/gu, '$1')
    .replace(/([，,。；;])\1+/gu, '$1')
    .replace(/^[，,。！!？?；;：:、\s]+/u, '')
    .replace(/[，,、\s]+$/u, '')
    .trim();
  return out;
}

function hasCookingAction(text) {
  return COOKING_ACTION_RE.test(toText(text));
}

function isNoiseClause(clause) {
  const text = toText(clause).replace(/[。，,！!？?；;：:]/gu, '');
  if (!text) return true;
  // 有真实烹饪动作的子句永远保留 —— 宁可留噪声，也不误删做法。
  if (hasCookingAction(text)) return false;
  if (SOCIAL_NOISE_RE.test(text)) return true;
  if (CHATTER_RE.test(text)) return true;
  if (REMINDER_RE.test(text)) return true;
  return false;
}

function stripNoiseClauses(text) {
  const clauses = toText(text).split(CLAUSE_SPLIT_RE).filter(Boolean);
  if (clauses.length <= 1) {
    return isNoiseClause(text) ? '' : normalizeStepText(text);
  }
  const kept = clauses.filter(clause => !isNoiseClause(clause));
  if (!kept.length) return '';
  return normalizeStepText(kept.join(''));
}

/** 整条只是食材罗列（例如「食材：猪肉、青椒、蒜」或「猪肉 青椒 蒜」）。 */
function isIngredientListOnly(text) {
  const raw = toText(text);
  if (!raw) return false;
  if (hasCookingAction(raw)) return false;
  if (INGREDIENT_LABEL_RE.test(raw)) return true;
  const parts = raw.split(/[、，,\/\s]+/u).map(part => part.trim()).filter(Boolean);
  // 3 个以上的短名词并列且没有任何动作 → 视为配料表残留。
  return parts.length >= 3 && parts.every(part => part.length <= 6);
}

function isVagueStep(text) {
  return VAGUE_STEP_RE.test(toText(text));
}

function classifyStage(text) {
  const value = toText(text);
  for (const entry of STAGE_PATTERNS) {
    if (entry.re.test(value)) return entry;
  }
  return { stage: 'other', rank: 2.5, re: null };
}

function finishSentence(text) {
  const value = toText(text);
  if (!value) return '';
  return /[。.!！?？]$/u.test(value) ? value : `${value}。`;
}

// ---------------------------------------------------------------------------
// 拆分
// ---------------------------------------------------------------------------

function countMainActions(text) {
  const value = toText(text);
  let count = 0;
  const seen = new Set();
  const globalAction = new RegExp(COOKING_ACTION_RE.source, 'gu');
  let match;
  while ((match = globalAction.exec(value)) !== null) {
    if (seen.has(match.index)) continue;
    seen.add(match.index);
    count += 1;
  }
  return count;
}

/**
 * 一条文本里存在多个明显独立的主要操作时拆开。
 * 只在「够长 + 有阶段推进词或句号边界 + 两边都有动作」时才拆，避免把
 * 「炒至变色后盛出」这类紧密连续的动作切碎。
 */
function splitCompoundStep(text) {
  const value = toText(text);
  if (!value) return [];

  // 1) 句号边界优先：本来就是多句。
  const sentences = value.split(/(?<=[。！!？?])/u).map(part => part.trim()).filter(Boolean);
  if (sentences.length > 1) {
    return sentences.flatMap(splitCompoundStep);
  }

  if (value.length < SPLIT_LENGTH_THRESHOLD) return [value];
  if (countMainActions(value) < 2) return [value];

  // 2) 阶段推进词边界。
  const breakSplit = value.split(new RegExp(`(?=${STAGE_BREAK_RE.source})`, 'u'))
    .map(part => normalizeStepText(part.replace(new RegExp(`^${STAGE_BREAK_RE.source}`, 'u'), '')))
    .filter(Boolean);
  if (breakSplit.length > 1 && breakSplit.every(part => hasCookingAction(part))) {
    return breakSplit;
  }

  // 3) 仍然超长时，按逗号在「动作均衡」的位置切一刀。
  if (value.length > MAX_STEP_LENGTH) {
    const clauses = value.split(/(?<=[，,；;])/u).map(part => part.trim()).filter(Boolean);
    if (clauses.length > 1) {
      const chunks = [];
      let current = '';
      for (const clause of clauses) {
        if (current && (current.length + clause.length) > MAX_STEP_LENGTH && hasCookingAction(current)) {
          chunks.push(normalizeStepText(current));
          current = clause;
        } else {
          current += clause;
        }
      }
      if (current) chunks.push(normalizeStepText(current));
      const usable = chunks.filter(Boolean);
      if (usable.length > 1) return usable;
    }
  }

  return [value];
}

// ---------------------------------------------------------------------------
// 近似去重（OCR × ASR）
// ---------------------------------------------------------------------------

function dedupeKey(text) {
  return toText(text).replace(/[\s。，,！!？?；;：:、（）()【】\[\]]/gu, '');
}

function bigrams(text) {
  const set = new Set();
  for (let i = 0; i < text.length - 1; i += 1) set.add(text.slice(i, i + 2));
  if (!set.size && text) set.add(text);
  return set;
}

function similarity(a, b) {
  if (!a || !b) return 0;
  if (a === b) return 1;
  const setA = bigrams(a);
  const setB = bigrams(b);
  let intersection = 0;
  for (const gram of setA) {
    if (setB.has(gram)) intersection += 1;
  }
  const union = setA.size + setB.size - intersection;
  return union ? intersection / union : 0;
}

/**
 * OCR 与 ASR 常把同一动作说成措辞不同的两句（「猪肉切成肉丝」/「猪肉切丝」），
 * bigram 相似度抓不到。这里退一步用字符集合包含关系：短句的每个字都出现在长句里
 * 时，短句不携带任何长句没有的信息，属于重复识别。
 */
function isCharacterSubset(shortKey, longKey) {
  if (shortKey.length < 3 || shortKey.length >= longKey.length) return false;
  for (const char of shortKey) {
    if (!longKey.includes(char)) return false;
  }
  return true;
}

/**
 * 极短且不含时间/温度/火候/状态判断的步骤（「腌一下」「盛出」），若它的烹饪动作
 * 已经被另一条更完整的步骤覆盖，就是重复识别的残片。
 */
function listActionVerbs(text) {
  const globalAction = new RegExp(COOKING_ACTION_RE.source, 'gu');
  return [...new Set(toText(text).match(globalAction) || [])];
}

function isRedundantShortStep(step, otherSteps) {
  const bare = dedupeKey(step);
  if (!bare || bare.length > 5) return false;
  if (countDetailTokens(step) > 0) return false;
  const verbs = listActionVerbs(step);
  if (!verbs.length) return false;
  return otherSteps.some(other => {
    if (other === step) return false;
    const otherKey = dedupeKey(other);
    if (otherKey.length <= bare.length) return false;
    return verbs.every(verb => otherKey.includes(verb));
  });
}

function countDetailTokens(text) {
  const globalDetail = new RegExp(DETAIL_TOKEN_RE.source, 'gu');
  return (toText(text).match(globalDetail) || []).length;
}

/**
 * 保留信息更全的一条：先比「细节 token」（时间/温度/火候/状态判断/用量），
 * 再比长度。这样 OCR 的「小火煎3分钟」不会被 ASR 的「煎一下」顶掉。
 */
function pickRicherStep(a, b) {
  const detailA = countDetailTokens(a);
  const detailB = countDetailTokens(b);
  if (detailA !== detailB) return detailA > detailB ? a : b;
  return dedupeKey(a).length >= dedupeKey(b).length ? a : b;
}

/**
 * OCR 常把 ASR 里分成两步说的内容压成一句（「倒油烧热下入肉丝」对应
 * 「锅中倒油烧热」+「下入肉丝炒至变色盛出」）。逐条两两比较抓不到这种跨步骤
 * 的重复，这里看候选句的 bigram 是否几乎全部已被保留内容覆盖，且没有带来任何
 * 新的时间/温度/火候/状态信息。
 *
 * 阈值 0.85 而不是 0.9：候选句跨越两条已保留步骤时，接缝处的那个 bigram
 * （「…烧热」+「下入…」→「热下」）必然缺失，7-gram 的句子因此最高只能到
 * 6/7≈0.857。仍然要求「不带来任何新信息」，所以误删风险很低。
 */
const CROSS_STEP_COVERAGE_THRESHOLD = 0.85;

function isCoveredByKeptSteps(step, keptKeys, keptDetailTokens) {
  const key = dedupeKey(step);
  if (key.length < 4) return false;

  const globalDetail = new RegExp(DETAIL_TOKEN_RE.source, 'gu');
  const ownDetails = new Set(step.match(globalDetail) || []);
  for (const detail of ownDetails) {
    if (!keptDetailTokens.has(detail)) return false;
  }

  const grams = bigrams(key);
  if (!grams.size) return false;
  let covered = 0;
  for (const gram of grams) {
    if (keptKeys.has(gram)) covered += 1;
  }
  return (covered / grams.size) >= CROSS_STEP_COVERAGE_THRESHOLD;
}

function dedupeNearDuplicates(steps) {
  const kept = [];
  let removedCount = 0;

  for (const step of steps) {
    const key = dedupeKey(step);
    if (!key) continue;
    let mergedIndex = -1;
    for (let i = 0; i < kept.length; i += 1) {
      const existingKey = dedupeKey(kept[i]);
      const contained = (key.length >= 6 && existingKey.includes(key))
        || (existingKey.length >= 6 && key.includes(existingKey))
        || isCharacterSubset(key, existingKey)
        || isCharacterSubset(existingKey, key);
      if (contained || similarity(key, existingKey) >= NEAR_DUPLICATE_THRESHOLD) {
        mergedIndex = i;
        break;
      }
    }
    if (mergedIndex === -1) {
      kept.push(step);
      continue;
    }
    kept[mergedIndex] = pickRicherStep(kept[mergedIndex], step);
    removedCount += 1;
  }

  // 第二轮：清理动作已被更完整步骤覆盖的极短残片。
  let survivors = kept.filter(step => {
    if (!isRedundantShortStep(step, kept)) return true;
    removedCount += 1;
    return false;
  });
  if (!survivors.length) survivors = kept;

  // 第三轮：清理内容已被前面若干步骤合并覆盖的跨步骤重复（典型是 OCR 把 ASR
  // 分成两步说的内容压成一句）。只向前看，保证先出现的表述优先保留。
  const finalSteps = [];
  const keptGrams = new Set();
  const keptDetails = new Set();
  const globalDetail = new RegExp(DETAIL_TOKEN_RE.source, 'gu');
  for (const step of survivors) {
    if (finalSteps.length && isCoveredByKeptSteps(step, keptGrams, keptDetails)) {
      removedCount += 1;
      continue;
    }
    finalSteps.push(step);
    for (const gram of bigrams(dedupeKey(step))) keptGrams.add(gram);
    for (const detail of step.match(globalDetail) || []) keptDetails.add(detail);
  }

  return { steps: finalSteps.length ? finalSteps : survivors, removedCount };
}

// ---------------------------------------------------------------------------
// 合并
// ---------------------------------------------------------------------------

function mergeFragmentedSteps(steps) {
  const merged = [];
  let mergedCount = 0;

  for (const step of steps) {
    const previous = merged[merged.length - 1];
    if (
      previous
      && previous.length <= MERGE_LENGTH_THRESHOLD
      && step.length <= MERGE_LENGTH_THRESHOLD
      && (previous.length + step.length) <= MERGED_MAX_LENGTH
      && classifyStage(previous).stage === classifyStage(step).stage
    ) {
      merged[merged.length - 1] = `${previous.replace(/[，,。；;]$/u, '')}，${step}`;
      mergedCount += 1;
      continue;
    }
    merged.push(step);
  }

  return { steps: merged, mergedCount };
}

// ---------------------------------------------------------------------------
// 保守重排
// ---------------------------------------------------------------------------

/**
 * 只做两类明确无歧义的移动：
 *  - 纯备料步骤（切/洗/去皮…且完全不涉及锅、火、油）若排在第一个下锅步骤之后，
 *    前移到第一个下锅步骤之前，相对顺序保持不变；
 *  - 纯收尾步骤（出锅/装盘且没有其它动作）后移到末尾。
 * 其余步骤一律保持来源顺序，不按「常识」重排。
 */
function reorderSteps(steps) {
  if (steps.length < 2) return { steps, movedCount: 0 };

  const firstCookIndex = steps.findIndex(step => classifyStage(step).stage === 'cook');
  let movedCount = 0;
  let working = steps.slice();

  if (firstCookIndex > -1) {
    const prepAfterCook = [];
    const rest = [];
    working.forEach((step, index) => {
      if (index > firstCookIndex && PURE_PREP_RE.test(step)) {
        prepAfterCook.push(step);
      } else {
        rest.push(step);
      }
    });
    if (prepAfterCook.length) {
      movedCount += prepAfterCook.length;
      const insertAt = rest.findIndex(step => classifyStage(step).stage === 'cook');
      const target = insertAt === -1 ? rest.length : insertAt;
      working = [...rest.slice(0, target), ...prepAfterCook, ...rest.slice(target)];
    }
  }

  const finishOnly = [];
  const others = [];
  working.forEach((step, index) => {
    const isLast = index === working.length - 1;
    if (!isLast && classifyStage(step).stage === 'finish' && !/加入|放入|倒入|翻炒|炒|煮|焖|炖|煎/u.test(step)) {
      finishOnly.push(step);
    } else {
      others.push(step);
    }
  });
  if (finishOnly.length) {
    movedCount += finishOnly.length;
    working = [...others, ...finishOnly];
  }

  return { steps: working, movedCount };
}

// ---------------------------------------------------------------------------
// 主入口
// ---------------------------------------------------------------------------

/**
 * @param {unknown} rawSteps 原始 method（数组或字符串）
 * @param {{ maxSteps?: number }} [options]
 * @returns {{ steps: string[], diagnostics: object }}
 */
function cleanRecipeSteps(rawSteps, options = {}) {
  const maxSteps = Number(options.maxSteps) || 12;
  const diagnostics = {
    stepCleanupInputCount: 0,
    stepCleanupOutputCount: 0,
    stepCleanupNoiseRemovedCount: 0,
    stepCleanupIngredientListRemovedCount: 0,
    stepCleanupVagueRemovedCount: 0,
    stepCleanupSplitCount: 0,
    stepCleanupMergedCount: 0,
    stepCleanupDuplicateRemovedCount: 0,
    stepCleanupReorderedCount: 0,
    stepCleanupFellBack: false
  };

  let input = [];
  if (Array.isArray(rawSteps)) input = rawSteps;
  else if (typeof rawSteps === 'string') input = rawSteps.split(/\n+/u);
  else return { steps: [], diagnostics };

  input = input.map(toText).filter(Boolean);
  diagnostics.stepCleanupInputCount = input.length;
  if (!input.length) return { steps: [], diagnostics };

  // 1) 归一化 + 子句级降噪。
  const denoised = [];
  for (const raw of input) {
    const normalized = normalizeStepText(raw);
    if (!normalized) {
      diagnostics.stepCleanupNoiseRemovedCount += 1;
      continue;
    }
    const cleaned = stripNoiseClauses(normalized);
    if (!cleaned) {
      diagnostics.stepCleanupNoiseRemovedCount += 1;
      continue;
    }
    denoised.push(cleaned);
  }

  // 2) 拆分。
  const split = [];
  for (const step of denoised) {
    const parts = splitCompoundStep(step).map(normalizeStepText).filter(Boolean);
    if (parts.length > 1) diagnostics.stepCleanupSplitCount += parts.length - 1;
    split.push(...parts);
  }

  // 3) 剔除配料表 / 空泛步骤 / 过短碎片。
  const filtered = [];
  for (const step of split) {
    if (isIngredientListOnly(step)) {
      diagnostics.stepCleanupIngredientListRemovedCount += 1;
      continue;
    }
    if (isVagueStep(step)) {
      diagnostics.stepCleanupVagueRemovedCount += 1;
      continue;
    }
    const bare = step.replace(/[。，,！!？?；;：:]/gu, '');
    if (bare.length < 2) {
      diagnostics.stepCleanupNoiseRemovedCount += 1;
      continue;
    }
    filtered.push(step);
  }

  // 4) 近似去重。
  const deduped = dedupeNearDuplicates(filtered);
  diagnostics.stepCleanupDuplicateRemovedCount = deduped.removedCount;

  // 5) 合并零碎片段。
  const mergedResult = mergeFragmentedSteps(deduped.steps);
  diagnostics.stepCleanupMergedCount = mergedResult.mergedCount;

  // 6) 保守重排。
  const reordered = reorderSteps(mergedResult.steps);
  diagnostics.stepCleanupReorderedCount = reordered.movedCount;

  let finalSteps = reordered.steps.map(finishSentence).filter(Boolean).slice(0, maxSteps);

  // 7) 安全网：清洗把步骤清空时，退回到「只归一化」的结果，绝不返回空做法。
  if (!finalSteps.length) {
    const fallback = input.map(normalizeStepText).filter(Boolean).map(finishSentence).slice(0, maxSteps);
    if (fallback.length) {
      diagnostics.stepCleanupFellBack = true;
      finalSteps = fallback;
    }
  }

  diagnostics.stepCleanupOutputCount = finalSteps.length;
  return { steps: finalSteps, diagnostics };
}

module.exports = {
  cleanRecipeSteps,
  // 导出内部判定供测试与 fallback 复用（不构成对外契约的一部分）。
  classifyStage,
  dedupeNearDuplicates,
  hasCookingAction,
  isIngredientListOnly,
  isNoiseClause,
  isVagueStep,
  mergeFragmentedSteps,
  normalizeStepText,
  reorderSteps,
  splitCompoundStep,
  stripNoiseClauses
};
