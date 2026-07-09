/*
 * src/components/recipe-create-modal.js —— 菜谱页「新建菜谱」轻量弹窗（不跳转 / 不改 hash）
 *
 * 设计约束：
 *  - 不改菜谱 JSON 原始数据 / localStorage key；保存逻辑与 recipe-editor-view.js 一致，
 *    都写入用户 overlay（overlay.recipes[id] + overlay.recipe_ingredients[id]）。
 *  - 仅做第一阶段轻量新建（菜名 / 标签 / 食材多行 / 做法）；完整编辑仍走 #recipe-edit:id。
 *  - 复用 .km-modal-overlay / .km-modal-content 既有底部弹窗风格。
 */
import { genId } from '../shopping.js?v=235';
import { getCanonicalName } from '../ingredients.js?v=235';
import { applyOverlay, loadOverlay, saveOverlay } from '../backup.js?v=235';
import { escapeHtml, showToast } from './status.js?v=235';

const CLOSE_SVG = `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>`;

// 标签解析：逗号 / 顿号 / 分号分隔。
export function parseRecipeTags(text) {
  return String(text || '').split(/[，,、;；]+/).map(s => s.trim()).filter(Boolean);
}

/**
 * 食材多行文本 → recipe_ingredients 结构（[{ item, qty?, unit }]）。
 *  支持「鸡蛋 2个」「番茄 2 个」「葱」「豆腐 1块」「土豆*3」；无数量则省略 qty，无单位则 unit 空。
 *  纯本地解析，不调用 AI。
 */
export function parseRecipeIngredientText(text) {
  const out = [];
  for (const rawLine of String(text || '').split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) continue;
    for (const seg0 of line.split(/[，,、;；]+/).map(s => s.trim()).filter(Boolean)) {
      const seg = seg0.replace(/^[-•·]\s*/, '').trim();
      if (!seg) continue;
      let m = seg.match(/^(.+?)\s*[*xX×]\s*(\d+(?:\.\d+)?)\s*([^\d\s]*)$/);     // 名*数量[单位]
      if (!m) m = seg.match(/^(.+?)\s+(\d+(?:\.\d+)?)\s*([^\d\s]*)$/);          // 名 数量[单位]（空格分隔）
      if (!m) m = seg.match(/^([^\d]+?)(\d+(?:\.\d+)?)\s*([^\d\s]*)$/);         // 名数量[单位]（无空格）
      if (m) {
        const item = getCanonicalName(m[1].trim());
        if (!item) continue;
        const qty = Number(m[2]);
        const unit = (m[3] || '').trim();
        const row = { item, unit };
        if (Number.isFinite(qty)) row.qty = qty;
        out.push(row);
      } else {
        const item = getCanonicalName(seg);
        if (item) out.push({ item, unit: '' });
      }
    }
  }
  return out;
}

/**
 * 轻量 helper：创建一条用户自定义菜谱，写入 overlay（与编辑器保存口径一致）。
 * @param {Object} base  当前数据包（用于重名校验）
 * @param {{name:string, tags?:string[], ingredients?:Array, method?:string, source?:string}} data
 * @returns {string} 新菜谱 id
 * @throws {Error} 菜名为空 / 重名
 */
export function createUserRecipe(base, { name, tags = [], ingredients = [], method = '', source = '' } = {}) {
  const cleanName = String(name || '').trim();
  if (!cleanName) throw new Error('菜名不能为空。');

  const overlay = loadOverlay();
  const mergedPack = applyOverlay(base || { recipes: [] }, overlay);
  const dup = (mergedPack.recipes || []).find(r => String(r.name || '').trim() === cleanName);
  if (dup) throw new Error(`已有一道菜名为「${cleanName}」，请换个菜名。`);

  const id = genId();
  const cleanSource = String(source || '').trim();
  overlay.recipes = overlay.recipes || {};
  const recipeRecord = {
    name: cleanName,
    tags: tags.length ? tags : ['自定义'],
    method: String(method || '').trim()
  };
  if (cleanSource) recipeRecord.source = cleanSource;
  overlay.recipes[id] = recipeRecord;
  overlay.recipe_ingredients = overlay.recipe_ingredients || {};
  overlay.recipe_ingredients[id] = Array.isArray(ingredients) ? ingredients : [];
  if (overlay.deletes) delete overlay.deletes[id];
  saveOverlay(overlay);
  window.invalidatePackCache?.();
  return id;
}

