import { S, todayISO } from '../storage.js?v=222';
import { buildCatalog, explodeCombinedItems } from '../ingredients.js?v=222';
import { splitRecipeIngredients } from '../utils/recipe-sanitizer.js?v=222';
import { applyCookCalibration, computeCookDeductions, getStockCoverageAnalysis, loadInventory } from '../inventory.js?v=222';
import {
  addMissingRecipeIngredientsToShopping,
  getMissingRecipeIngredients,
  markRecipeCooked
} from '../recommendations.js?v=222';
import { addRecipeToPlanWithMissingCheck } from '../components/plan-missing-check.js?v=222';
import {
  callAiForMethod,
  formatAiErrorMessage,
  withTimeout
} from '../ai.js?v=222';
import { loadOverlay, saveOverlay } from '../backup.js?v=222';
import { escapeHtml, brieflyConfirmButton, getRecipeStatusInfo, showToast } from '../components/status.js?v=222';
import { showCalibrationModal } from '../components/modal.js?v=222';
import { getCookShoppingCandidates, showCookCompleteFeedback } from '../components/cook-feedback.js?v=222';
import { splitMethodSteps } from '../utils/method-steps.js?v=222';

// 把做法字符串渲染成 glass 分步列表（每步 escapeHtml；无步骤时返回空串，由调用方兜底）。
function methodToListHtml(method) {
  const steps = splitMethodSteps(method);
  if (!steps.length) return '';
  const items = steps.map((s, i) =>
    `<li class="method-step"><span class="method-step-num">${i + 1}</span><span class="method-step-text">${escapeHtml(s)}</span></li>`
  ).join('');
  return `<ol class="method-steps">${items}</ol>`;
}

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

  // 食材 / 调料 / 非库存三分流（统一口径）：confirmItems / 食材清单 / 买菜候选都只看 core。
  const { foods: foodItems, seasonings: itemSeasonings } = splitRecipeIngredients(items);

  // Detect unit-mismatch among items that are NOT already flagged as missing.
  // These are items where findInventoryMatch found a hit (so they count as "matched"),
  // but the units differ — the user should double-check. 只检查核心食材的单位/状态。
  const confirmItems = r.isCreative ? [] : foodItems
    .filter(it => it.item)
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
    if (!parts.length) return '食材看起来已经够做这道菜';
    return parts.join('；');
  })();

  const div = document.createElement('div'); div.className = 'detail-view';
  const missingMethodContent = `<div class="ai-empty-note">暂无详细做法。可以让 AI 先生成草稿，确认后再保存。</div><button type="button" class="btn ai" id="genMethodBtn">✨ AI 生成草稿</button>`;
  // 已保存做法改为 glass 分步展示；若解析不出步骤（极端空白）回退原整段文本；无做法则保留 AI 草稿入口。
  const methodContent = r.method
    ? (methodToListHtml(r.method) || `<div class="method-text">${escapeHtml(r.method)}</div>`)
    : missingMethodContent;

  // 食材清单只显示核心食材，调料清单显示调料；水/高汤/汤汁/适量等非库存项不展示
  // （做法文本里自然会出现，无需重复）。再并入菜谱单列的 r.seasonings（按名称去重）。
  const extraSeasonings = Array.isArray(r.seasonings) ? r.seasonings.filter(s => s && s.item) : [];
  const seasoningItems = [];
  const seenSeasoning = new Set();
  for (const s of [...itemSeasonings, ...extraSeasonings]) {
    const key = String(s.item || '').trim();
    if (!key || seenSeasoning.has(key)) continue;
    seenSeasoning.add(key);
    seasoningItems.push(s);
  }
  const pillHtml = (it, cls = '') => `<div class="ing-tag-pill${cls ? ' ' + cls : ''}">${escapeHtml(it.item)} ${it.qty ? `<span class="qty">${escapeHtml(it.qty)}${escapeHtml(it.unit || '')}</span>` : ''}</div>`;
  // 不回退到原始 items：没有核心食材时给轻提示，绝不把水/汤/调料显示成食材。
  const foodBlock = `<div class="block"><h4>🥬 食材清单 Ingredients</h4><div class="ing-compact-container">${foodItems.length ? foodItems.map(it => pillHtml(it)).join('') : '<span class="meta">这道菜没有明确需要管理的食材。</span>'}</div></div>`;
  const seasoningBlock = seasoningItems.length ? `<div class="block ingredient-seasoning-block"><h4>🧂 调料清单 Seasonings <span class="meta seasoning-note">仅做菜谱参考，不参与食材余量</span></h4><div class="ing-compact-container">${seasoningItems.map(it => pillHtml(it, 'seasoning-pill')).join('')}</div></div>` : '';

  div.innerHTML = `<div class="detail-nav-bar"><button type="button" class="btn" onclick="history.back()">← 返回</button><a class="btn" href="#recipe-edit:${r.id}">✎ 编辑 / 录入</a></div><h2 class="detail-title">${escapeHtml(r.name)}</h2><div class="tags meta detail-tags">${(r.tags||[]).map(escapeHtml).join(' / ')}</div><div class="recipe-meta-strip">${detailMeta.map(text => `<span>${escapeHtml(text)}</span>`).join('')}</div><div class="recipe-action-panel"><div class="recipe-action-copy"><span>下一步</span><strong>${escapeHtml(isPlanned ? '已安排在菜单计划' : '先加入菜单计划')}</strong><p>${escapeHtml(missingSummary)}。做完后可更新食材，用完的也能顺手加入买菜。</p></div><div class="recipe-action-buttons"><div style="display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 6px; width: 100%;"><button type="button" class="btn ok small" style="flex: 1; min-width: 90px;" id="planToday" ${isPlannedToday ? 'disabled' : ''}>${isPlannedToday ? '今天已计划' : '计划今天'}</button><button type="button" class="btn ok small" style="flex: 1; min-width: 90px;" id="planTomorrow" ${isPlannedTomorrow ? 'disabled' : ''}>${isPlannedTomorrow ? '明天已计划' : '计划明天'}</button><button type="button" class="btn ok small" style="flex: 1; min-width: 90px;" id="planDayAfter" ${isPlannedDayAfter ? 'disabled' : ''}>${isPlannedDayAfter ? '后天已计划' : '计划后天'}</button></div><button type="button" class="btn" id="detailAddMissing">${missingIngredients.length ? '缺少食材加入买菜' : '食材已齐'}</button><button type="button" class="btn favorite-btn" id="detailMarkCooked">标记为已做完</button></div><div class="recipe-action-feedback" id="recipeActionFeedback" hidden></div></div>${foodBlock}${seasoningBlock}<section class="block method-glass glass-panel"><h4 class="method-glass-title">制作方法 Method</h4><div id="methodArea">${methodContent}</div></section>`;

  const actionFeedback = div.querySelector('#recipeActionFeedback');
  const showActionFeedback = (text, { actionLabel = '', onAction = null, autoHide = true } = {}) => {
    actionFeedback.hidden = false;
    if (actionLabel && typeof onAction === 'function') {
      actionFeedback.innerHTML = `<span>${escapeHtml(text)}</span><button type="button" class="recipe-feedback-link">${escapeHtml(actionLabel)}</button>`;
      actionFeedback.querySelector('.recipe-feedback-link').onclick = onAction;
    } else {
      actionFeedback.textContent = text;
    }
    if (autoHide) window.setTimeout(() => { actionFeedback.hidden = true; }, 1800);
  };

  const bindPlanBtn = (btnId, dateStr, successMsg, labelActive) => {
    const btn = div.querySelector(btnId);
    if (btn) {
      btn.onclick = async () => {
        const planLabel = dateStr === today
          ? '今日计划'
          : dateStr === tomorrowISO
            ? '明天计划'
            : '后天计划';
        const result = await addRecipeToPlanWithMissingCheck(id, pack, inv, {
          date: dateStr,
          recipe: r,
          fallbackItems: items,
          planLabel,
          source: 'recipe-detail'
        });
        const added = result.added;
        if (added) {
          btn.textContent = labelActive;
          btn.disabled = true;
          const feedbackMsg = result.missing.length
            ? (result.shoppingAddedCount ? `已加入${planLabel}，缺的食材已加入买菜清单。` : `已加入${planLabel}，缺的食材可稍后处理。`)
            : successMsg;
          showActionFeedback(feedbackMsg, dateStr === today ? {
            actionLabel: '去今日看看',
            autoHide: false,
            onAction: () => { location.hash = '#today'; }
          } : {});
          if (typeof onRoute === 'function') {
            setTimeout(onRoute, 1000);
          }
        }
      };
    }
  };

  bindPlanBtn('#planToday', today, '已加入今天，做完后会帮你更新食材。', '今天已计划');
  bindPlanBtn('#planTomorrow', tomorrowISO, '已加入明天的计划。', '明天已计划');
  bindPlanBtn('#planDayAfter', dayAfterISO, '已加入后天的计划。', '后天已计划');

  const detailAddMissing = div.querySelector('#detailAddMissing');
  if (!missingIngredients.length) detailAddMissing.disabled = true;
  detailAddMissing.onclick = () => {
    const count = addMissingRecipeIngredientsToShopping(r, pack, inv, items);
    if (count > 0) { brieflyConfirmButton(detailAddMissing, '已加入买菜'); showActionFeedback(`已把 ${count} 项缺少食材加入买菜清单。`); }
  };

  div.querySelector('#detailMarkCooked').onclick = () => {
    const cookedBtn = div.querySelector('#detailMarkCooked');
    cookedBtn.disabled = true;

    // 计算混合双轨预扣减（计件整数相减 / 档位降一级）。
    const predictions = computeCookDeductions(items, inv);

    // 没有任何匹配库存 → 直接记录做完，不弹校准舱。
    if (!predictions.length) {
      // 只把核心食材作为买菜候选；没有核心食材就给空数组，绝不把水/汤/调料补进买菜。
      const missingCandidates = foodItems.filter(it => it && (it.item || it.name));
      markRecipeCooked(id);
      brieflyConfirmButton(cookedBtn, '已记录');
      cookedBtn.disabled = false;
      showCookCompleteFeedback({
        updated: false,
        missing: missingCandidates,
        onClose: () => { if (typeof onRoute === 'function') onRoute(); },
        onShoppingAdded: () => { if (typeof onRoute === 'function') onRoute(); }
      });
      return;
    }

    showCalibrationModal(
      r.name,
      predictions,
      // onConfirm: 写入校准后的库存 + 记录做完
      (calibrations) => {
        const candidates = getCookShoppingCandidates({ calibrations });
        applyCookCalibration(inv, calibrations);
        markRecipeCooked(id);
        brieflyConfirmButton(cookedBtn, '已更新');
        cookedBtn.disabled = false;
        showCookCompleteFeedback({
          updated: true,
          candidates,
          onClose: () => { if (typeof onRoute === 'function') onRoute(); },
          onShoppingAdded: () => { if (typeof onRoute === 'function') onRoute(); }
        });
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
      methodArea.innerHTML = `${methodToListHtml(text) || `<div class="method-text">${escapeHtml(text)}</div>`}<div class="small ok method-saved-note">已保存到菜谱</div>`;
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
          showToast('AI 暂不可用', { tone: 'error' });
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
