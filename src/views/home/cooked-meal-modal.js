/*
 * src/views/home/cooked-meal-modal.js —— 「记录消耗」弹窗（从 home-view 抽出）。
 * 三条候选来源：今日计划菜谱 / 本地文本匹配 / AI 辅助；全部经用户确认后才扣减库存。
 */
import { S, todayISO } from '../../storage.js?v=235';
import { getCanonicalName, guessKitchenUnit, UNIT_TYPE } from '../../ingredients.js?v=235';
import { applyCookCalibration, computeCookDeductions, gearInfo, GEAR_LABELS, isInventoryAvailable } from '../../inventory.js?v=235';
import { markRecipeCookedKeepPlan } from '../../recommendations.js?v=235';
import { callAiForCookedMeal, formatAiErrorMessage, withTimeout } from '../../ai.js?v=235';
import { escapeHtml, escapeOptionAttr, showToast } from '../../components/status.js?v=235';
import { getCookShoppingCandidates, showCookCompleteFeedback } from '../../components/cook-feedback.js?v=235';
import {
  buildLocalCookedMealCandidates,
  getRecipeCoreItems,
  matchCookedMealRecipe,
  mergeCookedMealCandidates,
  normalizeAiCookedMealResult
} from '../../utils/cooked-meal.js?v=235';
import { isDemoKitchenMode, refreshDemoKitchenBanner, setDemoStep } from './demo-kitchen.js?v=235';
import { getTodayPendingPlanRows, isPendingPlanRow } from '../../plan-selectors.js?v=235';

// “直接选食材”里的推荐排序：适合下面 / 煮螺蛳粉 / 麻辣烫等场景的快熟百搭配料优先出现。
const IMPROMPTU_ALLOWED_REGEX = /(菜|茼蒿|菠菜|韭菜|肠|午餐肉|培根|香肠|火腿|丸|棒|饺|千层肚|菇|豆腐|豆皮|腐竹|木耳|蛋|面条|粉|年糕|水饺)/;

function isImpromptuCandidate(e) {
  return isInventoryAvailable(e) && IMPROMPTU_ALLOWED_REGEX.test(String(e.name || ''));
}

function decorateCookedPredictions(predictions, candidates) {
  return (predictions || []).map(prediction => {
    const matchName = prediction.match?.name || prediction.name;
    const candidate = (candidates || []).find(item =>
      item && (item.matchName === matchName || item.item === matchName || getCanonicalName(item.item) === getCanonicalName(prediction.name))
    );
    return {
      ...prediction,
      reason: candidate?.reason || '需确认',
      suggestedQty: Number.isFinite(Number(candidate?.qty)) && Number(candidate.qty) > 0
        ? Number(candidate.qty)
        : (prediction.recipeQty || 1)
    };
  });
}

function getTodayPlanRecipeRows(pack) {
  const recipes = pack.recipes || [];
  return getTodayPendingPlanRows()
    .map(row => {
      const recipe = recipes.find(r => r.id === row.id);
      return recipe ? { row, recipe } : null;
    })
    .filter(Boolean);
}

function markTodayPlanCooked(recipeId) {
  if (!recipeId) return;
  const today = todayISO();
  const plans = S.load(S.keys.plan, []);
  let changed = false;
  for (const row of plans) {
    if (row && row.id === recipeId && isPendingPlanRow(row, today, today)) {
      row.isCooked = true;
      row.cookedAt = Date.now();
      changed = true;
    }
  }
  if (changed) S.save(S.keys.plan, plans);
  markRecipeCookedKeepPlan(recipeId);
}

function createRecordCookedButton(pack, inv, { onRoute = () => {} } = {}) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'record-cooked-btn';
  button.innerHTML = '<span class="record-cooked-icon">🍽️</span><span>记录消耗</span>';
  button.onclick = () => {
    if (isDemoKitchenMode()) {
      setDemoStep('cook');
      refreshDemoKitchenBanner({ onRoute });
    }
    const original = button.innerHTML;
    button.disabled = true;
    button.classList.add('is-opening');
    button.innerHTML = '<span class="record-cooked-icon">🍽️</span><span>打开中...</span>';
    requestAnimationFrame(() => {
      openCookedMealModal(pack, inv, { onRoute });
      window.setTimeout(() => {
        button.innerHTML = original;
        button.disabled = false;
        button.classList.remove('is-opening');
      }, 180);
    });
  };
  return button;
}

