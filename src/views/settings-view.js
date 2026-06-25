import { S, todayISO } from '../storage.js?v=219';
import { CUSTOM_AI } from '../config.js?v=219';
import { buildKitchenBackup, downloadJsonFile, importKitchenBackup, loadOverlay, saveOverlay, validateKitchenBackup } from '../backup.js?v=219';
import { setInlineStatus, escapeHtml, showToast } from '../components/status.js?v=219';
import { getSavedTheme, saveTheme } from '../theme.js?v=219';

// 渐进式展现：「高级与数据设置」面板的展开状态，记忆在模块作用域（同次会话内保持）。
let advancedOpen = false;

const THEME_OPTIONS = [
  { key: 'system', label: '跟随系统' },
  { key: 'light', label: '浅色' },
  { key: 'dark', label: '深色' }
];

// 与 recipes-view.js 中迁出来的同名工具一致：合并外部 overlay 时保留当前用户已有的菜谱补丁，避免覆盖。
function mergeRecipeOverlay(currentOverlay, incomingOverlay) {
  const current = currentOverlay || {};
  const incoming = incomingOverlay || {};
  const next = {
    ...current,
    recipes: { ...(current.recipes || {}) },
    recipe_ingredients: { ...(current.recipe_ingredients || {}) },
    deletes: { ...(current.deletes || {}) }
  };
  const conflicts = []; const imported = [];
  const incomingIds = new Set([
    ...Object.keys(incoming.recipes || {}),
    ...Object.keys(incoming.recipe_ingredients || {}),
    ...Object.keys(incoming.deletes || {})
  ]);
  const hasCurrentPatch = id =>
    Object.prototype.hasOwnProperty.call(current.recipes || {}, id)
    || Object.prototype.hasOwnProperty.call(current.recipe_ingredients || {}, id)
    || Object.prototype.hasOwnProperty.call(current.deletes || {}, id);
  incomingIds.forEach(id => {
    if (hasCurrentPatch(id)) { conflicts.push(id); return; }
    if (Object.prototype.hasOwnProperty.call(incoming.recipes || {}, id)) next.recipes[id] = incoming.recipes[id];
    if (Object.prototype.hasOwnProperty.call(incoming.recipe_ingredients || {}, id)) next.recipe_ingredients[id] = incoming.recipe_ingredients[id];
    if (Object.prototype.hasOwnProperty.call(incoming.deletes || {}, id)) next.deletes[id] = incoming.deletes[id];
    imported.push(id);
  });
  return { overlay: next, conflicts, imported };
}

