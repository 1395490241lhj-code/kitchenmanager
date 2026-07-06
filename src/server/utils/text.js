/*
 * src/server/utils/text.js —— 跨层文本小工具：来源分节拼接、截断、去重列表。
 * 从 server.js 拆出，正文逐字搬移；依赖按符号自动接线。
 */


function appendSourceSection(sections, title, value) {
  const text = String(value || '').trim();
  if (text) sections.push(`【${title}】\n${text}`);
}

function limitSourceSectionText(value, maxChars) {
  const text = String(value || '').trim();
  const limit = Number(maxChars || 0);
  if (!text || !Number.isFinite(limit) || limit <= 0) return text;
  return text.length > limit ? text.slice(0, limit) : text;
}

function uniqueTextList(list, limit = 12) {
  const seen = new Set();
  return list.map(item => String(item || '').trim())
    .filter(Boolean)
    .filter(item => !seen.has(item) && seen.add(item))
    .slice(0, limit);
}

module.exports = {
  appendSourceSection,
  limitSourceSectionText,
  uniqueTextList
};