export function createRecordCookedCta(pack, inv, { onRoute = () => {} } = {}) {
  const cta = document.createElement('div');
  cta.className = 'record-cooked-cta';
  cta.innerHTML = `
    <span class="record-cooked-cta-text">
      <strong>记录消耗</strong>
      <small>选择这顿饭用掉的食材</small>
    </span>
  `;
  cta.appendChild(createRecordCookedButton(pack, inv, { onRoute }));
  return cta;
}

export function openCookedMealModal(pack, inv, { onRoute = () => {} } = {}) {
  const overlay = document.createElement('div');
  overlay.className = 'km-modal-overlay';
  const panel = document.createElement('div');
  panel.className = 'km-modal-content cooked-meal-modal';
  panel.innerHTML = `
    <div class="km-modal-header">
      <span class="km-modal-title">记录消耗</span>
      <button type="button" class="km-modal-close" aria-label="关闭">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
        </svg>
      </button>
    </div>
    <div class="km-modal-body cooked-meal-body">
      <p class="km-modal-subtitle cooked-meal-intro">选择实际做了哪些菜，库存会按用量更新。</p>
      <div class="cooked-meal-start" id="cookedMealStart"></div>
      <textarea class="cooked-meal-textarea" id="cookedMealText" rows="4" placeholder="比如：番茄炒蛋，或者我炒了鸡腿和豆芽"></textarea>
      <div class="small inline-status cooked-meal-status" id="cookedMealStatus" hidden></div>
      <div class="cooked-meal-result" id="cookedMealResult"></div>
      <div class="km-modal-actions cooked-meal-actions">
        <button type="button" class="btn km-action-weak" id="cookedMealCancel">稍后</button>
        <button type="button" class="btn km-action-secondary" id="cookedMealAddAction" hidden>添加食材</button>
        <button type="button" class="btn ok km-action-primary" id="cookedMealAnalyze">生成建议</button>
      </div>
    </div>
  `;
  overlay.appendChild(panel);
  document.body.appendChild(overlay);

  const textInput = panel.querySelector('#cookedMealText');
  const startHost = panel.querySelector('#cookedMealStart');
  const status = panel.querySelector('#cookedMealStatus');
  const resultHost = panel.querySelector('#cookedMealResult');
  const analyzeBtn = panel.querySelector('#cookedMealAnalyze');
  const addActionBtn = panel.querySelector('#cookedMealAddAction');
  const recipes = pack.recipes || [];
  let currentRecipe = null;
  let currentCandidates = [];
  let currentPredictions = [];
  let currentSourceLabel = '';
  let currentMarkPlanId = '';

  let closing = false;
  const close = (after = () => {}) => {
    if (closing) return;
    closing = true;
    panel.style.transition = 'transform 0.2s ease-in, opacity 0.2s ease-in';
    panel.style.opacity = '0';
    panel.style.transform = 'translate3d(0, 0, 0) scale(0.95)';
    overlay.classList.add('closing');
    window.setTimeout(() => {
      overlay.remove();
      after();
    }, 220);
  };
  const showStatus = (message, tone = '') => {
    status.hidden = false;
    status.className = `small inline-status cooked-meal-status ${tone}`.trim();
    status.textContent = message;
  };
  const clearStatus = () => {
    status.hidden = true;
    status.textContent = '';
  };
  const resetAnalyzeButton = () => {
    analyzeBtn.textContent = '生成建议';
    analyzeBtn.disabled = false;
    analyzeBtn.onclick = analyze;
    addActionBtn.hidden = true;
  };

  function renderStart() {
    const planRows = getTodayPlanRecipeRows(pack);
    startHost.innerHTML = `
      <section class="cooked-meal-start-block">
        <div class="cooked-meal-start-title">从计划记录</div>
        <div class="cooked-meal-plan-list">
          ${planRows.length
            ? planRows.slice(0, 5).map(({ recipe }) => `
              <button type="button" class="cooked-meal-plan-chip" data-recipe-id="${escapeOptionAttr(recipe.id)}">${escapeHtml(recipe.name)}</button>
            `).join('')
            : '<span class="cooked-meal-muted">今天还没有待完成的计划。</span>'}
        </div>
      </section>
      <section class="cooked-meal-start-block">
        <div class="cooked-meal-start-title">直接选食材</div>
        <button type="button" class="wx-mini-btn cooked-meal-select-btn" id="cookedMealPickStock">直接选库存食材</button>
      </section>
    `;
    startHost.querySelectorAll('.cooked-meal-plan-chip').forEach(btn => {
      btn.onclick = () => {
        const recipe = recipes.find(r => r.id === btn.dataset.recipeId);
        if (recipe) useRecipeForCookedMeal(recipe, { source: '来自计划', markPlan: true });
      };
    });
    startHost.querySelector('#cookedMealPickStock')?.addEventListener('click', () => {
      clearStatus();
      currentRecipe = null;
      currentCandidates = [];
      currentPredictions = [];
      currentSourceLabel = '你手动选择库存食材。';
      currentMarkPlanId = '';
      renderInventoryPicker({ title: '直接选库存食材' });
    });
  }

  function recomputeAndRenderConfirm({ recipe = currentRecipe, candidates = currentCandidates, sourceLabel = currentSourceLabel, markPlanId = currentMarkPlanId } = {}) {
    const merged = mergeCookedMealCandidates(candidates);
    const predictions = decorateCookedPredictions(computeCookDeductions(merged, inv), merged);
    if (!predictions.length) {
      showStatus('没判断出用到哪些食材，可以直接从库存里选。', 'bad');
      renderInventoryPicker({ title: '直接选库存食材' });
      resetAnalyzeButton();
      return;
    }
    currentRecipe = recipe || null;
    currentCandidates = merged;
    currentPredictions = predictions;
    currentSourceLabel = sourceLabel || '确认后才会更新食材。';
    currentMarkPlanId = markPlanId || '';
    renderConfirm();
  }

  function renderConfirm() {
    const title = '可能用掉了这些';
    const subtitle = currentRecipe
      ? `按「${currentRecipe.name}」整理，你可以增删改，确认后才会更新库存。`
      : '你可以增删改，确认后才会更新库存。';
    const predictions = currentPredictions;
    resultHost.innerHTML = `
      <div class="cooked-meal-suggestion-head">
        <strong>${escapeHtml(title)}</strong>
        <span>${escapeHtml(subtitle)}</span>
      </div>
      <div class="cooked-meal-list">
        ${predictions.map((prediction, index) => {
          const isPiece = prediction.unitType === UNIT_TYPE.PIECE;
          const unit = prediction.unit || prediction.match?.unit || '';
          const current = isPiece
            ? `当前 ${prediction.currentQty}${unit}`
            : `当前 ${GEAR_LABELS[gearInfo(prediction.currentGear).value] || '有'}`;
          const control = isPiece
            ? `<input class="cooked-meal-use" type="number" min="0" step="1" value="${escapeOptionAttr(String(prediction.suggestedQty || prediction.recipeQty || 1))}"><input class="cooked-meal-unit" value="${escapeOptionAttr(unit || '份')}" aria-label="单位">`
            : `<select class="cooked-meal-final-gear" aria-label="剩余档位">${[100, 75, 50, 25, 0].map(g => `<option value="${g}"${g === prediction.predictedGear ? ' selected' : ''}>剩余${GEAR_LABELS[g]}</option>`).join('')}</select>`;
          return `
            <div class="cooked-meal-row" data-index="${index}">
              <input type="checkbox" class="cooked-meal-check" checked>
              <span class="cooked-meal-main">
                <strong>${escapeHtml(prediction.match?.name || prediction.name)}</strong>
                <small>${escapeHtml(prediction.reason || '需确认')} · ${escapeHtml(current)}</small>
              </span>
              <span class="cooked-meal-control">${control}</span>
              <button type="button" class="cooked-meal-remove" aria-label="移除">×</button>
            </div>
          `;
        }).join('')}
      </div>
    `;
    resultHost.querySelectorAll('.cooked-meal-remove').forEach(btn => {
      btn.onclick = event => {
        event.preventDefault();
        event.stopPropagation();
        const row = btn.closest('.cooked-meal-row');
        const prediction = predictions[Number(row?.dataset.index)];
        const key = getCanonicalName(prediction?.match?.name || prediction?.name || '');
        currentCandidates = currentCandidates.filter(item => (getCanonicalName(item?.item || item?.name || '') !== key));
        if (!currentCandidates.length) {
          resultHost.innerHTML = '';
          showStatus('确认单已清空，可以直接选择食材。', '');
          renderInventoryPicker({ title: '直接选库存食材' });
        } else {
          recomputeAndRenderConfirm();
        }
      };
    });
    startHost.hidden = true;
    analyzeBtn.textContent = '更新库存';
    analyzeBtn.disabled = false;
    addActionBtn.hidden = false;
    addActionBtn.onclick = () => renderInventoryPicker({ title: '添加库存食材', append: true });
    analyzeBtn.onclick = () => {
      const rows = Array.from(resultHost.querySelectorAll('.cooked-meal-row'));
      const calibrations = rows.map(row => {
        if (!row.querySelector('.cooked-meal-check')?.checked) return null;
        const prediction = predictions[Number(row.dataset.index)];
        if (!prediction) return null;
        if (prediction.unitType === UNIT_TYPE.PIECE) {
          const useQty = Math.max(0, Math.round(Number(row.querySelector('.cooked-meal-use')?.value) || 0));
          const unit = String(row.querySelector('.cooked-meal-unit')?.value || prediction.unit || prediction.match?.unit || '').trim();
          if (useQty <= 0) return null;
          if (unit && prediction.match) prediction.match.unit = unit;
          return {
            match: prediction.match,
            name: prediction.name,
            unitType: UNIT_TYPE.PIECE,
            finalQty: Math.max(0, (Number(prediction.currentQty) || 0) - useQty)
          };
        }
        return {
          match: prediction.match,
          name: prediction.name,
          unitType: UNIT_TYPE.GEAR,
          finalGear: Number(row.querySelector('.cooked-meal-final-gear')?.value ?? prediction.predictedGear)
        };
      }).filter(Boolean);
      if (!calibrations.length) {
        showToast('没有选择要更新的食材', { tone: 'warning' });
        showStatus('至少勾选一样食材。', 'bad');
        return;
      }
      const shoppingCandidates = getCookShoppingCandidates({ calibrations });
      applyCookCalibration(inv, calibrations);
      showToast('已更新库存', { tone: 'success' });
      if (isDemoKitchenMode()) {
        setDemoStep('done');
        refreshDemoKitchenBanner({ onRoute });
      }
      if (currentMarkPlanId) markTodayPlanCooked(currentMarkPlanId);
      else if (currentRecipe?.id) markRecipeCookedKeepPlan(currentRecipe.id);
      close(() => showCookCompleteFeedback({
        updated: true,
        candidates: shoppingCandidates,
        onClose: onRoute,
        onShoppingAdded: onRoute
      }));
    };
  }

  function renderInventoryPicker({ title = '选择库存食材', append = false } = {}) {
    const available = (inv || [])
      .filter(item => item && isInventoryAvailable(item))
      .filter(item => mergeCookedMealCandidates([{ item: item.name }]).length)
      .sort((a, b) => Number(isImpromptuCandidate(b)) - Number(isImpromptuCandidate(a)) || String(a.name).localeCompare(String(b.name), 'zh-Hans-CN'));
    const picker = document.createElement('div');
    picker.className = 'cooked-meal-picker';
    picker.innerHTML = `
      <div class="cooked-meal-picker-head">
        <strong>${escapeHtml(title)}</strong>
        <input class="cooked-meal-picker-filter" type="search" placeholder="搜索库存食材">
      </div>
      <div class="cooked-meal-picker-list">
        ${available.length
          ? available.map(item => `
            <button type="button" class="cooked-meal-stock-option${isImpromptuCandidate(item) ? ' is-suggested' : ''}" data-name="${escapeOptionAttr(item.name)}">
              <span>${escapeHtml(item.name)}</span>
              <small>${escapeHtml(item.qty ? `${item.qty}${item.unit || ''}` : item.unit || '')}</small>
            </button>
          `).join('')
          : '<span class="cooked-meal-muted">当前没有可扣减的库存食材。</span>'}
      </div>
    `;
    if (append && currentPredictions.length) {
      resultHost.querySelector('.cooked-meal-picker')?.remove();
      resultHost.appendChild(picker);
    } else {
      startHost.hidden = true;
      addActionBtn.hidden = true;
      resultHost.innerHTML = '';
      resultHost.appendChild(picker);
    }
    const filter = picker.querySelector('.cooked-meal-picker-filter');
    const refreshFilter = () => {
      const q = getCanonicalName(filter.value.trim()) || filter.value.trim();
      picker.querySelectorAll('.cooked-meal-stock-option').forEach(btn => {
        const name = btn.dataset.name || '';
        const canonical = getCanonicalName(name) || '';
        btn.hidden = q && !name.includes(q) && !canonical.includes(q);
      });
    };
    filter.oninput = refreshFilter;
    picker.querySelectorAll('.cooked-meal-stock-option').forEach(btn => {
      btn.onclick = () => {
        const item = available.find(x => x.name === btn.dataset.name);
        if (!item) return;
        const next = {
          item: item.name,
          qty: 1,
          unit: item.unit || guessKitchenUnit(item.name) || '份',
          reason: '你手动添加',
          matchName: item.name
        };
        currentCandidates = mergeCookedMealCandidates(currentCandidates, [next]);
        recomputeAndRenderConfirm({
          recipe: currentRecipe,
          candidates: currentCandidates,
          sourceLabel: currentSourceLabel || '你手动选择库存食材。',
          markPlanId: currentMarkPlanId
        });
      };
    });
    filter.focus();
  }

  function useRecipeForCookedMeal(recipe, { source = '来自菜谱', markPlan = false } = {}) {
    clearStatus();
    const candidates = getRecipeCoreItems(recipe, pack).map(item => ({ ...item, reason: source }));
    recomputeAndRenderConfirm({
      recipe,
      candidates,
      sourceLabel: `${source}，确认后才会更新食材。`,
      markPlanId: markPlan ? recipe.id : ''
    });
  }

  async function analyze() {
    const text = textInput.value.trim();
    resultHost.innerHTML = '';
    if (!text) {
      showStatus('先写一下刚吃了什么。', 'bad');
      textInput.focus();
      return;
    }
    clearStatus();
    analyzeBtn.disabled = true;
    analyzeBtn.textContent = '正在分析...';
    const recipe = matchCookedMealRecipe(text, recipes);
    let sourceLabel = '';
    let candidates = [];

    if (recipe) {
      candidates = getRecipeCoreItems(recipe, pack).map(item => ({ ...item, reason: '来自菜谱' }));
      sourceLabel = '来自菜谱，确认后才会更新食材。';
    }

    let predictions = computeCookDeductions(candidates, inv);
    if (!predictions.length) {
      const localCandidates = buildLocalCookedMealCandidates(text, inv);
      predictions = computeCookDeductions(localCandidates, inv);
      if (predictions.length) {
        candidates = localCandidates;
        sourceLabel = '根据你刚刚提到的食材匹配库存。';
      }
    }

    if (!predictions.length) {
      try {
        const aiResult = await withTimeout(callAiForCookedMeal(text, inv, recipes), 22000, 'AI 响应超时');
        const normalized = normalizeAiCookedMealResult(aiResult, inv);
        const aiCandidates = mergeCookedMealCandidates(normalized.candidates);
        predictions = computeCookDeductions(aiCandidates, inv);
        if (predictions.length) {
          candidates = aiCandidates;
          sourceLabel = 'AI 辅助整理，仍需你确认。';
        }
      } catch (err) {
        showStatus(`${formatAiErrorMessage(err)} 已尝试用本地规则匹配。`, 'bad');
      }
    }

    if (!predictions.length) {
      analyzeBtn.disabled = false;
      analyzeBtn.textContent = '生成建议';
      if (status.hidden) showStatus('没判断出用到哪些食材，可以直接从库存里选。', 'bad');
      renderInventoryPicker({ title: '直接选库存食材' });
      return;
    }

    const decorated = decorateCookedPredictions(predictions, candidates);
    clearStatus();
    currentRecipe = recipe || null;
    currentCandidates = mergeCookedMealCandidates(candidates);
    currentPredictions = decorated;
    currentSourceLabel = sourceLabel || '确认后才会更新食材。';
    currentMarkPlanId = '';
    renderConfirm();
  }

  analyzeBtn.onclick = analyze;
  panel.querySelector('.km-modal-close').onclick = () => close();
  panel.querySelector('#cookedMealCancel').onclick = () => close();
  overlay.onclick = event => { if (event.target === overlay) close(); };
  textInput.onkeydown = event => {
    if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') analyze();
  };
  renderStart();
  requestAnimationFrame(() => overlay.classList.add('open'));
  setTimeout(() => textInput.focus(), 80);
}