export function renderSettings() {
  const s = S.load(S.keys.settings, { apiUrl: '', apiKey: '', model: '' });
  const aiProviderMode = s.aiProviderMode === 'byok' ? 'byok' : 'cloud';
  const displayUrl = s.apiUrl || CUSTOM_AI.URL;
  const displayKey = s.apiKey || '';
  const displayModel = s.model || CUSTOM_AI.MODEL;

  const libMode = s.recipeLibraryMode === 'full' ? 'full' : 'curated';

  const theme = getSavedTheme();
  const themeSeg = THEME_OPTIONS.map(o =>
    `<button type="button" class="settings-seg-btn${o.key === theme ? ' is-active' : ''}" data-theme="${o.key}">${o.label}</button>`
  ).join('');

  const div = document.createElement('div');
  div.className = 'settings-page';
  div.innerHTML = `
    <h2 class="section-title">我的</h2>
    <div id="settingsStatus" class="small inline-status" hidden></div>

    <!-- 区块 A：通用与外观（高频核心偏好，默认展开） -->
    <div class="settings-group-label">通用与外观</div>
    <div class="settings-group">
      <div class="settings-row">
        <div class="settings-row-main">
          <span class="settings-row-title">外观主题</span>
          <span class="settings-row-sub">浅色 / 深色 / 跟随系统</span>
        </div>
        <div class="settings-seg" id="themeSeg" role="tablist" aria-label="外观主题">${themeSeg}</div>
      </div>
      <div class="settings-row">
        <div class="settings-row-main">
          <span class="settings-row-title">菜谱多少</span>
          <span class="settings-row-sub">精简日常更聚焦；完整传统菜谱更全</span>
        </div>
        <select id="sLibMode" class="settings-input settings-select">
          <option value="curated" ${libMode === 'curated' ? 'selected' : ''}>精简日常（推荐）</option>
          <option value="full" ${libMode === 'full' ? 'selected' : ''}>完整传统菜谱</option>
        </select>
      </div>
      <div class="settings-row">
        <div class="settings-row-main">
          <span class="settings-row-title">使用提示</span>
          <span class="settings-row-sub">回到今日页，看记食材、推荐、买菜和做完后的轻提示。</span>
        </div>
        <a class="btn settings-tips-link" href="#today">查看使用提示</a>
      </div>
    </div>

    <!-- 渐进式展现：低频 / 极客配置统一收进可折叠面板 -->
    <button type="button" class="settings-advanced-toggle" id="advToggle" aria-expanded="false" aria-controls="advPanel">
      <span id="advToggleLabel">展开高级与数据设置</span>
      <span class="settings-adv-chevron" aria-hidden="true">⌄</span>
    </button>

    <div class="settings-advanced-panel" id="advPanel" hidden>
      <!-- 区块 B：AI 模型配置 -->
      <div class="settings-group-label">🤖 AI 模型配置</div>
      <div class="settings-group">
        <div class="settings-row is-stacked">
          <div class="settings-row-main">
            <span class="settings-row-title">AI 使用方式</span>
            <span class="settings-row-sub">默认走内置服务；高级用户也可以继续使用自己的 Key。</span>
          </div>
          <div class="settings-ai-mode" role="radiogroup" aria-label="AI 使用方式">
            <label class="settings-ai-option${aiProviderMode === 'cloud' ? ' is-active' : ''}">
              <input type="radio" name="aiProviderMode" value="cloud" ${aiProviderMode === 'cloud' ? 'checked' : ''}>
              <span>
                <strong>使用内置 AI 服务（推荐）</strong>
                <small>不用在浏览器里配置 API Key。</small>
              </span>
            </label>
            <label class="settings-ai-option${aiProviderMode === 'byok' ? ' is-active' : ''}">
              <input type="radio" name="aiProviderMode" value="byok" ${aiProviderMode === 'byok' ? 'checked' : ''}>
              <span>
                <strong>使用自己的 API Key（高级）</strong>
                <small>Key 只保存在本机浏览器，备份默认不含 Key。</small>
              </span>
            </label>
          </div>
        </div>
        <div class="settings-row is-stacked" id="cloudAiBox">
          <div class="settings-row-main">
            <span class="settings-row-title">当前使用内置 AI 服务。</span>
            <span class="settings-row-sub">小票图片、菜名和你主动提交的文字会发送到后端 AI 服务；厨房库存仍保存在本地浏览器。</span>
          </div>
        </div>
        <div class="settings-byok-fields" id="byokAiBox">
        <div class="settings-row">
          <div class="settings-row-main">
            <span class="settings-row-title">快速预设</span>
            <span class="settings-row-sub">一键填入常见服务商端点</span>
          </div>
          <select id="sPreset" class="settings-input settings-select">
            <option value="">自定义…</option>
            <option value="silicon">SiliconFlow（硅基流动）</option>
            <option value="groq">Groq</option>
            <option value="openai">OpenAI</option>
          </select>
        </div>
        <div class="settings-row is-stacked">
          <div class="settings-row-main"><span class="settings-row-title">API 地址</span><span class="settings-row-sub">兼容 OpenAI 协议的端点（含本地 Ollama）</span></div>
          <input id="sUrl" class="settings-input" value="${escapeHtml(displayUrl)}" placeholder="https://…/v1/chat/completions">
        </div>
        <div class="settings-row is-stacked">
          <div class="settings-row-main"><span class="settings-row-title">模型名称</span><span class="settings-row-sub">如 gpt-4o、llama3、qwen2.5 等 Tag</span></div>
          <input id="sModel" class="settings-input" value="${escapeHtml(displayModel)}" placeholder="模型 / Tag 名称">
        </div>
        <div class="settings-row is-stacked">
          <div class="settings-row-main"><span class="settings-row-title">API Key</span><span class="settings-row-sub">仅保存在本地浏览器，备份默认不含 Key</span></div>
          <input id="sKey" class="settings-input" type="password" value="${escapeHtml(displayKey)}" placeholder="sk-…（本地 Ollama 可留空）">
        </div>
        <div class="settings-row is-action">
          <a class="btn ok" id="saveSet">保存 AI 设置</a>
        </div>
        </div>
      </div>

      <!-- 区块 C：数据管理 -->
      <div class="settings-group-label">💾 数据管理</div>
      <div class="settings-group">
        <div class="settings-row is-stacked">
          <div class="settings-row-main"><span class="settings-row-title">菜谱补丁</span><span class="settings-row-sub">仅含你对菜谱的新增 / 编辑 / 删除，便于多设备同步</span></div>
          <div class="settings-backup-actions">
            <button type="button" class="btn ok" id="exportRecipeOverlay">导出菜谱备份</button>
            <label class="btn"><input type="file" id="importRecipeOverlay" accept="application/json,.json" hidden>恢复 / 导入菜谱</label>
          </div>
        </div>
        <div class="settings-row is-stacked">
          <div class="settings-row-main"><span class="settings-row-title">数据备份</span><span class="settings-row-sub">导出当前厨房数据，换设备或清缓存前可以先保存一份。</span></div>
          <div class="settings-backup-actions">
            <button type="button" class="btn ok" id="exportKitchenBackup">导出备份</button>
            <label class="btn"><input type="file" id="importKitchenBackup" accept="application/json,.json" hidden>导入备份</label>
          </div>
        </div>
        <div class="settings-row is-stacked">
          <div class="settings-row-main"><span class="settings-row-title">清除缓存</span><span class="settings-row-sub">清理离线缓存并刷新，不会删除你的厨房数据</span></div>
          <div class="settings-backup-actions">
            <button type="button" class="btn" id="clearCacheBtn">清除缓存并刷新</button>
          </div>
        </div>
      </div>

      <!-- 区块 D：菜谱库精简报告（只读，低频查看） -->
      <div class="settings-group-label">🗂️ 菜谱库精简报告</div>
      <div class="settings-group" id="curationReport">
        <p class="settings-group-note">正在加载报告…</p>
      </div>
    </div>
  `;

  // ── 外观主题分段控件：点选即时生效，无需刷新 ──
  const themeSegEl = div.querySelector('#themeSeg');
  themeSegEl.querySelectorAll('.settings-seg-btn').forEach(btn => {
    btn.onclick = () => {
      saveTheme(btn.dataset.theme);
      themeSegEl.querySelectorAll('.settings-seg-btn').forEach(b => b.classList.toggle('is-active', b === btn));
    };
  });

  // ── 渐进式展现：展开 / 收起「高级与数据设置」 ──
  const advToggle = div.querySelector('#advToggle');
  const advPanel = div.querySelector('#advPanel');
  const advLabel = div.querySelector('#advToggleLabel');
  let curationLoaded = false;
  const setAdvanced = (open) => {
    advancedOpen = open;
    advPanel.hidden = !open;
    advToggle.setAttribute('aria-expanded', open ? 'true' : 'false');
    advLabel.textContent = open ? '收起高级与数据设置' : '展开高级与数据设置';
    if (open && !curationLoaded) {
      curationLoaded = true;
      loadCurationReport(div.querySelector('#curationReport'), libMode);
    }
  };
  advToggle.onclick = () => setAdvanced(!advancedOpen);

  const presets = {
    silicon: { url: 'https://api.siliconflow.cn/v1/chat/completions', model: 'Qwen/Qwen2.5-7B-Instruct' },
    groq: { url: 'https://api.groq.com/openai/v1/chat/completions', model: 'llama3-70b-8192' },
    openai: { url: 'https://api.openai.com/v1/chat/completions', model: 'gpt-4o' }
  };
  div.querySelector('#sPreset').onchange = (e) => {
    const val = e.target.value;
    if (presets[val]) { div.querySelector('#sUrl').value = presets[val].url; div.querySelector('#sModel').value = presets[val].model; }
  };
  const cloudAiBox = div.querySelector('#cloudAiBox');
  const byokAiBox = div.querySelector('#byokAiBox');
  const syncAiModeUi = (mode) => {
    const isByok = mode === 'byok';
    cloudAiBox.hidden = isByok;
    byokAiBox.hidden = !isByok;
    div.querySelectorAll('.settings-ai-option').forEach(label => {
      label.classList.toggle('is-active', label.querySelector('input')?.value === mode);
    });
  };
  syncAiModeUi(aiProviderMode);
  div.querySelectorAll('input[name="aiProviderMode"]').forEach(input => {
    input.onchange = () => {
      const mode = input.value === 'byok' ? 'byok' : 'cloud';
      const currentSettings = S.load(S.keys.settings, {});
      S.save(S.keys.settings, { ...currentSettings, aiProviderMode: mode });
      syncAiModeUi(mode);
      const statusEl = div.querySelector('#settingsStatus');
      setInlineStatus(statusEl, mode === 'cloud' ? '已切换为内置 AI 服务。' : '已切换为自带 API Key 模式。', 'ok');
    };
  });
  div.querySelector('#sLibMode').onchange = (e) => {
    const mode = e.target.value === 'full' ? 'full' : 'curated';
    const currentSettings = S.load(S.keys.settings, {});
    S.save(S.keys.settings, { ...currentSettings, recipeLibraryMode: mode });
    if (typeof window.invalidatePackCache === 'function') window.invalidatePackCache();
    const statusEl = div.querySelector('#settingsStatus');
    setInlineStatus(statusEl, `已切换为${mode === 'full' ? '完整原始' : '精简日常'}菜谱库，正在刷新…`, 'ok');
    setTimeout(() => location.reload(), 800);
  };
  div.querySelector('#saveSet').onclick = () => {
    const currentSettings = S.load(S.keys.settings, {});
    const newS = {
      ...currentSettings,
      aiProviderMode: 'byok',
      apiUrl: div.querySelector('#sUrl').value.trim(),
      apiKey: div.querySelector('#sKey').value.trim(),
      model: div.querySelector('#sModel').value.trim()
    };
    S.save(S.keys.settings, newS);
    const statusEl = div.querySelector('#settingsStatus');
    setInlineStatus(statusEl, '已保存，刷新后生效。', 'ok');
    setTimeout(() => location.reload(), 1200);
  };
  // 菜谱补丁 — 从原菜谱页迁来的「导出 / 导入」低频功能。
  div.querySelector('#exportRecipeOverlay').onclick = () => {
    downloadJsonFile(loadOverlay(), `kitchen-overlay-${todayISO()}.json`);
  };
  div.querySelector('#importRecipeOverlay').onchange = (e) => {
    const file = e.target.files[0]; if (!file) return;
    const reader = new FileReader();
    const statusEl = div.querySelector('#settingsStatus');
    reader.onload = () => {
      try {
        const inc = JSON.parse(reader.result);
        const result = mergeRecipeOverlay(loadOverlay(), inc);
        saveOverlay(result.overlay);
        window.invalidatePackCache?.();
        const conflictText = result.conflicts.length ? `，${result.conflicts.length} 个冲突已保留当前版本` : '';
        setInlineStatus(statusEl, `导入成功：新增 ${result.imported.length} 项${conflictText}。页面将刷新。`, 'ok');
        setTimeout(() => location.reload(), 1200);
      } catch (err) {
        setInlineStatus(statusEl, '菜谱导入失败：' + (err.message || err), 'bad');
      }
    };
    reader.readAsText(file);
  };
  div.querySelector('#exportKitchenBackup').onclick = () => {
    downloadJsonFile(buildKitchenBackup(), `kitchenmanager-backup-${todayISO()}.json`);
    setInlineStatus(div.querySelector('#settingsStatus'), '备份已导出。', 'ok');
    showToast('备份已导出', { tone: 'success' });
  };
  div.querySelector('#importKitchenBackup').onchange = e => {
    const file = e.target.files[0]; if (!file) return;
    const reader = new FileReader();
    const statusEl = div.querySelector('#settingsStatus');
    reader.onload = () => {
      try {
        const backup = validateKitchenBackup(String(reader.result || ''));
        if (!window.confirm('导入会覆盖当前厨房数据，确定继续吗？')) {
          e.target.value = '';
          return;
        }
        importKitchenBackup(backup);
        setInlineStatus(statusEl, '备份已导入，页面将刷新。', 'ok');
        showToast('备份已导入', { tone: 'success' });
        setTimeout(() => location.reload(), 1200);
      }
      catch (err) {
        setInlineStatus(statusEl, err.message || '备份文件无法读取', 'bad');
        showToast('备份导入失败', { tone: 'error' });
      }
    };
    reader.onerror = () => {
      setInlineStatus(statusEl, '备份文件无法读取', 'bad');
      showToast('备份导入失败', { tone: 'error' });
    };
    reader.readAsText(file);
  };

  // 清除缓存：清理 Service Worker 离线缓存并刷新，绝不触碰 localStorage 里的厨房数据。
  div.querySelector('#clearCacheBtn').onclick = async () => {
    const statusEl = div.querySelector('#settingsStatus');
    setInlineStatus(statusEl, '正在清理离线缓存…', 'info');
    try {
      if (window.caches && caches.keys) {
        const names = await caches.keys();
        await Promise.all(names.map(n => caches.delete(n)));
      }
      if (navigator.serviceWorker && navigator.serviceWorker.getRegistrations) {
        const regs = await navigator.serviceWorker.getRegistrations();
        await Promise.all(regs.map(r => r.unregister()));
      }
      setInlineStatus(statusEl, '缓存已清除，正在刷新…', 'ok');
      setTimeout(() => location.reload(true), 700);
    } catch (err) {
      setInlineStatus(statusEl, '清除缓存失败：' + (err.message || err), 'bad');
    }
  };

  // 恢复上次的「高级设置」展开状态（同次会话内记忆）。菜谱库精简报告随面板首次展开懒加载。
  setAdvanced(advancedOpen);

  return div;
}

