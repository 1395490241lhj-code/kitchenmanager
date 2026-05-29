import { S, todayISO } from '../storage.js?v=171';
import { CUSTOM_AI } from '../config.js?v=171';
import { DATA_SCHEMA_VERSION } from '../migrations.js?v=171';
import { buildKitchenBackup, downloadJsonFile, restoreKitchenBackup } from '../backup.js?v=171';
import { setInlineStatus, escapeHtml } from '../components/status.js?v=171';

export function renderSettings() {
  const s = S.load(S.keys.settings, { apiUrl: '', apiKey: '', model: '' });
  const displayUrl = s.apiUrl || CUSTOM_AI.URL;
  const displayKey = s.apiKey || '';
  const displayModel = s.model || CUSTOM_AI.MODEL;

  const libMode = s.recipeLibraryMode === 'full' ? 'full' : 'curated';

  const div = document.createElement('div');
  div.innerHTML = `
    <h2 class="section-title">设置</h2>
    <div id="settingsStatus" class="small inline-status" hidden></div>
    <div class="section-title home-section-title"><span>菜谱库</span></div>
    <div class="card">
      <div class="setting-group">
        <label>菜谱库范围</label>
        <select id="sLibMode">
          <option value="curated" ${libMode === 'curated' ? 'selected' : ''}>精简日常菜谱库（推荐）</option>
          <option value="full" ${libMode === 'full' ? 'selected' : ''}>完整原始菜谱库</option>
        </select>
      </div>
      <p class="meta">精简库聚焦日常家常菜；完整库包含全部原始菜谱（含宴席、罕见菜）。无论哪种模式，你的自定义菜谱和修改都会保留。切换后页面会自动刷新。</p>
    </div>
    <div class="section-title home-section-title"><span>菜谱库精简报告</span></div>
    <div class="card" id="curationReport">
      <p class="meta">正在加载报告…</p>
    </div>
    <div class="section-title home-section-title"><span>AI 设置</span></div>
    <div class="card">
      <div class="setting-group">
        <label>快速预设</label>
        <select id="sPreset">
          <option value="">请选择...</option>
          <option value="silicon">SiliconFlow (硅基流动 - 推荐)</option>
          <option value="groq">Groq</option>
          <option value="openai">OpenAI</option>
        </select>
      </div>
      <hr class="settings-divider">
      <div class="setting-group"><label>API 地址</label><input id="sUrl" value="${displayUrl}"></div>
      <div class="setting-group"><label>模型名称</label><input id="sModel" value="${displayModel}"></div>
      <div class="setting-group"><label>API Key</label><input id="sKey" type="password" value="${displayKey}"></div>
      <p class="meta">API Key 只保存在本地浏览器；导出备份默认不包含 Key。</p>
      <div class="right"><a class="btn ok" id="saveSet">保存</a></div>
    </div>
    <div class="section-title home-section-title"><span>厨房备份</span></div>
    <div class="card backup-card">
      <p class="meta">导出会包含库存、今日计划、购物项、常做菜、安排记录、菜谱补丁和 AI 设置。当前数据结构版本：v${DATA_SCHEMA_VERSION}。</p>
      <div class="backup-actions">
        <button type="button" class="btn ok" id="exportKitchenBackup">导出整个厨房</button>
        <label class="btn"><input type="file" id="importKitchenBackup" accept="application/json,.json" hidden>导入整个厨房</label>
      </div>
    </div>
  `;

  const presets = {
    silicon: { url: 'https://api.siliconflow.cn/v1/chat/completions', model: 'Qwen/Qwen2.5-7B-Instruct' },
    groq: { url: 'https://api.groq.com/openai/v1/chat/completions', model: 'llama3-70b-8192' },
    openai: { url: 'https://api.openai.com/v1/chat/completions', model: 'gpt-4o' }
  };
  div.querySelector('#sPreset').onchange = (e) => {
    const val = e.target.value;
    if (presets[val]) { div.querySelector('#sUrl').value = presets[val].url; div.querySelector('#sModel').value = presets[val].model; }
  };
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
      apiUrl: div.querySelector('#sUrl').value.trim(),
      apiKey: div.querySelector('#sKey').value.trim(),
      model: div.querySelector('#sModel').value.trim()
    };
    S.save(S.keys.settings, newS);
    const statusEl = div.querySelector('#settingsStatus');
    setInlineStatus(statusEl, '已保存，刷新后生效。', 'ok');
    setTimeout(() => location.reload(), 1200);
  };
  div.querySelector('#exportKitchenBackup').onclick = () => {
    downloadJsonFile(buildKitchenBackup(), `kitchen-backup-${todayISO()}.json`);
  };
  div.querySelector('#importKitchenBackup').onchange = e => {
    const file = e.target.files[0]; if (!file) return;
    const reader = new FileReader();
    const statusEl = div.querySelector('#settingsStatus');
    reader.onload = () => {
      try {
        restoreKitchenBackup(JSON.parse(reader.result));
        setInlineStatus(statusEl, '备份已导入，页面将刷新。', 'ok');
        setTimeout(() => location.reload(), 1200);
      }
      catch (err) {
        setInlineStatus(statusEl, '导入失败：' + err.message, 'bad');
      }
    };
    reader.readAsText(file);
  };

  // 菜谱库精简报告（只读查看，不影响菜谱列表）
  loadCurationReport(div.querySelector('#curationReport'), libMode);

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
