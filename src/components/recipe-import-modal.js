import { loadOverlay, saveOverlay } from '../backup.js?v=222';
import { genId } from '../shopping.js?v=222';
import { importRecipeFromSource, getRecipeImportAiFailureCopy } from '../ai.js?v=225';
import { setActionStatus, setInlineStatus, showToast } from './status.js?v=223';

const AI_DRAFT_SESSION_KEY = 'kitchen-ai-draft-pending';

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
        <p class="km-modal-subtitle">粘贴菜谱链接，或上传截图/视频，系统会整理成可编辑草稿。</p>
        <label class="ai-import-field">
          <span>粘贴链接</span>
          <input id="aiImportUrl" type="url" inputmode="url" placeholder="小红书 / 网页菜谱链接">
        </label>
        <label class="ai-import-field ai-import-text-field" id="aiImportTextField" hidden>
          <span>粘贴菜谱文字</span>
          <textarea id="aiImportText" rows="5" placeholder="菜名、食材、做法都可以直接粘贴在这里"></textarea>
        </label>
        <label class="ai-import-field ai-import-file">
          <span>上传视频 / 截图</span>
          <input id="aiImportFile" type="file" accept="image/*,video/*" hidden>
          <span class="ai-import-filename" id="aiImportFileName">点此选择文件</span>
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
  requestAnimationFrame(() => overlay.querySelector('#aiImportUrl')?.focus?.({ preventScroll: true }));

  const fileInput = overlay.querySelector('#aiImportFile');
  const fileName = overlay.querySelector('#aiImportFileName');
  const textField = overlay.querySelector('#aiImportTextField');
  const textInput = overlay.querySelector('#aiImportText');
  overlay.querySelector('.ai-import-file').onclick = (e) => { if (e.target !== fileInput) fileInput.click(); };
  fileInput.onchange = () => { fileName.textContent = fileInput.files[0] ? fileInput.files[0].name : '点此选择文件'; };

  const status = overlay.querySelector('#aiImportStatus');
  const goBtn = overlay.querySelector('#aiImportGo');
  goBtn.onclick = async () => {
    if (goBtn.getAttribute('disabled')) return;
    const raw = overlay.querySelector('#aiImportUrl').value.trim();
    const pastedText = textInput.value.trim();
    const match = raw.match(/https?:\/\/[^\s]+/g);
    const url = match ? match[0].replace(/[，。、,.;；]+$/, '') : '';
    const file = fileInput.files[0] || null;
    if (!raw && !file && !pastedText) { setInlineStatus(status, '请粘贴链接、菜谱文字或选择一个视频/截图。', 'bad'); return; }
    if (raw && !url && !pastedText) { setInlineStatus(status, '没找到有效链接，请检查粘贴内容，或改用粘贴文本。', 'bad'); return; }
    goBtn.setAttribute('disabled', 'true');
    goBtn.innerHTML = '<span class="spinner"></span> 正在整理菜谱…';
    try {
      const draft = await importRecipeFromSource(pastedText ? { text: pastedText, file: null } : { url, file });
      setInlineStatus(status, '解析完成，正在打开编辑器…', 'ok');
      setTimeout(() => { close(); openEditorWithAiDraft(draft); }, 500);
    } catch (err) {
      const copy = getRecipeImportAiFailureCopy(err);
      const textModeVisible = !textField.hidden;
      setActionStatus(status, {
        title: copy.title,
        message: copy.message,
        primaryText: textModeVisible ? '' : '改用粘贴文本',
        secondaryText: '稍后再试',
        onPrimary: () => {
          textField.hidden = false;
          textInput.focus();
          setInlineStatus(status, '可以直接粘贴菜谱文字后再点开始导入。', 'info');
        },
        onSecondary: () => setInlineStatus(status, '可以稍后再试；本地菜谱和厨房数据不受影响。', 'info')
      });
      showToast('AI 暂不可用', { tone: 'error' });
      goBtn.removeAttribute('disabled');
      goBtn.innerHTML = '开始导入';
    }
  };
}
