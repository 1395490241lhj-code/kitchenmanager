/*
 * src/utils/ai-disliked-recipes.js —— 「AI 推荐不合理/不喜欢」轻量反馈的本地记录。
 *
 * 用户在今日 AI 推荐卡片 / AI 草稿详情页点「不喜欢」「不合理」后，把菜名记到这里；
 * 之后 callCloudAI 的 prompt、validateRecommendationResult、processAiData 都会读取
 * 这份名单，避免重复推荐同名或（AI 层面）相似的菜。
 *
 * 只存菜名 + 原因 + 时间戳，最多 100 条，超出删最旧的。
 */
import { S } from '../storage.js?v=236';

const MAX_DISLIKED = 100;

function normalizeName(name) {
  return String(name || '').trim().replace(/\s+/g, ' ');
}

function loadDislikedMap() {
  const map = S.load(S.keys.ai_disliked_recipes, {});
  return (map && typeof map === 'object' && !Array.isArray(map)) ? map : {};
}

/** 返回所有已标记「不喜欢/不合理」的菜名（数组）。 */
export function getDislikedAiRecipeNames() {
  return Object.keys(loadDislikedMap());
}

/**
 * 标记一个菜名为「不喜欢/不合理」。同名再次标记会覆盖原因并更新时间戳。
 * @param {string} name
 * @param {string} [reason]
 * @returns {boolean} 是否成功保存（name 为空时返回 false，不保存）
 */
export function markAiRecipeDisliked(name, reason = '用户标记不喜欢') {
  const key = normalizeName(name);
  if (!key) return false;
  const map = loadDislikedMap();
  map[key] = { name: key, reason: String(reason || '用户标记不喜欢').trim(), ts: Date.now() };

  const entries = Object.entries(map).sort((a, b) => a[1].ts - b[1].ts);
  while (entries.length > MAX_DISLIKED) {
    const [oldestKey] = entries.shift();
    delete map[oldestKey];
  }

  S.save(S.keys.ai_disliked_recipes, map);
  return true;
}

/** 判断某个菜名是否被标记过「不喜欢/不合理」。 */
export function isAiRecipeDisliked(name) {
  const key = normalizeName(name);
  if (!key) return false;
  return Boolean(loadDislikedMap()[key]);
}
