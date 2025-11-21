// v38 app.js - 增强中文小票识别 Prompt
const el = (sel, root=document) => root.querySelector(sel);
const els = (sel, root=document) => Array.from(root.querySelectorAll(sel));
const app = el('#app');
const todayISO = () => new Date().toISOString().slice(0,10);

// --- AI 配置 (用户自定义) ---
const CUSTOM_AI = {
  URL: "https://api.groq.com/openai/v1/chat/completions",
  KEY: "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",
  // 文本生成模型 (写菜谱、推荐)
  MODEL: "qwen/qwen-2.5-32b", 
  // 视觉模型 (识图) - Llama 3.2 Vision
  VISION_MODEL: "llama-3.2-11b-vision-preview" 
};

// -------- Storage --------
const S = {
  save(k, v){ localStorage.setItem(k, JSON.stringify(v)); },
  load(k, d){ try{ return JSON.parse(localStorage.getItem(k)) ?? d }catch{ return d } },
  keys: { inventory:'km_v19_inventory', plan:'km_v19_plan', overlay:'km_v19_overlay', settings:'km_v23_settings' }
};

// -------- Data Loading --------
async function loadBasePack(){
  const url = new URL('./data/sichuan-recipes.json', location).href + '?v=23';
  let pack = {recipes:[], recipe_ingredients:{}};
  try{ const res = await fetch(url, { cache:'no-store' }); if(res.ok) pack = await res.json(); }
  catch(e){ console.error('Base pack error', e); }
  const staticMethods = window.RECIPE_METHODS || {};
  if(pack.recipes){
    pack.recipes.forEach(r => {
      const method = staticMethods[r.id] || staticMethods[r.name];
      if(method) r.staticMethod = method;
    });
  }
  return pack;
}

// -------- Overlay Logic --------
function emptyOverlay(){ return {version:1, recipes:{}, recipe_ingredients:{}, deletes:{}}; }
function loadOverlay(){ return S.load(S.keys.overlay, emptyOverlay()); }
function saveOverlay(o){ S.save(S.keys.overlay, o); }
function genId(){ return 'u-' + Math.random().toString(36).slice(2,8) + '-' + Date.now().toString(36).slice(-4); }

function applyOverlay(base, overlay){
  const recipes = [];
  const ingMap = JSON.parse(JSON.stringify(base.recipe_ingredients || {}));
  const baseMap = new Map((base.recipes||[]).map(r => [r.id, {...r}]));
  const del = overlay.deletes || {};
  for(const [id, flag] of Object.entries(del)){ if(flag){ baseMap.delete(id); delete ingMap[id]; } }
  const ro = overlay.recipes || {};
  for(const [id, ov] of Object.entries(ro)){
    if(!baseMap.has(id)) {
      baseMap.set(id, {id, name: ov.name||'未命名', tags: ov.tags||[], method: ov.method||''});
    } else {
      const old = baseMap.get(id);
      const finalMethod = ov.method || old.staticMethod || old.method || '';
      baseMap.set(id, {...old, ...ov, method: finalMethod});
    }
  }
  const io = overlay.recipe_ingredients || {};
  for(const [id, list] of Object.entries(io)){ ingMap[id] = list.slice(); }
  for(const r of baseMap.values()) {
    if(!r.method && r.staticMethod) r.method = r.staticMethod;
    recipes.push(r);
  }
  for(const [id, ov] of Object.entries(ro)){
    if(/^u-/.test(id) && !recipes.find(x=>x.id===id)){
      recipes.push({id, name: ov.name||'自定义', tags: ov.tags||['自定义'], method: ov.method||''});
      if(!ingMap[id]) ingMap[id] = (io[id] || []);
    }
  }
  recipes.sort((a,b)=> a.name.localeCompare(b.name, 'zh-Hans-CN'));
  return {recipes, recipe_ingredients:ingMap};
}

