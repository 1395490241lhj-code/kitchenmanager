function safeParseJsonText(text) {
  try { return JSON.parse(String(text || '').trim()); } catch (_) { return null; }
}

function extractBalancedJsonObject(text, startIndex) {
  const source = String(text || '');
  const firstBrace = source.indexOf('{', startIndex);
  if (firstBrace < 0) return '';
  let depth = 0;
  let inString = false;
  let quote = '';
  let escaped = false;
  for (let i = firstBrace; i < source.length; i += 1) {
    const ch = source[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch === '\\') {
        escaped = true;
      } else if (ch === quote) {
        inString = false;
        quote = '';
      }
      continue;
    }
    if (ch === '"' || ch === "'") {
      inString = true;
      quote = ch;
      continue;
    }
    if (ch === '{') depth += 1;
    if (ch === '}') {
      depth -= 1;
      if (depth === 0) return source.slice(firstBrace, i + 1);
    }
  }
  return '';
}

function parseJsonParseCall(text) {
  const source = String(text || '').trim();
  const match = source.match(/^JSON\.parse\(\s*(["'])((?:\\.|(?!\1)[\s\S])*)\1\s*\)/);
  if (!match) return null;
  try {
    const decodedString = JSON.parse(`${match[1]}${match[2]}${match[1]}`);
    return safeParseJsonText(decodedString);
  } catch (_) {
    return null;
  }
}

function safeParseModelJson(raw) {
  if (raw && typeof raw === 'object') return raw;
  const s = String(raw || '')
    .replace(/^\uFEFF/, '')
    .replace(/```(?:json|JSON)?/g, '')
    .replace(/```/g, '')
    .trim();
  const a = s.indexOf('{'), b = s.lastIndexOf('}');
  if (a < 0 || b <= a) return null;
  try { return JSON.parse(s.slice(a, b + 1)); } catch (_) { return null; }
}

module.exports = {
  safeParseJsonText,
  extractBalancedJsonObject,
  parseJsonParseCall,
  safeParseModelJson
};