/**
 * 打开「新建菜谱」弹窗。
 * @param {Object}   base   当前数据包（重名校验用）
 * @param {Object}   [opts]
 * @param {Function} [opts.onSaved] 保存成功回调（参数为新菜谱 id），用于刷新菜谱列表。
 */
export function showRecipeCreateModal(base, { onSaved = () => {} } = {}) {
  const overlayEl = document.createElement('div');
  overlayEl.className = 'km-modal-overlay';
  const panel = document.createElement('div');
  panel.className = 'km-modal-content recipe-create-modal';
  panel.innerHTML = `
    <div class="km-modal-header">
      <span class="km-modal-title">新建菜谱</span>
      <button type="button" class="km-modal-close" aria-label="关闭">${CLOSE_SVG}</button>
    </div>
    <div class="km-modal-body recipe-create-body">
      <div class="rcm-field">
        <label class="rcm-label" for="rcmName">菜名 <span class="rcm-required">*</span></label>
        <input id="rcmName" class="rcm-input" type="text" placeholder="例如 番茄炒蛋" autocomplete="off">
      </div>
      <div class="rcm-field">
        <label class="rcm-label" for="rcmTags">标签（可选，逗号 / 顿号分隔）</label>
        <input id="rcmTags" class="rcm-input" type="text" placeholder="例如 家常,快手" autocomplete="off">
      </div>
      <div class="rcm-field">
        <label class="rcm-label" for="rcmIngredients">食材（每行一项，可写数量单位）</label>
        <textarea id="rcmIngredients" class="rcm-input rcm-area" rows="4" placeholder="鸡蛋 2个&#10;番茄 2个&#10;葱 1根"></textarea>
      </div>
      <div class="rcm-field">
        <label class="rcm-label" for="rcmMethod">做法（可选）</label>
        <textarea id="rcmMethod" class="rcm-input rcm-area rcm-method-area" rows="5" placeholder="1. 番茄切块、鸡蛋打散…"></textarea>
      </div>
      <p class="quick-shop-hint" id="rcmStatus" hidden></p>
    </div>
    <div class="km-modal-actions rcm-actions">
      <button type="button" class="btn" id="rcmCancel">取消</button>
      <button type="button" class="btn ok" id="rcmSave">保存菜谱</button>
    </div>
  `;
  overlayEl.appendChild(panel);
  document.body.appendChild(overlayEl);
  requestAnimationFrame(() => overlayEl.classList.add('open'));

  let closing = false;
  const close = () => {
    if (closing) return;
    closing = true;
    overlayEl.classList.add('closing');
    setTimeout(() => overlayEl.remove(), 220);
  };
  panel.querySelector('.km-modal-close').onclick = close;
  panel.querySelector('#rcmCancel').onclick = close;
  overlayEl.onclick = e => { if (e.target === overlayEl) close(); };

  const nameInput = panel.querySelector('#rcmName');
  const status = panel.querySelector('#rcmStatus');
  const showStatus = (text, ok = false) => {
    status.hidden = false;
    status.textContent = text;
    status.classList.toggle('is-bad', !ok);
  };

  panel.querySelector('#rcmSave').onclick = () => {
    const name = nameInput.value.trim();
    if (!name) { showStatus('菜名不能为空。', false); nameInput.focus(); return; }
    try {
      const id = createUserRecipe(base, {
        name,
        tags: parseRecipeTags(panel.querySelector('#rcmTags').value),
        ingredients: parseRecipeIngredientText(panel.querySelector('#rcmIngredients').value),
        method: panel.querySelector('#rcmMethod').value
      });
      showStatus('✓ 已添加菜谱', true);
      showToast('已保存菜谱', { tone: 'success' });
      setTimeout(() => { close(); onSaved(id); }, 450);
    } catch (err) {
      showStatus(err && err.message ? err.message : '保存失败，请重试。', false);
    }
  };

  setTimeout(() => nameInput.focus(), 80);
}