// -------- Utils --------
const SEP_RE = /[，,、/;；|]+/;
function explodeCombinedItems(list){
  const out = [];
  for(const it of (list||[])){
    const name = (it.item||'').trim();
    if(!name) continue;
    const hasQty = typeof it.qty === 'number' && isFinite(it.qty);
    if(SEP_RE.test(name) && !hasQty){
      for(const n of name.split(SEP_RE).map(s=>s.trim()).filter(Boolean)){ out.push({ item:n, qty:null, unit:null }); }
    }else{ out.push(it); }
  }
  return out;
}
function guessShelfDays(name, unit){ const veg=['菜','叶','苔','苗','芹','香菜','葱','椒','瓜','番茄','西红柿','豆角','笋','蘑','菇','花菜','西兰花','菜花','茄子','豆腐','生菜','莴','空心菜','韭','蒜苗','青椒','黄瓜']; if(veg.some(w=>name.includes(w)))return 5; if(unit==='ml')return 30; if(unit==='pcs')return 14; return 7; }
function buildCatalog(pack){
  const units = {}, set = new Set();
  for(const list of Object.values(pack.recipe_ingredients||{})){
    for(const it of explodeCombinedItems(list)){ const n=(it.item||'').trim(); if(!n) continue; set.add(n); units[n]=units[n]||it.unit||'g'; }
  }
  return Array.from(set).sort().map(n=>({name:n, unit:units[n]||'g', shelf:guessShelfDays(n, units[n]||'g')}));
}
function loadInventory(catalog){ const inv=S.load(S.keys.inventory,[]); for(const i of inv){ if(!i.unit){i.unit=(catalog.find(c=>c.name===i.name)?.unit)||'g'} if(!i.shelf){i.shelf=(catalog.find(c=>c.name===i.name)?.shelf)||7} } return inv; }
function saveInventory(inv){ S.save(S.keys.inventory, inv); }
function daysBetween(a,b){ return Math.floor((new Date(b)-new Date(a))/86400000); }
function remainingDays(e){ const age=daysBetween(e.buyDate||todayISO(), todayISO()); return (+e.shelf||7)-age; }
function badgeFor(e){ const r=remainingDays(e); if(r<=1) return `<span class="kchip bad">即将过期 ${r}天</span>`; if(r<=3) return `<span class="kchip warn">优先消耗 ${r}天</span>`; return `<span class="kchip ok">新鲜 ${r}天</span>`; }
function upsertInventory(inv, e){ const i=inv.findIndex(x=>x.name===e.name && (x.kind||'raw')===(e.kind||'raw')); if(i>=0) inv[i]={...inv[i],...e}; else inv.push(e); saveInventory(inv); }
function addInventoryQty(inv, name, qty, unit, kind='raw'){ const e=inv.find(x=>x.name===name && (x.kind||'raw')===kind); if(e){ e.qty=(+e.qty||0)+qty; e.unit=unit||e.unit; e.buyDate=e.buyDate||todayISO(); } else { inv.push({name, qty, unit:unit||'g', buyDate:todayISO(), kind, shelf:guessShelfDays(name, unit||'g')}); } saveInventory(inv); }

// -------- AI Services --------
function getAiConfig() {
  const localSettings = S.load(S.keys.settings, {});
  const apiKey = CUSTOM_AI.KEY || localSettings.apiKey;
  const apiUrl = CUSTOM_AI.KEY ? CUSTOM_AI.URL : (localSettings.apiUrl || CUSTOM_AI.URL);
  // 混合模型选择逻辑
  const textModel = localSettings.model || CUSTOM_AI.MODEL;
  const visionModel = CUSTOM_AI.VISION_MODEL;
  
  if (!apiKey) throw new Error("未配置 API Key。请在设置页面配置。");
  return { apiKey, apiUrl, textModel, visionModel };
}

function cleanAiResponse(text) {
  let cleaned = text.replace(/<think>[\s\S]*?<\/think>/gi, '').trim();
  cleaned = cleaned.replace(/```json/gi, '').replace(/```/g, '').trim();
  return cleaned;
}
function extractJson(text) {
  const cleaned = cleanAiResponse(text);
  const match = cleaned.match(/\{[\s\S]*\}|\[[\s\S]*\]/);
  if (match) return match[0];
  return cleaned;
}

