/* ──────────────────────────────────────────────────────────────────────────
 * 首页推荐会话（home recommendation session）
 *
 * createWeatherPanel 的 recsState / localShownIds 只是面板闭包状态，任何完整
 * renderHome（路由离开首页再回来、浏览器刷新、写库后 onRoute 重建）都会把它们
 * 清空，用户会重新看到已经换过的菜。这里把「当前展示到哪一张、已经展示过哪些、
 * 是否已耗尽、是否本人明确生成过 creative」抽成一小份可序列化的会话。
 *
 * 本模块是纯函数：不读 localStorage、不碰 DOM，方便直接对序列化 / 恢复 / 失效
 * 规则做真实行为测试。存取由 home-view 负责，签名一律复用 recommendations.js
 * 的 buildRecommendationSignature，不在这里另起一套签名算法。
 * ────────────────────────────────────────────────────────────────────────── */

export const HOME_REC_SESSION_VERSION = 1;

// local=本地正式菜谱轮换中；local-exhausted=本地候选已换完；creative=用户明确
// 点过「AI 创作新菜」并拿到结果。local-empty 是「本来就没有候选」的即时状态，
// 不需要持久化（下次进来重新算一次即可）。
export const HOME_REC_SESSION_MODES = ['local', 'local-exhausted', 'creative'];

// 与 home-view 的卡片 key 口径保持一致：优先正式菜谱 id，其次本地兜底卡的 id/名字。
export function getRecommendationCardKey(card) {
  return String(card?.recipeId || card?.id || card?.name || '').trim();
}

function normalizeShownIds(value) {
  const out = [];
  const seen = new Set();
  for (const raw of (Array.isArray(value) ? value : [])) {
    const key = String(raw ?? '').trim();
    if (!key || seen.has(key)) continue;
    seen.add(key);
    out.push(key);
  }
  return out;
}

// 构造一份可直接 JSON 序列化的会话；只保存稳定 key，不序列化整个候选池。
export function createHomeRecSession({
  date = '',
  signature = '',
  mode = 'local',
  currentCardKey = '',
  shownIds = [],
  explicitCreativeRequested = false
} = {}) {
  return {
    version: HOME_REC_SESSION_VERSION,
    date: String(date || ''),
    signature: String(signature || ''),
    mode: HOME_REC_SESSION_MODES.includes(mode) ? mode : 'local',
    currentCardKey: String(currentCardKey || ''),
    shownIds: normalizeShownIds(shownIds),
    explicitCreativeRequested: explicitCreativeRequested === true
  };
}

// 宽容解析：任何形状不对、版本不认识的输入都返回 null，绝不抛错。
export function parseHomeRecSession(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  if (raw.version !== HOME_REC_SESSION_VERSION) return null;
  if (!HOME_REC_SESSION_MODES.includes(raw.mode)) return null;
  const date = String(raw.date || '');
  const signature = String(raw.signature || '');
  if (!date || !signature) return null;
  return {
    version: HOME_REC_SESSION_VERSION,
    date,
    signature,
    mode: raw.mode,
    currentCardKey: String(raw.currentCardKey || ''),
    shownIds: normalizeShownIds(raw.shownIds),
    explicitCreativeRequested: raw.explicitCreativeRequested === true
  };
}

/**
 * 尝试把一份已保存的会话恢复成面板状态。
 *
 * 失效即返回 { ok:false, reason }，调用方据此安全重置到最新本地池第一项：
 *   unsupported          会话损坏 / 版本不支持 / mode 不认识
 *   date-changed         跨天
 *   signature-changed    库存 / 计划 / 收藏 / 用户菜谱 / 常备品等导致签名变化
 *   no-candidates        当前没有任何合理本地候选
 *   card-missing         上次展示的卡片已不在候选池
 *   creative-unavailable creative 会话缺少明确标记，或 ai_recs 过滤后没有可用卡片
 *
 * creative 的恢复条件刻意收紧：必须 explicitCreativeRequested === true 且调用方
 * 已经用 processAiData 过滤出可用 creative 卡片。只有旧 ai_recs、没有有效会话
 * 标记时，这里一定返回失效，首屏因此仍走本地池。
 */
export function restoreHomeRecSession(raw, {
  date = '',
  signature = '',
  cards = [],
  creativeCards = []
} = {}) {
  const session = parseHomeRecSession(raw);
  if (!session) return { ok: false, reason: 'unsupported' };
  if (session.date !== String(date || '')) return { ok: false, reason: 'date-changed' };
  if (session.signature !== String(signature || '')) return { ok: false, reason: 'signature-changed' };

  if (session.mode === 'creative') {
    if (!session.explicitCreativeRequested) return { ok: false, reason: 'creative-unavailable' };
    const list = Array.isArray(creativeCards) ? creativeCards : [];
    if (!list.length) return { ok: false, reason: 'creative-unavailable' };
    return {
      ok: true,
      state: {
        mode: 'creative',
        idx: 0,
        shownIds: session.shownIds,
        explicitCreativeRequested: true
      }
    };
  }

  const list = Array.isArray(cards) ? cards : [];
  if (!list.length) return { ok: false, reason: 'no-candidates' };
  const idx = list.findIndex(card => getRecommendationCardKey(card) === session.currentCardKey);
  if (idx < 0) return { ok: false, reason: 'card-missing' };

  return {
    ok: true,
    state: {
      mode: session.mode,
      idx,
      // 上次展示过的 key 一律保留（含当前这张），返回首页后继续换批不会重复。
      shownIds: normalizeShownIds([...session.shownIds, session.currentCardKey]),
      explicitCreativeRequested: session.explicitCreativeRequested
    }
  };
}
