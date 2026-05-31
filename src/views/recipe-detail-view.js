import { S, todayISO } from '../storage.js?v=184';
import { buildCatalog, explodeCombinedItems, isSeasoning } from '../ingredients.js?v=184';
import { deductInventoryForRecipe, getStockCoverageAnalysis, loadInventory } from '../inventory.js?v=184';
import {
  addMissingRecipeIngredientsToShopping,
  addRecipeToPlan,
  getMissingRecipeIngredients,
  markRecipeCooked
} from '../recommendations.js?v=184';
import {
  callAiForMethod,
  formatAiErrorMessage,
  withTimeout
} from '../ai.js?v=184';
import { loadOverlay, saveOverlay } from '../backup.js?v=184';
import { escapeHtml, brieflyConfirmButton, getRecipeStatusInfo } from '../components/status.js?v=184';
import { showDeductStockModal } from '../components/modal.js?v=184';

export function renderRecipeDetail(id, pack, { onRoute } = {}) {
  let r = (pack.recipes || []).find(x => x.id === id);
  if (!r && id === 'creative-ai-temp') {
    const aiData = S.load(S.keys.ai_recs, null);
    if (aiData && aiData.creative) {
      r = { id: 'creative-ai-temp', name: aiData.creative.name, tags: ['AI草稿'], method: '', isCreative: true, isAiDraft: true };
    }
  }
  if (!r) {
    const div = document.createElement('div');
    div.innerHTML = `<div style="padding:20px;text-align:center;">菜谱不存在。<br><button class="btn" onclick="history.back()">返回</button></div>`;
    return div;
  }

  const overlay = loadOverlay();
  const ovRecipe = (overlay.recipes || {})[id];
  if (ovRecipe) { r = { ...r, ...ovRecipe, method: ovRecipe.method || r.method || '' }; }
  const detailBaseHint = /^(u-|ai-search-)/.test(id) ? null : {};
  const detailStatus = getRecipeStatusInfo(r, id, detailBaseHint, ovRecipe);
  const detailMeta = [
    detailStatus.label,
    r.prepTime ? `预计耗时：${r.prepTime}` : '',
    r.difficulty ? `难度：${r.difficulty}` : '',
    r.servings ? `份量：${r.servings}` : ''
  ].filter(Boolean);

  let items = [];
  if (r.isCreative) {
    const aiData = S.load(S.keys.ai_recs, null);
    items = Array.isArray(aiData?.creative?.ingredients)
      ? aiData.creative.ingredients.map(item => ({ item: item.item || item.name || String(item), qty: item.qty || '', unit: item.unit || '' })).filter(item => item.item)
      : [{ item: '请参考 AI 草稿' }];
  } else {
    items = explodeCombinedItems(pack.recipe_ingredients[id] || []);
  }

  const catalog = buildCatalog(pack);
  const inv = loadInventory(catalog);
  const missingIngredients = getMissingRecipeIngredients(r, pack, inv, items);
  const plan = S.load(S.keys.plan, []);
  const today = todayISO();
  const baseDate = new Date(today);
  const tomorrow = new Date(baseDate);
  tomorrow.setDate(baseDate.getDate() + 1);
  const tomorrowISO = tomorrow.toISOString().slice(0, 10);
  const dayAfter = new Date(baseDate);
  dayAfter.setDate(baseDate.getDate() + 2);
  const dayAfterISO = dayAfter.toISOString().slice(0, 10);

  const isPlannedToday = plan.some(item => item.id === id && (item.date || today) === today);
  const isPlannedTomorrow = plan.some(item => item.id === id && item.date === tomorrowISO);
  const isPlannedDayAfter = plan.some(item => item.id === id && item.date === dayAfterISO);
  const isPlanned = isPlannedToday || isPlannedTomorrow || isPlannedDayAfter;

  // Detect unit-mismatch among items that are NOT already flagged as missing.
  // These are items where findInventoryMatch found a hit (so they count as "matched"),
  // but the units differ — the user should double-check.
  const confirmItems = r.isCreative ? [] : items
    .filter(it => it.item && !isSeasoning(it.item))
    .filter(it => !missingIngredients.some(m => (m.item || m.name) === it.item))
    .filter(it => {
      const analysis = getStockCoverageAnalysis(inv, it.item, it.qty, it.unit);
      return analysis.confidence === 'unit-mismatch' || analysis.confidence === 'status-only';
    });

  const missingSummary = (() => {
    const parts = [];
    if (missingIngredients.length) {
      parts.push(`还缺 ${missingIngredients.slice(0, 3).map(item => item.item).join('、')}${missingIngredients.length > 3 ? '等' : ''}`);
    }
    if (confirmItems.length) {
      parts.push(`${confirmItems.slice(0, 2).map(i => i.item).join('、')} 单位需确认`);
    }
    if (!parts.length) return '库存看起来已经够做这道菜';
    return parts.join('；');
  })();

  const div = document.createElement('div'); div.className = 'detail-view';
  const missingMethodContent = `<div class="ai-empty-note">暂无详细做法。可以让 AI 先生成草稿，确认后再保存。</div><button type="button" class="btn ai" id="genMethodBtn">✨ AI 生成草稿</button>`;
  const methodContent = r.method ? `<div class="method-text">${escapeHtml(r.method)}</div>` : missingMethodContent;

  const seasoningItems = Array.isArray(r.seasonings) ? r.seasonings.filter(s => s && s.item) : [];
  const seasoningBlock = seasoningItems.length ? `<div class="block"><h4>调料表 Seasonings <span class="meta seasoning-note">仅做菜谱参考，不参与库存扣减</span></h4><div class="ing-compact-container">${seasoningItems.map(it => `<div class="ing-tag-pill seasoning-pill">${escapeHtml(it.item)} ${it.qty ? `<span class="qty">${escapeHtml(it.qty)}${escapeHtml(it.unit||'')}</span>` : ''}</div>`).join('')}</div></div>` : '';

  div.innerHTML = `<div class="detail-nav-bar"><button type="button" class="btn" onclick="history.back()">← 返回</button><a class="btn" href="#recipe-edit:${r.id}">✎ 编辑 / 录入</a></div><h2 class="detail-title">${escapeHtml(r.name)}</h2><div class="tags meta detail-tags">${(r.tags||[]).map(escapeHtml).join(' / ')}</div><div class="recipe-meta-strip">${detailMeta.map(text => `<span>${escapeHtml(text)}</span>`).join('')}</div><div class="recipe-action-panel"><div class="recipe-action-copy"><span>下一步</span><strong>${escapeHtml(isPlanned ? '已安排在菜单计划' : '先加入菜单计划')}</strong><p>${escapeHtml(missingSummary)}。做完后可选择扣减库存。</p></div><div class="recipe-action-buttons"><div style="display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 6px; width: 100%;"><button type="button" class="btn ok small" style="flex: 1; min-width: 90px;" id="planToday" ${isPlannedToday ? 'disabled' : ''}>${isPlannedToday ? '今天已计划' : '计划今天'}</button><button type="button" class="btn ok small" style="flex: 1; min-width: 90px;" id="planTomorrow" ${isPlannedTomorrow ? 'disabled' : ''}>${isPlannedTomorrow ? '明天已计划' : '计划明天'}</button><button type="button" class="btn ok small" style="flex: 1; min-width: 90px;" id="planDayAfter" ${isPlannedDayAfter ? 'disabled' : ''}>${isPlannedDayAfter ? '后天已计划' : '计划后天'}</button></div><button type="button" class="btn" id="detailAddMissing">${missingIngredients.length ? '缺少食材加入清单' : '食材已齐'}</button><button type="button" class="btn favorite-btn" id="detailMarkCooked">标记为已做完</button></div><div class="recipe-action-feedback" id="recipeActionFeedback" hidden></div></div><div class="block"><h4>用料 Ingredients</h4><div class="ing-compact-container">${items.map(it => `<div class="ing-tag-pill">${escapeHtml(it.item)} ${it.qty ? `<span class="qty">${escapeHtml(it.qty)}${escapeHtml(it.unit||'')}</span>` : ''}</div>`).join('')}</div></div>${seasoningBlock}<div class="block"><h4>制作方法 Method</h4><div id="methodArea">${methodContent}</div></div>`;

  const actionFeedback = div.querySelector('#recipeActionFeedback');
  const showActionFeedback = (text) => {
    actionFeedback.hidden = false; actionFeedback.textContent = text;
    window.setTimeout(() => { actionFeedback.hidden = true; }, 1800);
  };

  const bindPlanBtn = (btnId, dateStr, successMsg, labelActive) => {
    const btn = div.querySelector(btnId);
    if (btn) {
      btn.onclick = () => {
        const added = addRecipeToPlan(id, dateStr);
        if (added) {
          btn.textContent = labelActive;
          btn.disabled = true;
          showActionFeedback(successMsg);
          if (typeof onRoute === 'function') {
            setTimeout(onRoute, 1000);
          }
        }
      };
    }
  };

  bindPlanBtn('#planToday', today, '已加入今天的计划。', '今天已计划');
  bindPlanBtn('#planTomorrow', tomorrowISO, '已加入明天的计划。', '明天已计划');
  bindPlanBtn('#planDayAfter', dayAfterISO, '已加入后天的计划。', '后天已计划');

  const detailAddMissing = div.querySelector('#detailAddMissing');
  if (!missingIngredients.length) detailAddMissing.disabled = true;
  detailAddMissing.onclick = () => {
    const count = addMissingRecipeIngredientsToShopping(r, pack, inv, items);
    if (count > 0) { brieflyConfirmButton(detailAddMissing, '已加入清单'); showActionFeedback(`已把 ${count} 项缺少食材加入购物清单。`); }
  };

  div.querySelector('#detailMarkCooked').onclick = () => {
    const cookedBtn = div.querySelector('#detailMarkCooked');
    cookedBtn.disabled = true;
    showDeductStockModal(
      r.name,
      items,
      inv,
      // onConfirm: deduct then mark cooked
      (deductions) => {
        let deductMsg = '未扣减库存。';
        if (deductions.length > 0) {
          const deductRes = deductInventoryForRecipe(inv, deductions);
          const deductedItems = deductRes.deducted || [];
          const skippedItems = deductRes.skipped || [];
          
          let parts = [];
          if (deductedItems.length > 0) {
            parts.push(`已扣减 ${deductedItems.map(d => `${d.name}×${d.qty}${d.unit||''}`).join('、')}`);
          }
          const mismatchNames = skippedItems.filter(s => s.reason === 'unit-mismatch').map(s => s.name);
          if (mismatchNames.length > 0) {
            parts.push(`跳过了不同单位食材：${mismatchNames.join('、')}`);
          }
          if (parts.length > 0) {
            deductMsg = parts.join('，') + '。';
          }
        }
        const result = markRecipeCooked(id);
        brieflyConfirmButton(cookedBtn, '已记录');
        showActionFeedback(`已记录做完${result.removedFromPlan ? '，并从今日计划移除' : ''}。${deductMsg}`);
        cookedBtn.disabled = false;
        if (typeof onRoute === 'function') {
          setTimeout(onRoute, 1000);
        }
      },
      // onSkip: just mark cooked, no deduction
      () => {
        const result = markRecipeCooked(id);
        brieflyConfirmButton(cookedBtn, '已记录');
        showActionFeedback(result.removedFromPlan ? '已记录做完，并从今日计划移除；库存没有扣减。' : '已记录做完；库存没有扣减。');
        cookedBtn.disabled = false;
        if (typeof onRoute === 'function') {
          setTimeout(onRoute, 1000);
        }
      },
      // onCancel
      () => { cookedBtn.disabled = false; }
    );
  };

  const methodArea = div.querySelector('#methodArea');
  const showMissingMethod = () => { methodArea.innerHTML = missingMethodContent; bindGenerateMethodButton(); };
  const showMethodDraft = (text) => {
    methodArea.innerHTML = `
      <div class="ai-draft-card">
        <div class="ai-draft-title">AI 生成草稿</div>
        <div class="method-text">${escapeHtml(text)}</div>
        <div class="controls ai-draft-actions">
          <button type="button" class="btn ok" id="saveAiMethodBtn">保存到菜谱</button>
          <button type="button" class="btn" id="regenerateAiMethodBtn">重新生成</button>
          <button type="button" class="btn bad" id="cancelAiMethodBtn">取消</button>
        </div>
      </div>
    `;
    methodArea.querySelector('#saveAiMethodBtn').onclick = () => {
      const currentOverlay = loadOverlay();
      currentOverlay.recipes = currentOverlay.recipes || {};
      currentOverlay.recipes[id] = { ...(currentOverlay.recipes[id] || {}), method: text };
      saveOverlay(currentOverlay); window.invalidatePackCache?.(); r.method = text;
      methodArea.innerHTML = `<div class="method-text">${escapeHtml(text)}</div><div class="small ok method-saved-note">已保存到菜谱</div>`;
    };
    methodArea.querySelector('#regenerateAiMethodBtn').onclick = e => generateMethodDraft(e.currentTarget);
    methodArea.querySelector('#cancelAiMethodBtn').onclick = () => showMissingMethod();
  };

  const generateMethodDraft = async (triggerBtn = null) => {
    const genBtn = triggerBtn || methodArea.querySelector('#genMethodBtn');
    if (!genBtn) return;
    const resetLabel = genBtn.id === 'regenerateAiMethodBtn' ? '重新生成' : '✨ AI 生成草稿';
    genBtn.setAttribute('disabled', 'true');
    genBtn.innerHTML = '<span class="spinner"></span> 生成中...';
    const maxRetries = 1; let attempt = 0; let success = false;
    while (attempt <= maxRetries && !success) {
      try {
        attempt++;
        const text = await withTimeout(callAiForMethod(r.name, items), 30000, 'AI 生成超时');
        success = true; showMethodDraft(text);
      } catch (e) {
        console.warn(`Attempt ${attempt} failed:`, e);
        if (attempt > maxRetries) {
          methodArea.innerHTML = `${missingMethodContent}<div class="ai-empty-note">${escapeHtml(formatAiErrorMessage(e))} 你仍然可以点"编辑 / 录入"手动补做法。</div>`;
          bindGenerateMethodButton(); genBtn.innerHTML = resetLabel; genBtn.removeAttribute('disabled');
        } else {
          genBtn.innerHTML = `<span class="spinner"></span> 正在重试 (${attempt}/${maxRetries})...`;
          await new Promise(r => setTimeout(r, 1000));
        }
      }
    }
  };

  function bindGenerateMethodButton() {
    const genBtn = methodArea.querySelector('#genMethodBtn');
    if (genBtn) genBtn.onclick = generateMethodDraft;
  }
  if (!r.method) bindGenerateMethodButton();
  return div;
}
