import { loadOverlay, saveOverlay } from '../backup.js?v=222';
import { genId } from '../shopping.js?v=222';
import { importRecipeFromSource, getRecipeImportAiFailureCopy } from '../ai.js?v=226';
import { setActionStatus, setInlineStatus, showToast } from './status.js?v=223';

const AI_DRAFT_SESSION_KEY = 'kitchen-ai-draft-pending';

export function extractFirstHttpUrl(text) {
  const raw = String(text || '');
  const match = raw.match(/https?:\/\/[^\s，。、,.;；]+/i);
  if (!match) return { url: '', remainingText: raw.trim() };
  const originalUrl = match[0];
  const url = originalUrl.replace(/[，。、,.;；]+$/, '');
  const remainingText = raw.replace(originalUrl, ' ').replace(/\s+/g, ' ').trim();
  return { url, remainingText };
}

function openEditorWithAiDraft(draft) {
  const tags = Array.from(new Set(['AI草稿', 'AI导入', ...(Array.isArray(draft.tags) ? draft.tags : [])]));
  const seasonings = (Array.isArray(draft.seasonings) ? draft.seasonings : [])
    .map(i => ({ item: i.item || '', qty: i.qty || '', unit: i.unit || '' }))
    .filter(i => i.item);
  const pending = {
    name: draft.name || 'AI 导入菜谱草稿',
    tags,
    method: draft.method || '',
    seasonings,
    ingredients: (draft.ingredients || []).map(i => ({ item: i.item || '', qty: i.qty ?? null, unit: i.unit ?? null })),
    warnings: Array.isArray(draft.warnings) ? draft.warnings.filter(Boolean) : [],
    diagnostics: draft.diagnostics && typeof draft.diagnostics === 'object' ? draft.diagnostics : null,
    mediaDiagnostics: draft.mediaDiagnostics && typeof draft.mediaDiagnostics === 'object' ? draft.mediaDiagnostics : null,
    debugEvidenceSummary: draft.debugEvidenceSummary && typeof draft.debugEvidenceSummary === 'object' ? draft.debugEvidenceSummary : null,
    fallbackUsed: Boolean(draft.fallbackUsed),
    fallbackReason: draft.fallbackReason || '',
    importTextReady: Boolean(draft.importTextReady),
    needsReview: Boolean(draft.needsReview),
    isAiDraft: true,
  };
  try {
    sessionStorage.setItem(AI_DRAFT_SESSION_KEY, JSON.stringify(pending));
  } catch (e) {
    console.warn('[AI导入] sessionStorage 写入失败，回退为直接写 overlay', e);
    const id = genId();
    const ov = loadOverlay();
    ov.recipes = ov.recipes || {};
    ov.recipe_ingredients = ov.recipe_ingredients || {};
    ov.recipes[id] = {
      name: pending.name,
      tags: pending.tags,
      method: pending.method,
      seasonings: pending.seasonings,
      warnings: pending.warnings,
      reviewNotes: pending.warnings.join('\n'),
      needsReview: pending.needsReview,
      isAiDraft: true
    };
    ov.recipe_ingredients[id] = pending.ingredients;
    saveOverlay(ov);
    window.invalidatePackCache?.();
    location.hash = `#recipe-edit:${id}`;
    return;
  }
  location.hash = '#recipe-edit:ai-import-draft';
}

export function openRecipeImportModal() {
  const overlay = document.createElement('div');
  overlay.className = 'km-modal-overlay open ai-import-overlay';
  overlay.innerHTML = `
    <div class="km-modal-content ai-import-modal" role="dialog" aria-modal="true" aria-labelledby="aiImportTitle">
      <div class="km-modal-header ai-import-header">
        <span class="km-modal-title ai-import-title" id="aiImportTitle">导入菜谱</span>
        <button type="button" class="km-modal-close" id="aiImportClose" aria-label="关闭">×</button>
      </div>
      <div class="km-modal-body ai-import-body">
        <p class="km-modal-subtitle">粘贴小红书链接、网页菜谱链接或菜谱文字，系统会尽量整理成可编辑草稿。</p>
        <label class="ai-import-field">
          <span>粘贴内容</span>
          <textarea id="aiImportInput" rows="5" placeholder="粘贴小红书链接、网页链接或菜谱文字"></textarea>
        </label>
        <div id="aiImportStatus" class="inline-status" hidden></div>
      </div>
      <div class="km-modal-actions ai-import-actions">
        <button type="button" class="btn km-action-weak ai-import-cancel" id="aiImportCancel">取消</button>
        <button type="button" class="btn ok km-action-primary ai-import-go" id="aiImportGo">开始导入</button>
      </div>
    </div>
  `;
  document.body.appendChild(overlay);
  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    overlay.classList.add('closing');
    window.setTimeout(() => overlay.remove(), 160);
  };
  overlay.onclick = (e) => { if (e.target === overlay) close(); };
  overlay.querySelector('#aiImportClose').onclick = close;
  overlay.querySelector('#aiImportCancel').onclick = close;
  const importInput = overlay.querySelector('#aiImportInput');
  requestAnimationFrame(() => importInput?.focus?.({ preventScroll: true }));

  const status = overlay.querySelector('#aiImportStatus');
  const goBtn = overlay.querySelector('#aiImportGo');
  goBtn.onclick = async () => {
    if (goBtn.getAttribute('disabled')) return;
    const rawInput = importInput.value.trim();
    if (!rawInput) { setInlineStatus(status, '请先粘贴小红书链接、网页链接或菜谱文字。', 'bad'); return; }
    const { url, remainingText } = extractFirstHttpUrl(rawInput);
    const isXiaohongshuUrl = /(?:xhslink|xiaohongshu|小红书)/i.test(url || '');
    const loadingText = isXiaohongshuUrl ? '正在读取视频内容，可能需要稍等片刻…' : '正在整理菜谱…';
    goBtn.setAttribute('disabled', 'true');
    goBtn.innerHTML = `<span class="spinner"></span> ${loadingText}`;
    setInlineStatus(status, loadingText, 'info');
    try {
      const draft = url
        ? await importRecipeFromSource({ url, text: remainingText, file: null })
        : await importRecipeFromSource({ text: rawInput, file: null });
      setInlineStatus(status, '解析完成，正在打开编辑器…', 'ok');
      setTimeout(() => { close(); openEditorWithAiDraft(draft); }, 500);
    } catch (err) {
      const copy = getRecipeImportAiFailureCopy(err);
      setActionStatus(status, {
        title: copy.title,
        message: copy.message,
        primaryText: '编辑后重试',
        secondaryText: '稍后再试',
        onPrimary: () => {
          importInput.focus();
          setInlineStatus(status, '可以把菜谱文字直接粘贴到上方，再点开始导入。', 'info');
        },
        onSecondary: () => setInlineStatus(status, '可以稍后再试；本地菜谱和厨房数据不受影响。', 'info')
      });
      showToast('AI 暂不可用', { tone: 'error' });
      goBtn.removeAttribute('disabled');
      goBtn.innerHTML = '开始导入';
    }
  };
}