function compressImage(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.readAsDataURL(file);
    reader.onload = (e) => {
      const img = new Image();
      img.src = e.target.result;
      img.onload = () => {
        const canvas = document.createElement('canvas');
        const ctx = canvas.getContext('2d');
        let w = img.width, h = img.height;
        const MAX = 1024; 
        if (w > h) { if (w > MAX) { h *= MAX / w; w = MAX; } } 
        else { if (h > MAX) { w *= MAX / h; h = MAX; } }
        canvas.width = w; canvas.height = h;
        ctx.drawImage(img, 0, 0, w, h);
        resolve(canvas.toDataURL('image/jpeg', 0.7));
      };
      img.onerror = reject;
    };
    reader.onerror = reject;
  });
}

async function callAiService(prompt, imageBase64 = null) {
  const conf = getAiConfig();
  let messages = [];
  // 有图片时强制使用 Vision 模型，否则使用 Text 模型
  let activeModel = imageBase64 ? conf.visionModel : conf.textModel;

  if (imageBase64) {
    messages = [{
      role: "user",
      content: [
        { type: "text", text: prompt },
        { type: "image_url", image_url: { url: imageBase64 } }
      ]
    }];
  } else {
    messages = [{ role: "user", content: prompt }];
  }

  try {
    const res = await fetch(conf.apiUrl, {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${conf.apiKey}` },
      body: JSON.stringify({ model: activeModel, messages: messages, temperature: 0.3 }) // 识图时调低温度以提高准确率
    });
    if(!res.ok) {
        const err = await res.json();
        throw new Error(`API 错误 (${res.status}): ${err.error?.message || 'Unknown error'}`);
    }
    const data = await res.json();
    const rawText = data.choices?.[0]?.message?.content || "";
    return extractJson(rawText);
  } catch(e) { throw e; }
}

// 识别小票 (增强 Prompt)
async function recognizeReceipt(file) {
  const base64 = await compressImage(file);
  const prompt = `
  你是一个专业的中文收据识别助手。请仔细查看图片，识别出购物小票中的【食品/食材】列表。
  
  注意事项：
  1. **目标**：只提取食材（如蔬菜、肉类、水果、调料），忽略塑料袋、日用品等。
  2. **中文优化**：图片可能包含中文，请结合“厨房食材”的上下文进行OCR纠错。例如将“白来”修正为“白菜”，将“土”修正为“土豆”。
  3. **字段提取**：
     - name: 食材名称（去除“特价”、“打折”等修饰词）。
     - qty: 数量或重量。如果是重量（如 0.560 kg），提取数值 0.56。如果未标明，默认为 1。
     - unit: 单位（如 kg, g, 斤, 个, 包, 瓶）。若无单位则填 "pcs"。
  
  请严格只返回一个 JSON 数组，不要包含任何 Markdown 标记或解释文字：
  [{"name": "猪肉", "qty": 0.5, "unit": "kg"}, {"name": "青椒", "qty": 2, "unit": "pcs"}]
  `;
  
  const jsonStr = await callAiService(prompt, base64);
  return JSON.parse(jsonStr);
}

// 生成做法
async function callAiForMethod(recipeName, ingredients) {
  const ingStr = ingredients.map(i => i.item + (i.qty ? i.qty + (i.unit||'') : '')).join('、');
  const prompt = `请为川菜【${recipeName}】写一份详细的烹饪做法。已知用料：${ingStr}。请直接输出做法步骤，分条列出，简洁专业。不要输出思考过程。`;
  return await callAiService(prompt);
}

// 首页推荐
async function callCloudAI(pack, inv) {
  const invNames = inv.map(x => x.name).join('、');
  const recipeNames = (pack.recipes||[]).map(r=>r.name).join(',');
  const prompt = `我冰箱里有：【${invNames}】。我的菜谱库有：【${recipeNames}】。
  1. 挑选 3 道最适合现在做的菜（消耗库存）。2. 推荐 1 道创意菜。
  只返回 JSON：{ "local": [ {"name": "菜名", "reason": "理由"} ], "creative": { "name": "菜名", "reason": "理由", "ingredients": "用料" } }`;
  const jsonStr = await callAiService(prompt);
  return JSON.parse(jsonStr);
}

function getLocalRecommendations(pack, inv) {
  const invNames = inv.map(x => x.name.trim()).filter(Boolean);
  if (invNames.length === 0) return [];
  const scores = (pack.recipes || []).map(r => {
    const ingredients = explodeCombinedItems(pack.recipe_ingredients[r.id] || []);
    let matchCount = 0;
    ingredients.forEach(ing => { if((ing.item||'').trim() && invNames.some(n => n.includes(ing.item) || ing.item.includes(n))) matchCount++; });
    return { r, matchCount };
  });
  return scores.filter(s => s.matchCount > 0).sort((a,b) => b.matchCount - a.matchCount).slice(0, 6).map(s=>({r:s.r, reason:`本地匹配：含 ${s.matchCount} 种库存`}));
}

// -------- Renderers --------
function recipeCard(r, list, extraInfo=null){
  const card=document.createElement('div'); card.className='card';
  let topHtml = ''; if(extraInfo && extraInfo.isAi) { topHtml = `<div class="ai-badge">✨ AI 推荐</div>`; }
  card.innerHTML=`${topHtml}
    <div style="display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:8px;">
      <h3 style="margin:0;flex:1;cursor:pointer;text-decoration:underline" class="r-title">${r.name}</h3>
      <a class="kchip bad small btn-edit" data-id="${r.id}" style="cursor:pointer;margin-left:8px;">编辑</a>
    </div>
    <p class="meta">${(r.tags||[]).join(' / ')}</p>
    <div class="ings"></div>
    ${extraInfo && extraInfo.reason ? `<div class="ai-reason">${extraInfo.reason}</div>` : ''}
    <div class="controls"></div>`;
  card.querySelector('.r-title').onclick = () => location.hash = `#recipe:${r.id}`;
  if(!r.id.startsWith('creative-')) { card.querySelector('.btn-edit').onclick = (e) => { e.stopPropagation(); location.hash = `#recipe-edit:${r.id}`; }; } else { card.querySelector('.btn-edit').remove(); }
  const ul=document.createElement('ul'); ul.className='ing-list';
  const items = explodeCombinedItems(list||[]);
  const showItems = items.slice(0, 5);
  for(const it of showItems){ const q=(typeof it.qty==='number'&&isFinite(it.qty))?(it.qty+(it.unit||'')):''; const li=document.createElement('li'); li.textContent=q?`${it.item}  ${q}`:it.item; ul.appendChild(li); }
  if(items.length > 5) { const li=document.createElement('li'); li.textContent='...'; li.style.color='var(--muted)'; ul.appendChild(li); }
  card.querySelector('.ings').appendChild(ul);
  if(!r.id.startsWith('creative-')){
    const plan = new Set((S.load(S.keys.plan,[])).map(x=>x.id));
    const btn=document.createElement('a'); btn.href='javascript:void(0)'; btn.className='btn'; btn.textContent=plan.has(r.id)?'已加入计划':'加入购物计划';
    btn.onclick=()=>{ const p=S.load(S.keys.plan,[]); const i=p.findIndex(x=>x.id===r.id); if(i>=0) p.splice(i,1); else p.push({id:r.id, servings:1}); S.save(S.keys.plan,p); onRoute(); };
    card.querySelector('.controls').appendChild(btn);
    const detailBtn = document.createElement('a'); detailBtn.className='btn'; detailBtn.textContent='查看做法';
    detailBtn.onclick = () => location.hash = `#recipe:${r.id}`;
    card.querySelector('.controls').appendChild(detailBtn);
  }
  return card;
}

function renderRecipeDetail(id, pack) {
  const r = (pack.recipes||[]).find(x=>x.id===id);
  if(!r) return document.createTextNode('未找到菜谱');
  const ingList = pack.recipe_ingredients[id] || [];
  const items = explodeCombinedItems(ingList);
  const div = document.createElement('div'); div.className = 'detail-view';
  const methodContent = r.method ? `<div class="method-text">${r.method}</div>` : `<div class="small" style="margin-bottom:10px;padding:10px;border:1px dashed #555;border-radius:8px;">暂无详细做法。您可以点击下方按钮让 AI 生成，或者点击“编辑”手动录入书上的内容。</div><a class="btn ai" id="genMethodBtn">✨ 让 AI 自动生成做法</a>`;
  div.innerHTML = `<div style="margin-bottom:20px;display:flex;justify-content:space-between;"><a class="btn" onclick="history.back()">← 返回</a><a class="btn" href="#recipe-edit:${r.id}">✎ 编辑 / 录入</a></div><h2 style="color:#fff;font-size:24px;">${r.name}</h2><div class="tags meta" style="margin-bottom:24px;border-bottom:1px solid rgba(255,255,255,0.1);padding-bottom:10px;">${(r.tags||[]).join(' / ')}</div><div class="block"><h4>用料 Ingredients</h4><ul class="ing-list" style="columns:2; -webkit-columns:2; gap:20px;">${items.map(it => `<li><span style="color:#fff;">${it.item}</span> <span class="small" style="color:var(--accent);">${it.qty?it.qty+(it.unit||''):''}</span></li>`).join('')}</ul></div><div class="block"><h4>制作方法 Method</h4><div id="methodArea">${methodContent}</div></div>`;
  const genBtn = div.querySelector('#genMethodBtn');
  if(genBtn) {
    genBtn.onclick = async () => {
      genBtn.innerHTML = '<span class="spinner"></span> 正在生成...';
      try {
        const text = await callAiForMethod(r.name, items);
        const overlay = loadOverlay();
        overlay.recipes = overlay.recipes || {};
        overlay.recipes[id] = { ...(overlay.recipes[id]||{}), method: text };
        saveOverlay(overlay);
        div.querySelector('#methodArea').innerHTML = `<div class="method-text">${text}</div><div class="small ok" style="margin-top:10px">已保存到补丁</div>`;
      } catch(e) { alert('生成失败：' + e.message); genBtn.innerHTML = '✨ 让 AI 生成做法'; }
    };
  }
  return div;
}

function renderRecipes(pack){ const wrap = document.createElement('div'); wrap.innerHTML = `<div class="controls" style="margin-bottom:16px;gap:10px;"><input id="search" placeholder="搜菜谱..." style="flex:1;padding:10px;"><a class="btn ok" id="addBtn" style="padding:10px;">+ 新建</a><a class="btn" id="exportBtn">导出</a><label class="btn"><input type="file" id="importFile" hidden>导入</label></div><div class="grid" id="grid"></div>`; const grid = wrap.querySelector('#grid'); const map = pack.recipe_ingredients||{}; function draw(filter=''){ grid.innerHTML = ''; const f = filter.trim(); (pack.recipes||[]).filter(r => !f || r.name.includes(f)).forEach(r=>{ grid.appendChild(recipeCard(r, map[r.id])); }); } draw(); wrap.querySelector('#search').oninput = e => draw(e.target.value); wrap.querySelector('#addBtn').onclick = () => { const id = genId(); const overlay = loadOverlay(); overlay.recipes = overlay.recipes || {}; overlay.recipes[id] = { name: '新菜谱', tags: ['自定义'] }; overlay.recipe_ingredients = overlay.recipe_ingredients || {}; overlay.recipe_ingredients[id] = [{item:'', qty:null, unit:'g'}]; saveOverlay(overlay); location.hash = `#recipe-edit:${id}`; }; wrap.querySelector('#exportBtn').onclick = ()=>{ const blob = new Blob([JSON.stringify(loadOverlay(), null, 2)], {type:'application/json'}); const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'kitchen-overlay.json'; a.click(); }; wrap.querySelector('#importFile').onchange = (e)=>{ const file = e.target.files[0]; if(!file) return; const reader = new FileReader(); reader.onload = ()=>{ try{ const inc = JSON.parse(reader.result); const cur = loadOverlay(); const m = {...cur, recipes:{...cur.recipes,...(inc.recipes||{})}, recipe_ingredients:{...cur.recipe_ingredients,...(inc.recipe_ingredients||{})}, deletes:{...cur.deletes,...(inc.deletes||{})} }; saveOverlay(m); alert('导入成功'); location.reload(); }catch(err){ alert('导入失败'); } }; reader.readAsText(file); }; return wrap; }
function renderHome(pack){ const container = document.createElement('div'); const recDiv = document.createElement('div'); recDiv.innerHTML = `<div style="display:flex;justify-content:space-between;align-items:center;margin:24px 0 12px;"><h2 class="section-title" style="margin:0;border:none;padding:0">今日推荐</h2><a class="btn ai" id="callAiBtn">✨ 呼叫 AI 厨师</a></div><div id="rec-content" class="grid"></div>`; const recGrid = recDiv.querySelector('#rec-content'); container.appendChild(recDiv); const catalog = buildCatalog(pack); const inv = loadInventory(catalog); const localRecs = getLocalRecommendations(pack, inv); function showCards(list) { recGrid.innerHTML = ''; if(list.length===0) { recGrid.innerHTML = '<div class="small" style="grid-column:1/-1;padding:20px;text-align:center;">冰箱空空如也，快去“库存”添加食材，或点击右上角“呼叫 AI”获取灵感！</div>'; return; } const map = pack.recipe_ingredients || {}; list.forEach(item => { recGrid.appendChild(recipeCard(item.r, item.list || map[item.r.id], { reason: item.reason, isAi: item.isAi })); }); } showCards(localRecs); const aiBtn = recDiv.querySelector('#callAiBtn'); aiBtn.onclick = async () => { aiBtn.innerHTML = '<span class="spinner"></span> 思考中...'; aiBtn.style.opacity = '0.7'; try { const aiResult = await callCloudAI(pack, inv); const newCards = []; if(aiResult.local && Array.isArray(aiResult.local)){ aiResult.local.forEach(l => { const found = (pack.recipes||[]).find(r => r.name === l.name); if(found) newCards.push({ r: found, reason: l.reason, isAi: true }); }); } if(aiResult.creative){ const c = aiResult.creative; newCards.push({ r: { id: 'creative-'+Date.now(), name: c.name, tags: ['AI创意菜'] }, list: [{item: c.ingredients || '请根据描述自由发挥'}], reason: c.reason, isAi: true }); } if(newCards.length > 0) showCards(newCards); else alert('AI 虽然响应了，但没有给出有效推荐。'); } catch(e) { alert(e.message); } finally { aiBtn.innerHTML = '✨ 呼叫 AI 厨师'; aiBtn.style.opacity = '1'; } }; container.appendChild(renderInventory(pack)); return container; }
function renderSettings(){ const s = S.load(S.keys.settings, { apiUrl: '', apiKey: '', model: '' }); 
  const displayUrl = s.apiUrl || CUSTOM_AI.URL; const displayKey = s.apiKey || CUSTOM_AI.KEY; const displayModel = s.model || CUSTOM_AI.MODEL;
  const div = document.createElement('div'); div.innerHTML = `<h2 class="section-title">AI 设置</h2><div class="card"><div class="setting-group"><label>快速预设</label><select id="sPreset"><option value="">请选择...</option><option value="silicon">SiliconFlow (硅基流动)</option><option value="groq">Groq (Llama/Mixtral)</option><option value="groq-v">Groq (Llama-Vision)</option><option value="deepseek">DeepSeek</option><option value="openai">OpenAI</option></select></div><hr style="border:0;border-top:1px solid rgba(255,255,255,0.1);margin:16px 0"><div class="setting-group"><label>API 地址</label><input id="sUrl" value="${displayUrl}" placeholder="https://..."></div><div class="setting-group"><label>模型名称 (Model)</label><input id="sModel" value="${displayModel}"></div><div class="setting-group"><label>API Key</label><input id="sKey" type="password" value="${displayKey}" placeholder="sk-..."></div><div class="right"><a class="btn ok" id="saveSet">保存</a></div><p class="small" style="margin-top:20px;color:var(--muted)">* 当前配置：<br>文本模型: ${CUSTOM_AI.MODEL}<br>视觉模型: ${CUSTOM_AI.VISION_MODEL} (固定)</p></div>`; 
  const presets = { silicon: { url: 'https://api.siliconflow.cn/v1/chat/completions', model: 'Qwen/Qwen2.5-7B-Instruct' }, groq: { url: 'https://api.groq.com/openai/v1/chat/completions', model: 'llama3-70b-8192' }, "groq-v": { url: 'https://api.groq.com/openai/v1/chat/completions', model: 'llama-3.2-11b-vision-preview' }, deepseek: { url: 'https://api.deepseek.com/v1/chat/completions', model: 'deepseek-chat' }, openai: { url: 'https://api.openai.com/v1/chat/completions', model: 'gpt-4o' } }; 
  div.querySelector('#sPreset').onchange = (e) => { const val = e.target.value; if(presets[val]) { div.querySelector('#sUrl').value = presets[val].url; div.querySelector('#sModel').value = presets[val].model; } }; 
  div.querySelector('#saveSet').onclick = () => { const newS = { apiUrl: div.querySelector('#sUrl').value.trim(), apiKey: div.querySelector('#sKey').value.trim(), model: div.querySelector('#sModel').value.trim() }; S.save(S.keys.settings, newS); alert('设置已保存，下次刷新将优先使用此设置。'); }; return div; }

function renderInventory(pack){ const catalog=buildCatalog(pack); const inv=loadInventory(catalog); const wrap=document.createElement('div'); const h=document.createElement('h2'); h.className='section-title'; h.textContent='库存管理'; wrap.appendChild(h); const searchDiv = document.createElement('div'); searchDiv.className = 'controls'; searchDiv.style.marginBottom = '8px'; 
  searchDiv.innerHTML = `<div style="display:flex; gap:8px;"><input id="invSearch" placeholder="🔍 搜索库存..." style="flex:1;padding:10px;background:var(--card);border:1px solid rgba(255,255,255,0.1);"><label class="btn ai" style="padding:10px 12px; white-space:nowrap; cursor:pointer;"><input type="file" id="camInput" accept="image/*" capture="environment" hidden>📷 拍小票</label></div><div id="scanStatus" class="small" style="color:var(--accent); display:none; margin-top:4px;"></div>`; wrap.appendChild(searchDiv);
  const ctr=document.createElement('div'); ctr.className='controls'; ctr.innerHTML=`<div style="flex:1; min-width:120px;"><input id="addName" list="catalogList" placeholder="选择/搜索食材" style="width:100%;padding:10px;border-radius:8px;border:1px solid rgba(255,255,255,0.14);background:#0f1935;color:#fff;"><datalist id="catalogList">${catalog.map(c=>`<option value="${c.name}">`).join('')}</datalist></div><input id="addQty" type="number" step="1" placeholder="数量"><select id="addUnit"><option value="g">g</option><option value="ml">ml</option><option value="pcs">pcs</option></select><input id="addDate" type="date" value="${todayISO()}"><select id="addKind"><option value="raw">原材料</option><option value="semi">半成品</option></select><button id="addBtn" class="btn">入库</button>`; wrap.appendChild(ctr); ctr.querySelector('#addName').addEventListener('input', (e)=>{ const val = e.target.value.trim(); const match = catalog.find(c => c.name === val); if(match && match.unit){ ctr.querySelector('#addUnit').value = match.unit; } }); const tbl=document.createElement('table'); tbl.className='table'; tbl.innerHTML=`<thead><tr><th>食材</th><th>数量</th><th>单位</th><th>购买日期</th><th>保质</th><th>状态</th><th></th></tr></thead><tbody></tbody>`; wrap.appendChild(tbl);
  const scanStatus = searchDiv.querySelector('#scanStatus');
  searchDiv.querySelector('#camInput').onchange = async (e) => {
    const file = e.target.files[0]; if(!file) return;
    scanStatus.style.display = 'block'; scanStatus.innerHTML = '<span class="spinner"></span> 正在识别，请稍候...';
    try {
      const items = await recognizeReceipt(file);
      scanStatus.innerHTML = `✅ 识别成功！发现 ${items.length} 个物品，正在加入...`;
      let count = 0; for(const it of items) { if(!it.name) continue; let unit = it.unit || 'g'; const match = catalog.find(c => c.name === it.name); if(match && match.unit) unit = match.unit; upsertInventory(inv, { name: it.name, qty: Number(it.qty) || 1, unit: unit, buyDate: todayISO(), kind: 'raw', shelf: guessShelfDays(it.name, unit) }); count++; }
      setTimeout(() => { scanStatus.style.display = 'none'; alert(`成功识别并添加了 ${count} 种食材！`); renderTable(); }, 1000);
    } catch(err) { scanStatus.innerHTML = `<span style="color:var(--bad)">❌ 识别失败: ${err.message}</span>`; }
  };
  function renderTable(){ const tb=tbl.querySelector('tbody'); tb.innerHTML=''; const filterText = (searchDiv.querySelector('#invSearch').value || '').trim().toLowerCase(); const filteredInv = inv.filter(e => e.name.toLowerCase().includes(filterText)); filteredInv.sort((a,b)=>remainingDays(a)-remainingDays(b)); if(filteredInv.length === 0 && inv.length > 0) { tb.innerHTML = `<tr><td colspan="7" class="small" style="text-align:center;padding:16px;">没有找到包含 "${filterText}" 的食材</td></tr>`; return; } else if(inv.length === 0) { tb.innerHTML = `<tr><td colspan="7" class="small" style="text-align:center;padding:16px;">库存为空，快去添加点什么吧！</td></tr>`; return; } for(const e of filteredInv){ const tr=document.createElement('tr'); tr.innerHTML=`<td>${e.name}<div class="small">${(e.kind||'raw')==='semi'?'半成品':'原材料'}</div></td><td class="qty"><input type="number" step="1" value="${+e.qty||0}" style="width:60px"></td><td><select><option value="g"${e.unit==='g'?' selected':''}>g</option><option value="ml"${e.unit==='ml'?' selected':''}>ml</option><option value="pcs"${e.unit==='pcs'?' selected':''}>pcs</option></select></td><td><input type="date" value="${e.buyDate||todayISO()}" style="width:110px"></td><td><input type="number" step="1" value="${+e.shelf||7}" style="width:50px"></td><td>${badgeFor(e)}</td><td class="right"><a class="btn" href="javascript:void(0)">保存</a><a class="btn" href="javascript:void(0)">删</a></td>`; const inputs=els('input',tr); const qtyEl=inputs[0], dateEl=inputs[1], shelfEl=inputs[2]; const unitEl=els('select',tr)[0]; const [saveBtn, delBtn]=els('.btn',tr).slice(-2); saveBtn.onclick=()=>{ e.qty=+qtyEl.value||0; e.unit=unitEl.value; e.buyDate=dateEl.value||todayISO(); e.shelf=+shelfEl.value||7; saveInventory(inv); renderTable(); }; delBtn.onclick=()=>{ const i=inv.indexOf(e); if(i>=0){ inv.splice(i,1); saveInventory(inv); renderTable(); }}; tb.appendChild(tr); } } searchDiv.querySelector('#invSearch').oninput = () => renderTable(); ctr.querySelector('#addBtn').onclick=()=>{ const name=ctr.querySelector('#addName').value.trim(); if(!name) return alert('请选择或输入食材名称'); const qty=+ctr.querySelector('#addQty').value||0; const unit=ctr.querySelector('#addUnit').value; const date=ctr.querySelector('#addDate').value||todayISO(); const kind=ctr.querySelector('#addKind').value; const cat=catalog.find(c=>c.name===name); upsertInventory(inv,{name, qty, unit, buyDate:date, kind, shelf:(cat&&cat.shelf)||7}); ctr.querySelector('#addName').value = ''; ctr.querySelector('#addQty').value = ''; renderTable(); }; renderTable(); return wrap; }

async function onRoute(){ app.innerHTML=''; const base = await loadBasePack(); const overlay = loadOverlay(); const pack = applyOverlay(base, overlay); let hash = location.hash.replace('#',''); els('nav a').forEach(a=>a.classList.remove('active')); if(hash==='recipes') el('#nav-recipe').classList.add('active'); else if(hash==='shopping') el('#nav-shop').classList.add('active'); else if(hash==='settings') el('#nav-set').classList.add('active'); else if(!hash || hash==='inventory') el('#nav-home').classList.add('active'); if(hash.startsWith('recipe-edit:')){ const id = hash.split(':')[1]; app.appendChild(renderRecipeEditor(id, base)); } else if(hash.startsWith('recipe:')){ const id = hash.split(':')[1]; app.appendChild(renderRecipeDetail(id, pack)); } else if(hash==='shopping'){ app.appendChild(renderShopping(pack)); } else if(hash==='recipes'){ app.appendChild(renderRecipes(pack)); } else if(hash==='settings'){ app.appendChild(renderSettings()); } else { app.appendChild(renderHome(pack)); } } window.addEventListener('hashchange', onRoute); onRoute();
