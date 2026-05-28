import { S, todayISO } from '../storage.js?v=98';
import { CUSTOM_AI } from '../config.js?v=89';
import { DATA_SCHEMA_VERSION } from '../migrations.js?v=1';
import { buildKitchenBackup, downloadJsonFile, restoreKitchenBackup } from '../backup.js?v=2';
import { setInlineStatus } from '../components/status.js?v=1';

export function renderSettings() {
  const s = S.load(S.keys.settings, { apiUrl: '', apiKey: '', model: '' });
  const displayUrl = s.apiUrl || CUSTOM_AI.URL;
  const displayKey = s.apiKey || '';
  const displayModel = s.model || CUSTOM_AI.MODEL;

  const div = document.createElement('div');
  div.innerHTML = `
    <h2 class="section-title">设置</h2>
    <div id="settingsStatus" class="small inline-status" hidden></div>
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
  div.querySelector('#saveSet').onclick = () => {
    const newS = { apiUrl: div.querySelector('#sUrl').value.trim(), apiKey: div.querySelector('#sKey').value.trim(), model: div.querySelector('#sModel').value.trim() };
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
  return div;
}
