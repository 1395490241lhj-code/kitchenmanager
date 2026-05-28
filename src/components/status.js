export function escapeOptionAttr(value) {
  return String(value || '').replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

export function escapeHtml(value) {
  return String(value || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

export function brieflyConfirmButton(button, text = '已加入') {
  if(!button) return;
  const originalText = button.textContent;
  button.textContent = text;
  button.classList.add('is-confirmed');
  button.disabled = true;
  window.setTimeout(() => {
    button.disabled = false;
    button.classList.remove('is-confirmed');
    button.textContent = originalText;
  }, 900);
}

export function setInlineStatus(node, message, type = 'info') {
  if (!node) return;
  if (!message) {
    node.hidden = true;
    node.textContent = '';
    return;
  }
  node.hidden = false;
  node.textContent = message;
  node.className = `small inline-status ${type}`;
}

export function setSelectValueWithOption(select, value) {
  const v = String(value || '').trim();
  if (!v || !select) return;
  if (!Array.from(select.options).some(option => option.value === v)) {
    select.appendChild(new Option(v, v));
  }
  select.value = v;
}

export function normalizeDifficulty(value) {
  return ['简单', '中等', '复杂'].includes(value) ? value : '';
}

export function getRecipeStatusInfo(recipe, id, baseRecipe = null, overlayRecipe = null) {
  const tags = recipe?.tags || [];
  if (recipe?.isAiDraft || tags.includes('AI草稿')) return { label: 'AI 草稿', className: 'draft' };
  if (!baseRecipe) return { label: '自定义菜谱', className: 'custom' };
  if (overlayRecipe && Object.keys(overlayRecipe).length) return { label: '系统菜谱修改版', className: 'modified' };
  return { label: '系统菜谱', className: 'system' };
}