async function loadCurationReport(container, libMode) {
  if (!container) return;
  const fetchJson = async (file) => {
    const res = await fetch(new URL(file, location).href, { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json();
  };

  let removedData, needingData;
  try {
    [removedData, needingData] = await Promise.all([
      fetchJson('./data/recipe-curation-removed.json'),
      fetchJson('./data/recipes-needing-completion.json')
    ]);
  } catch (e) {
    container.innerHTML = '<p class="meta">暂无精简报告。</p>';
    return;
  }

  const removed = Array.isArray(removedData?.removed) ? removedData.removed : [];
  const needing = Array.isArray(needingData?.items) ? needingData.items : [];
  const modeLabel = libMode === 'full' ? '完整库' : '精简库';

  const removedRow = (r) => `
    <li class="curation-item">
      <div class="curation-name">${escapeHtml(r.name || '未命名')}</div>
      <div class="curation-meta small">${escapeHtml(r.reason || '')}</div>
      ${r.duplicateOf ? `<div class="curation-tag small">重复于：${escapeHtml(r.duplicateOf)}</div>` : ''}
    </li>`;

  const needRow = (n) => {
    const missing = Array.isArray(n.missing) && n.missing.length ? n.missing.join('、') : '';
    const prio = { high: '高', medium: '中', low: '低' }[n.suggestedPriority] || '';
    return `
    <li class="curation-item">
      <div class="curation-name">${escapeHtml(n.name || '未命名')}${prio ? `<span class="curation-prio curation-prio-${escapeHtml(n.suggestedPriority || '')}">${prio}优先</span>` : ''}</div>
      <div class="curation-meta small">${escapeHtml(n.reason || '')}</div>
      ${missing ? `<div class="curation-tag small">待补：${escapeHtml(missing)}</div>` : ''}
    </li>`;
  };

  container.innerHTML = `
    <p class="meta">当前菜谱库模式：<strong>${modeLabel}</strong></p>
    <p class="meta">已移出主库：<strong>${removed.length}</strong> 道 · 待补全日常菜：<strong>${needing.length}</strong> 道</p>
    <details class="curation-details">
      <summary>已移出主库（${removed.length}）</summary>
      ${removed.length ? `<ul class="curation-list">${removed.map(removedRow).join('')}</ul>` : '<p class="meta">无</p>'}
    </details>
    <details class="curation-details">
      <summary>待补全日常菜（${needing.length}）</summary>
      ${needing.length ? `<ul class="curation-list">${needing.map(needRow).join('')}</ul>` : '<p class="meta">无</p>'}
    </details>
    <p class="meta">仅供查看：列出哪些菜被移出主库、原因，以及哪些日常菜还需要补做法。<a href="./data/recipe-curation-summary.md" target="_blank" rel="noopener">查看完整报告</a></p>
  `;
}
