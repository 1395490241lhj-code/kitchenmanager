import { els } from '../dom.js?v=89';
import {
  buildCatalog,
  buildIngredientOptions,
  getCanonicalName,
  guessKitchenUnit
} from '../ingredients.js?v=1';
import {
  applyOverlay,
  loadOverlay,
  saveOverlay
} from '../backup.js?v=2';
import {
  escapeHtml,
  escapeOptionAttr,
  getRecipeStatusInfo,
  normalizeDifficulty,
  setInlineStatus,
  setSelectValueWithOption
} from '../components/status.js?v=1';

export function renderRecipeEditor(id, base, { replaceView = null } = {}){
  const overlay = loadOverlay();
  const baseIng = base.recipe_ingredients || {};
  const overIng = overlay.recipe_ingredients || {};
  const ingredientOptions = buildIngredientOptions(buildCatalog(base));
  const rBase = (base.recipes||[]).find(x => x.id===id);
  const hasOverlayRecipe = Object.prototype.hasOwnProperty.call(overlay.recipes || {}, id);
  const rOv = hasOverlayRecipe ? (overlay.recipes||{})[id] || {} : {};
  if(!rBase && !hasOverlayRecipe && !/^(u-|ai-search-)/.test(id || '')) {
    const missing = document.createElement('div');
    missing.className = 'card editor-not-found';
    missing.innerHTML = `<h2>菜谱不存在</h2><p class="meta">这个编辑链接没有对应的菜谱，可能是旧链接或已删除的草稿。</p><a class="btn" href="#recipes">返回菜谱</a>`;
    return missing;
  }
  const r = {...(rBase||{id}), ...rOv};
  const items = (overIng[id] ?? baseIng[id] ?? []).map(x => ({...x}));
  const isCustomRecipe = !rBase;
  const statusInfo = getRecipeStatusInfo(r, id, rBase, rOv);
  const isAiDraft = statusInfo.className === 'draft';

  const wrap = document.createElement('div'); wrap.className = 'card recipe-editor-card';
  wrap.innerHTML = `
    <div class="editor-header">
      <h2 class="editor-title">编辑菜谱</h2>
      <a class="btn" onclick="history.back()">返回</a>
    </div>
    <div class="recipe-editor-status">
      <span class="recipe-status-pill ${statusInfo.className}">${escapeHtml(statusInfo.label)}</span>
      ${isAiDraft ? '<span class="meta">保存时可转为普通自定义菜谱。</span>' : ''}
    </div>
    <div id="editorStatus" class="inline-status" hidden></div>
    <div class="editor-field-grid">
      <div class="full"><label class="small">菜名</label><input id="rName" value="${escapeOptionAttr(r.name||'')}" class="full-width-input"></div>
      <div class="full"><label class="small">标签 (逗号分隔)</label><input id="rTags" value="${escapeOptionAttr((r.tags||[]).join(','))}" class="full-width-input"></div>
      <div><label class="small">预计耗时</label><input id="rPrepTime" value="${escapeOptionAttr(r.prepTime || '')}" placeholder="例如 30分钟"></div>
      <div><label class="small">难度</label><select id="rDifficulty"><option value="">未填写</option><option value="简单">简单</option><option value="中等">中等</option><option value="复杂">复杂</option></select></div>
      <div><label class="small">份量</label><input id="rServings" value="${escapeOptionAttr(r.servings || '')}" placeholder="例如 2人份"></div>
    </div>

    <h3 class="editor-section-title">用料表</h3>
    <table class="table recipe-editor-table">
      <thead><tr><th>用料</th><th>数量</th><th>单位</th><th class="right"><a class="btn small" id="addRow">新增</a></th></tr></thead>
      <tbody id="rows"></tbody>
    </table>
    <datalist id="recipeIngredientList">${ingredientOptions.map(o=>`<option value="${escapeOptionAttr(o.value)}"${o.label ? ` label="${escapeOptionAttr(o.label)}"` : ''}></option>`).join('')}</datalist>

    <h3 class="editor-section-title">做法 (Method)</h3>
    <textarea id="rMethod" rows="8" placeholder="请输入烹饪步骤..." class="editor-textarea">${escapeHtml(r.method || '')}</textarea>

    <div class="controls editor-actions">
       <div>
         <a class="btn bad" id="hideBtn">${(overlay.deletes||{})[id]?'取消隐藏':'删除/隐藏'}</a>
         ${!isCustomRecipe ? '<a class="btn" id="resetBtn">重置</a>' : ''}
       </div>
       <a class="btn ok" id="saveBtn">${isAiDraft ? '保存为自定义菜谱' : '保存'}</a>
    </div>
  `;
  const tbody = wrap.querySelector('#rows');
  const editorStatus = wrap.querySelector('#editorStatus');
  setSelectValueWithOption(wrap.querySelector('#rDifficulty'), normalizeDifficulty(r.difficulty));

  function showEditorStatus(message, type = 'bad') {
    setInlineStatus(editorStatus, message, type);
  }

  function addRow(item='', qty='', unit=''){
    const canonical = getCanonicalName(item || '');
    const defaultUnit = unit || (canonical ? guessKitchenUnit(canonical) : '份');
    const tr = document.createElement('tr');
    const unitChoices = Array.from(new Set([defaultUnit, '份', '个', '盒', '袋', '包', '瓶', '把', '根', '块', '条', 'g', 'ml', 'pcs'].filter(Boolean)));
    const unitHtml = unitChoices.map(u => `<option value="${escapeOptionAttr(u)}"${defaultUnit===u?' selected':''}>${escapeHtml(u)}</option>`).join('');
    tr.innerHTML = `
      <td><input list="recipeIngredientList" placeholder="食材名" value="${escapeOptionAttr(item)}"></td>
      <td><input type="number" min="0" step="0.1" placeholder="可选" value="${qty}"></td>
      <td><select>${unitHtml}</select></td>
      <td class="right"><a class="btn bad small">删</a></td>`;
    els('.btn', tr)[0].onclick = ()=> tr.remove();
    els('input', tr)[0].addEventListener('input', e => {
      const val = e.target.value.trim();
      if(val) setSelectValueWithOption(els('select', tr)[0], guessKitchenUnit(getCanonicalName(val)));
    });
    tbody.appendChild(tr);
  }
  if(items.length) items.forEach(it => addRow(it.item || '', (typeof it.qty==='number' && isFinite(it.qty))? it.qty : '', it.unit || ''));
  else addRow();
  wrap.querySelector('#addRow').onclick = ()=> addRow();

  function collectIngredients() {
    const arr = [];
    const rows = els('tbody#rows tr', wrap);
    if(!rows.length) throw new Error('至少需要保留一行食材。');
    rows.forEach((tr, index) => {
      const [i1,i2] = els('input', tr);
      const sel = els('select', tr)[0];
      const rawItem = i1.value.trim();
      if(!rawItem) throw new Error(`第 ${index + 1} 行食材名不能为空。`);
      const item = getCanonicalName(rawItem);
      const qtyText = i2.value.trim();
      let qty = null;
      if(qtyText !== '') {
        qty = Number(qtyText);
        if(!Number.isFinite(qty)) throw new Error(`第 ${index + 1} 行数量不是有效数字。`);
        if(qty < 0) throw new Error(`第 ${index + 1} 行数量不能为负数。`);
      }
      const unit = sel.value || guessKitchenUnit(item) || '份';
      setSelectValueWithOption(sel, unit);
      arr.push({ item, ...(qty===null?{}:{qty}), unit });
    });
    return arr;
  }

  wrap.querySelector('#saveBtn').onclick = ()=>{
    const name = wrap.querySelector('#rName').value.trim();
    if(!name) { showEditorStatus('菜名不能为空。'); return; }

    let arr;
    try {
      arr = collectIngredients();
    } catch(error) {
      showEditorStatus(error.message || String(error));
      return;
    }

    const mergedPack = applyOverlay(base, overlay);
    const duplicate = (mergedPack.recipes || []).find(recipe => recipe.id !== id && String(recipe.name || '').trim() === name);
    if(duplicate && !confirm(`已经有一道菜也叫「${name}」。仍然保存吗？`)) return;

    let tags = wrap.querySelector('#rTags').value.split(/[，,]/).map(s=>s.trim()).filter(Boolean);
    if(isAiDraft) {
      if(!confirm('这道菜现在是 AI 草稿。保存后会转为普通自定义菜谱，继续吗？')) return;
      tags = tags.filter(tag => !['AI草稿', 'AI搜索'].includes(tag));
      if(!tags.includes('自定义')) tags.push('自定义');
    }

    const method = wrap.querySelector('#rMethod').value.trim();
    const prepTime = wrap.querySelector('#rPrepTime').value.trim();
    const difficulty = normalizeDifficulty(wrap.querySelector('#rDifficulty').value);
    const servings = wrap.querySelector('#rServings').value.trim();
    const nextRecipe = { name, tags, method };
    if(prepTime) nextRecipe.prepTime = prepTime;
    if(difficulty) nextRecipe.difficulty = difficulty;
    if(servings) nextRecipe.servings = servings;

    overlay.recipes = overlay.recipes || {};
    overlay.recipes[id] = nextRecipe;
    overlay.recipe_ingredients = overlay.recipe_ingredients || {};
    overlay.recipe_ingredients[id] = arr;
    if(overlay.deletes) delete overlay.deletes[id];
    saveOverlay(overlay);
    showEditorStatus('已保存。', 'ok');
    window.setTimeout(() => history.back(), 450);
  };

  wrap.querySelector('#hideBtn').onclick = ()=>{
    if(!confirm(isCustomRecipe ? '确定删除这道自定义菜谱？' : '确定隐藏这道系统菜谱？')) return;
    overlay.deletes = overlay.deletes || {};
    if(overlay.deletes[id]) delete overlay.deletes[id];
    else overlay.deletes[id] = true;
    saveOverlay(overlay);
    history.back();
  };

  const rBtn = wrap.querySelector('#resetBtn');
  if(rBtn) rBtn.onclick = ()=>{
    if(!confirm('确定重置？')) return;
    if(overlay.recipes) delete overlay.recipes[id];
    if(overlay.recipe_ingredients) delete overlay.recipe_ingredients[id];
    if(overlay.deletes) delete overlay.deletes[id];
    saveOverlay(overlay);
    const newView = renderRecipeEditor(id, base, { replaceView });
    if(replaceView) replaceView(newView);
  };

  return wrap;
}
