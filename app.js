// v28 app.js - 菜谱详情页 + AI 生成做法
const el = (sel, root=document) => root.querySelector(sel);
const els = (sel, root=document) => Array.from(root.querySelectorAll(sel));
const app = el('#app');
const todayISO = () => new Date().toISOString().slice(0,10);

// -------- Storage --------
const S = {
  save(k, v){ localStorage.setItem(k, JSON.stringify(v)); },
  load(k, d){ try{ return JSON.parse(localStorage.getItem(k)) ?? d }catch{ return d } },
  keys: { inventory:'km_v19_inventory', plan:'km_v19_plan', overlay:'km_v19_overlay', settings:'km_v23_settings' }
};

// -------- Data Loading --------
async function loadBasePack(){
  const url = new URL('./data/sichuan-recipes.json', location).href + '?v=23';
  try{ const res = await fetch(url, { cache:'no-store' }); if(!res.ok) throw 0; return await res.json(); }
  catch{ return {recipes:[], recipe_ingredients:{}}; }
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
    if(!baseMap.has(id)) baseMap.set(id, {id, name: ov.name || ('未命名-'+id.slice(-4)), tags: ov.tags || [], method: ov.method || ''});
    else {
       // Merge method: if overlay has method, use it, otherwise keep base (if any)
       const old = baseMap.get(id);
       baseMap.set(id, {...old, ...ov, method: ov.method || old.method || ''});
    }
  }
  const io = overlay.recipe_ingredients || {};
  for(const [id, list] of Object.entries(io)){ ingMap[id] = list.slice(); }
  for(const r of baseMap.values()) recipes.push(r);
  // Add newly created
  for(const [id, ov] of Object.entries(ro)){
    if(/^u-/.test(id) && !recipes.find(x=>x.id===id)){
      recipes.push({id, name: ov.name || ('自定义-'+id.slice(-4)), tags: ov.tags || ['自定义'], method: ov.method || ''});
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

// -------- AI Service --------
async function callCloudAI(pack, inv) {
  const settings = S.load(S.keys.settings, { apiUrl: '', apiKey: '', model: '' });
  if(!settings.apiKey) throw new Error("请先在“设置”中填入 API Key");
  const apiUrl = settings.apiUrl || 'https://api.deepseek.com/v1/chat/completions';
  const model = settings.model || 'deepseek-chat';
  const invNames = inv.map(x => x.name).join('、');
  const recipeNames = (pack.recipes||[]).map(r=>r.name).join(',');
  const prompt = `
  我冰箱里有这些食材：【${invNames}】。
  我的菜谱数据库里有这些菜名：【${recipeNames}】。
  请做两件事：
  1. 从我的数据库中挑选 3 道最适合现在做的菜（尽可能多消耗库存）。
  2. 推荐 1 道数据库里没有的、有创意的菜（Based on my inventory）。
  请严格只返回 JSON 格式，不要Markdown标记，格式如下：
  {
    "local": [ {"name": "数据库里的菜名", "reason": "推荐理由"} ],
    "creative": { "name": "创意菜名", "reason": "推荐理由", "ingredients": "大概用料" }
  }`;
  try {
    const res = await fetch(apiUrl, {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${settings.apiKey}` },
      body: JSON.stringify({ model: model, messages: [{role: "user", content: prompt}], temperature: 0.7 })
    });
    if(!res.ok) throw new Error("API 请求失败: " + res.status);
    const data = await res.json();
    const content = data.choices?.[0]?.message?.content || "{}";
    const jsonStr = content.replace(/```json/g, '').replace(/```/g, '').trim();
    return JSON.parse(jsonStr);
  } catch(e) { console.error(e); throw e; }
}

// 生成做法的专用 AI 函数
async function callAiForMethod(recipeName, ingredients) {
  const settings = S.load(S.keys.settings, { apiUrl: '', apiKey: '', model: '' });
  if(!settings.apiKey) throw new Error("请先在设置中填入 API Key");
  const apiUrl = settings.apiUrl || 'https://api.deepseek.com/v1/chat/completions';
  const model = settings.model || 'deepseek-chat';
  
  const ingStr = ingredients.map(i => i.item + (i.qty ? i.qty + (i.unit||'') : '')).join('、');
  const prompt = `请为川菜【${recipeName}】写一份详细的烹饪做法。
  已知用料：${ingStr}。
  请直接输出做法步骤，分条列出，文字风格简洁、专业（类似《四川菜谱》风格）。不要多余的寒暄。`;

  try {
    const res = await fetch(apiUrl, {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${settings.apiKey}` },
      body: JSON.stringify({ model: model, messages: [{role: "user", content: prompt}], temperature: 0.7 })
    });
    if(!res.ok) throw new Error("API 失败");
    const data = await res.json();
    return data.choices?.[0]?.message?.content || "AI 未返回内容";
  } catch(e) { throw e; }
}

function getLocalRecommendations(pack, inv) {
  const invNames = inv.map(x => x.name.trim()).filter(Boolean);
  if (invNames.length === 0) return [];
  const scores = (pack.recipes || []).map(r => {
    const rawList = pack.recipe_ingredients[r.id] || [];
    const ingredients = explodeCombinedItems(rawList);
    let matchCount = 0;
    ingredients.forEach(ing => {
        const n = (ing.item || '').trim();
        if(n && invNames.some(invN => invN.includes(n) || n.includes(invN))) matchCount++;
    });
    return { r, matchCount, total: ingredients.length };
  });
  return scores.filter(s => s.matchCount > 0).sort((a,b) => b.matchCount - a.matchCount).slice(0, 6).map(s=>({r:s.r, reason:`本地匹配：含 ${s.matchCount} 种库存`}));
}

// -------- Renderers --------

function recipeCard(r, list, extraInfo=null){
  const card=document.createElement('div'); card.className='card';
  let topHtml = '';
  if(extraInfo && extraInfo.isAi) { topHtml = `<div class="ai-badge">✨ AI 推荐</div>`; }
  // 点击标题跳转到详情
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
  
  if(!r.id.startsWith('creative-')) { 
     card.querySelector('.btn-edit').onclick = (e) => { e.stopPropagation(); location.hash = `#recipe-edit:${r.id}`; }; 
  } else { card.querySelector('.btn-edit').remove(); }

  const ul=document.createElement('ul'); ul.className='ing-list';
  // 只显示前5个食材，避免卡片太长
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
    
    // 详情按钮
    const detailBtn = document.createElement('a'); detailBtn.className='btn'; detailBtn.textContent='查看做法';
    detailBtn.onclick = () => location.hash = `#recipe:${r.id}`;
    card.querySelector('.controls').appendChild(detailBtn);
  }
  return card;
}

// 详情页渲染
function renderRecipeDetail(id, pack) {
  const r = (pack.recipes||[]).find(x=>x.id===id);
  if(!r) return document.createTextNode('未找到菜谱');
  const ingList = pack.recipe_ingredients[id] || [];
  const items = explodeCombinedItems(ingList);

  const div = document.createElement('div');
  div.className = 'detail-view';
  
  // 做法内容，如果没有则显示提示
  const methodContent = r.method ? `<div class="method-text">${r.method}</div>` : 
    `<div class="small" style="margin-bottom:10px">暂无做法记录。</div>
     <a class="btn ai" id="genMethodBtn">✨ 让 AI 生成做法</a>`;

  div.innerHTML = `
    <div style="margin-bottom:20px"><a class="btn" onclick="history.back()">← 返回</a> <a class="btn" href="#recipe-edit:${r.id}">编辑</a></div>
    <h2>${r.name}</h2>
    <div class="tags meta">${(r.tags||[]).join(' / ')}</div>
    
    <div class="block">
      <h4>用料 Ingredients</h4>
      <ul class="ing-list" style="columns:2; -webkit-columns:2;">
        ${items.map(it => `<li>${it.item} <span class="small">${it.qty?it.qty+(it.unit||''):''}</span></li>`).join('')}
      </ul>
    </div>

    <div class="block">
      <h4>做法 Method</h4>
      <div id="methodArea">${methodContent}</div>
    </div>
  `;

  // 绑定 AI 生成事件
  const genBtn = div.querySelector('#genMethodBtn');
  if(genBtn) {
    genBtn.onclick = async () => {
      genBtn.innerHTML = '<span class="spinner"></span> 正在生成...';
      try {
        const text = await callAiForMethod(r.name, items);
        // 保存到补丁
        const overlay = loadOverlay();
        overlay.recipes = overlay.recipes || {};
        overlay.recipes[id] = { ...(overlay.recipes[id]||{}), method: text };
        saveOverlay(overlay);
        
        // 更新界面
        div.querySelector('#methodArea').innerHTML = `<div class="method-text">${text}</div><div class="small ok" style="margin-top:10px">已自动保存到补丁</div>`;
        alert('生成成功并已保存！');
      } catch(e) {
        alert('生成失败：' + e.message);
        genBtn.innerHTML = '✨ 让 AI 生成做法';
      }
    };
  }

  return div;
}

function renderRecipes(pack){
  const wrap = document.createElement('div');
  wrap.innerHTML = `<div class="controls" style="margin-bottom:16px;gap:10px;"><input id="search" placeholder="搜菜谱..." style="flex:1;padding:10px;"><a class="btn ok" id="addBtn" style="padding:10px;">+ 新建</a><a class="btn" id="exportBtn">导出</a><label class="btn"><input type="file" id="importFile" hidden>导入</label></div><div class="grid" id="grid"></div>`;
  const grid = wrap.querySelector('#grid'); const map = pack.recipe_ingredients||{};
  function draw(filter=''){ grid.innerHTML = ''; const f = filter.trim(); (pack.recipes||[]).filter(r => !f || r.name.includes(f)).forEach(r=>{ grid.appendChild(recipeCard(r, map[r.id])); }); }
  draw();
  wrap.querySelector('#search').oninput = e => draw(e.target.value);
  wrap.querySelector('#addBtn').onclick = () => { const id = genId(); const overlay = loadOverlay(); overlay.recipes = overlay.recipes || {}; overlay.recipes[id] = { name: '新菜谱', tags: ['自定义'] }; overlay.recipe_ingredients = overlay.recipe_ingredients || {}; overlay.recipe_ingredients[id] = [{item:'', qty:null, unit:'g'}]; saveOverlay(overlay); location.hash = `#recipe-edit:${id}`; };
  wrap.querySelector('#exportBtn').onclick = ()=>{ const blob = new Blob([JSON.stringify(loadOverlay(), null, 2)], {type:'application/json'}); const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'kitchen-overlay.json'; a.click(); };
  wrap.querySelector('#importFile').onchange = (e)=>{ const file = e.target.files[0]; if(!file) return; const reader = new FileReader(); reader.onload = ()=>{ try{ const inc = JSON.parse(reader.result); const cur = loadOverlay(); const m = {...cur, recipes:{...cur.recipes,...(inc.recipes||{})}, recipe_ingredients:{...cur.recipe_ingredients,...(inc.recipe_ingredients||{})}, deletes:{...cur.deletes,...(inc.deletes||{})} }; saveOverlay(m); alert('导入成功'); location.reload(); }catch(err){ alert('导入失败'); } }; reader.readAsText(file); };
  return wrap;
}

function renderHome(pack){
  const container = document.createElement('div');
  const recDiv = document.createElement('div');
  recDiv.innerHTML = `<div style="display:flex;justify-content:space-between;align-items:center;margin:24px 0 12px;"><h2 class="section-title" style="margin:0;border:none;padding:0">今日推荐</h2><a class="btn ai" id="callAiBtn">✨ 呼叫 AI 厨师</a></div><div id="rec-content" class="grid"></div>`;
  const recGrid = recDiv.querySelector('#rec-content');
  container.appendChild(recDiv);
  const catalog = buildCatalog(pack);
  const inv = loadInventory(catalog);
  const localRecs = getLocalRecommendations(pack, inv);
  function showCards(list) {
    recGrid.innerHTML = '';
    if(list.length===0) { recGrid.innerHTML = '<div class="small" style="grid-column:1/-1;padding:20px;text-align:center;">冰箱空空如也，快去“库存”添加食材，或点击右上角“呼叫 AI”获取灵感！</div>'; return; }
    const map = pack.recipe_ingredients || {};
    list.forEach(item => { recGrid.appendChild(recipeCard(item.r, item.list || map[item.r.id], { reason: item.reason, isAi: item.isAi })); });
  }
  showCards(localRecs);
  const aiBtn = recDiv.querySelector('#callAiBtn');
  aiBtn.onclick = async () => {
    aiBtn.innerHTML = '<span class="spinner"></span> 思考中...'; aiBtn.style.opacity = '0.7';
    try {
      const aiResult = await callCloudAI(pack, inv);
      const newCards = [];
      if(aiResult.local && Array.isArray(aiResult.local)){ aiResult.local.forEach(l => { const found = (pack.recipes||[]).find(r => r.name === l.name); if(found) newCards.push({ r: found, reason: l.reason, isAi: true }); }); }
      if(aiResult.creative){ const c = aiResult.creative; newCards.push({ r: { id: 'creative-'+Date.now(), name: c.name, tags: ['AI创意菜'] }, list: [{item: c.ingredients || '请根据描述自由发挥'}], reason: c.reason, isAi: true }); }
      if(newCards.length > 0) showCards(newCards); else alert('AI 虽然响应了，但没有给出有效推荐。');
    } catch(e) { alert(e.message); } finally { aiBtn.innerHTML = '✨ 呼叫 AI 厨师'; aiBtn.style.opacity = '1'; }
  };
  container.appendChild(renderInventory(pack));
  return container;
}

function renderSettings(){
  const s = S.load(S.keys.settings, { apiUrl: '', apiKey: '', model: '' });
  const div = document.createElement('div');
  div.innerHTML = `<h2 class="section-title">AI 设置</h2><div class="card"><div class="setting-group"><label>快速预设 (点我自动填)</label><select id="sPreset"><option value="">请选择服务商...</option><option value="silicon">SiliconFlow (硅基流动) - 免费</option><option value="groq">Groq - 免费/极速</option><option value="deepseek">DeepSeek - 官方</option><option value="openai">OpenAI (GPT)</option></select></div><hr style="border:0;border-top:1px solid rgba(255,255,255,0.1);margin:16px 0"><div class="setting-group"><label>API 地址</label><input id="sUrl" value="${s.apiUrl}" placeholder="https://..."></div><div class="setting-group"><label>模型名称 (Model)</label><input id="sModel" value="${s.model}" placeholder="例如 llama3-8b-8192"></div><div class="setting-group"><label>API Key</label><input id="sKey" type="password" value="${s.apiKey}" placeholder="sk-..."></div><div class="right"><a class="btn ok" id="saveSet">保存设置</a></div><p class="small" style="margin-top:20px;line-height:1.6;color:var(--muted)">* 提示：Groq 必须填写正确的模型名 (如 llama3-8b-8192)，不能填 gpt-3.5。<br>* 使用上方“快速预设”可自动填充正确的地址和模型。</p></div>`;
  const presets = { silicon: { url: 'https://api.siliconflow.cn/v1/chat/completions', model: 'Qwen/Qwen2.5-7B-Instruct' }, groq: { url: 'https://api.groq.com/openai/v1/chat/completions', model: 'llama3-8b-8192' }, deepseek: { url: 'https://api.deepseek.com/v1/chat/completions', model: 'deepseek-chat' }, openai: { url: 'https://api.openai.com/v1/chat/completions', model: 'gpt-3.5-turbo' } };
  div.querySelector('#sPreset').onchange = (e) => { const val = e.target.value; if(presets[val]) { div.querySelector('#sUrl').value = presets[val].url; div.querySelector('#sModel').value = presets[val].model; } };
  div.querySelector('#saveSet').onclick = () => { s.apiUrl = div.querySelector('#sUrl').value.trim(); s.apiKey = div.querySelector('#sKey').value.trim(); s.model = div.querySelector('#sModel').value.trim(); S.save(S.keys.settings, s); alert('设置已保存'); };
  return div;
}

function renderInventory(pack){
  const catalog=buildCatalog(pack);
  const inv=loadInventory(catalog);
  const wrap=document.createElement('div');
  const h=document.createElement('h2'); h.className='section-title'; h.textContent='库存管理'; wrap.appendChild(h);
  const searchDiv = document.createElement('div'); searchDiv.className = 'controls'; searchDiv.style.marginBottom = '8px'; searchDiv.innerHTML = `<input id="invSearch" placeholder="🔍 搜索库存..." style="width:100%;padding:10px;background:var(--card);border:1px solid rgba(255,255,255,0.1);">`; wrap.appendChild(searchDiv);
  const ctr=document.createElement('div'); ctr.className='controls'; ctr.innerHTML=`<div style="flex:1; min-width:120px;"><input id="addName" list="catalogList" placeholder="选择/搜索食材" style="width:100%;padding:10px;border-radius:8px;border:1px solid rgba(255,255,255,0.14);background:#0f1935;color:#fff;"><datalist id="catalogList">${catalog.map(c=>`<option value="${c.name}">`).join('')}</datalist></div><input id="addQty" type="number" step="1" placeholder="数量"><select id="addUnit"><option value="g">g</option><option value="ml">ml</option><option value="pcs">pcs</option></select><input id="addDate" type="date" value="${todayISO()}"><select id="addKind"><option value="raw">原材料</option><option value="semi">半成品</option></select><button id="addBtn" class="btn">入库</button>`; wrap.appendChild(ctr);
  ctr.querySelector('#addName').addEventListener('input', (e)=>{ const val = e.target.value.trim(); const match = catalog.find(c => c.name === val); if(match && match.unit){ ctr.querySelector('#addUnit').value = match.unit; } });
  const tbl=document.createElement('table'); tbl.className='table'; tbl.innerHTML=`<thead><tr><th>食材</th><th>数量</th><th>单位</th><th>购买日期</th><th>保质</th><th>状态</th><th></th></tr></thead><tbody></tbody>`; wrap.appendChild(tbl);
  function renderTable(){ const tb=tbl.querySelector('tbody'); tb.innerHTML=''; const filterText = (searchDiv.querySelector('#invSearch').value || '').trim().toLowerCase(); const filteredInv = inv.filter(e => e.name.toLowerCase().includes(filterText)); filteredInv.sort((a,b)=>remainingDays(a)-remainingDays(b)); if(filteredInv.length === 0 && inv.length > 0) { tb.innerHTML = `<tr><td colspan="7" class="small" style="text-align:center;padding:16px;">没有找到包含 "${filterText}" 的食材</td></tr>`; return; } else if(inv.length === 0) { tb.innerHTML = `<tr><td colspan="7" class="small" style="text-align:center;padding:16px;">库存为空，快去添加点什么吧！</td></tr>`; return; } for(const e of filteredInv){ const tr=document.createElement('tr'); tr.innerHTML=`<td>${e.name}<div class="small">${(e.kind||'raw')==='semi'?'半成品':'原材料'}</div></td><td class="qty"><input type="number" step="1" value="${+e.qty||0}" style="width:60px"></td><td><select><option value="g"${e.unit==='g'?' selected':''}>g</option><option value="ml"${e.unit==='ml'?' selected':''}>ml</option><option value="pcs"${e.unit==='pcs'?' selected':''}>pcs</option></select></td><td><input type="date" value="${e.buyDate||todayISO()}" style="width:110px"></td><td><input type="number" step="1" value="${+e.shelf||7}" style="width:50px"></td><td>${badgeFor(e)}</td><td class="right"><a class="btn" href="javascript:void(0)">保存</a><a class="btn" href="javascript:void(0)">删</a></td>`; const inputs=els('input',tr); const qtyEl=inputs[0], dateEl=inputs[1], shelfEl=inputs[2]; const unitEl=els('select',tr)[0]; const [saveBtn, delBtn]=els('.btn',tr).slice(-2); saveBtn.onclick=()=>{ e.qty=+qtyEl.value||0; e.unit=unitEl.value; e.buyDate=dateEl.value||todayISO(); e.shelf=+shelfEl.value||7; saveInventory(inv); renderTable(); }; delBtn.onclick=()=>{ const i=inv.indexOf(e); if(i>=0){ inv.splice(i,1); saveInventory(inv); renderTable(); }}; tb.appendChild(tr); } }
  searchDiv.querySelector('#invSearch').oninput = () => renderTable();
  ctr.querySelector('#addBtn').onclick=()=>{ const name=ctr.querySelector('#addName').value.trim(); if(!name) return alert('请选择或输入食材名称'); const qty=+ctr.querySelector('#addQty').value||0; const unit=ctr.querySelector('#addUnit').value; const date=ctr.querySelector('#addDate').value||todayISO(); const kind=ctr.querySelector('#addKind').value; const cat=catalog.find(c=>c.name===name); upsertInventory(inv,{name, qty, unit, buyDate:date, kind, shelf:(cat&&cat.shelf)||7}); ctr.querySelector('#addName').value = ''; ctr.querySelector('#addQty').value = ''; renderTable(); };
  renderTable();
  return wrap;
}

function renderShopping(pack){ const inv=loadInventory(buildCatalog(pack)); const plan=S.load(S.keys.plan,[]); const map=pack.recipe_ingredients||{}; const need={}; const addNeed=(n,q,u)=>{ const k=n+'|'+(u||'g'); need[k]=(need[k]||0)+(+q||0); }; for(const p of plan){ for(const it of explodeCombinedItems(map[p.id]||[])){ if(typeof it.qty==='number') addNeed(it.item, it.qty*(p.servings||1), it.unit); }} const missing=[]; for(const [k,req] of Object.entries(need)){ const [n,u]=k.split('|'); const stock=(inv.filter(x=>x.name===n&&x.unit===u).reduce((s,x)=>s+(+x.qty||0),0)); const m=Math.max(0, Math.round((req-stock)*100)/100); if(m>0) missing.push({name:n, unit:u, qty:m}); } const d=document.createElement('div'); const h=document.createElement('h2'); h.className='section-title'; h.textContent='购物清单'; d.appendChild(h); const pd=document.createElement('div'); pd.className='card'; pd.innerHTML='<h3>今日计划</h3>'; const pl=document.createElement('div'); pd.appendChild(pl); function drawPlan(){ pl.innerHTML=''; if(plan.length===0){ const p=document.createElement('p'); p.className='small'; p.textContent='暂未添加菜谱。请去首页或菜谱页添加。'; pl.appendChild(p); return; } for(const p of plan){ const r=(pack.recipes||[]).find(x=>x.id===p.id); if(!r) continue; const row=document.createElement('div'); row.className='controls'; row.innerHTML=`<span>${r.name}</span><span class="small">份数</span><input type="number" min="1" max="8" step="1" value="${p.servings||1}" style="width:80px"><a class="btn" href="javascript:void(0)">移除</a>`; const input=els('input',row)[0]; input.onchange=()=>{ const plans=S.load(S.keys.plan,[]); const it=plans.find(x=>x.id===p.id); if(it){ it.servings=+input.value||1; S.save(S.keys.plan,plans); onRoute(); } }; els('.btn',row)[0].onclick=()=>{ const plans=S.load(S.keys.plan,[]); const i=plans.findIndex(x=>x.id===p.id); if(i>=0){ plans.splice(i,1); S.save(S.keys.plan,plans); onRoute(); } }; pl.appendChild(row); }} drawPlan(); d.appendChild(pd); const tbl=document.createElement('table'); tbl.className='table'; tbl.innerHTML=`<thead><tr><th>食材</th><th>需购</th><th>单位</th><th class="right">操作</th></tr></thead><tbody></tbody>`; const tb=tbl.querySelector('tbody'); if(missing.length===0){ const tr=document.createElement('tr'); tr.innerHTML='<td colspan="4" class="small">库存已满足，无需购买。</td>'; tb.appendChild(tr); } else { for(const m of missing){ const tr=document.createElement('tr'); tr.innerHTML=`<td>${m.name}</td><td>${m.qty}</td><td>${m.unit}</td><td class="right"><a class="btn" href="javascript:void(0)">标记已购</a></td>`; els('.btn',tr)[0].onclick=()=>{ const invv=S.load(S.keys.inventory,[]); addInventoryQty(invv,m.name,m.qty,m.unit,'raw'); tr.remove(); }; tb.appendChild(tr); } } d.appendChild(tbl); return d; }

function renderRecipeEditor(id, base){
  const overlay = loadOverlay();
  const baseIng = base.recipe_ingredients || {};
  const overIng = overlay.recipe_ingredients || {};
  const rBase = (base.recipes||[]).find(x => x.id===id);
  const rOv = (overlay.recipes||{})[id] || {};
  const r = {...(rBase||{id}), ...rOv};
  const items = (overIng[id] ?? baseIng[id] ?? []).map(x => ({...x}));
  const isNew = /^u-/.test(id) && !rBase;
  
  const wrap = document.createElement('div'); wrap.className = 'card'; wrap.style.padding = '20px';
  wrap.innerHTML = `
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;">
      <h2 style="margin:0">编辑菜谱</h2>
      <a class="btn" onclick="history.back()">返回</a>
    </div>
    <div class="controls" style="flex-direction:column;align-items:stretch;gap:12px;">
      <div><label class="small">菜名</label><input id="rName" value="${r.name||''}" style="width:100%;font-size:16px;padding:8px;"></div>
      <div><label class="small">标签 (逗号分隔)</label><input id="rTags" value="${(r.tags||[]).join(',')}" style="width:100%;padding:8px;"></div>
      <div class="small badge">${isNew?'[自定义菜谱]':'[基于系统数据]'}</div>
    </div>
    
    <h3 style="margin-top:20px">用料表</h3>
    <table class="table"><thead><tr><th>食材</th><th>数量</th><th>单位</th><th class="right"></th></tr></thead><tbody id="rows"></tbody></table>
    <div style="margin-top:10px"><a class="btn" id="addRow" style="width:100%;text-align:center;display:block">+ 添加一行</a></div>
    
    <h3 style="margin-top:20px">做法 (Method)</h3>
    <textarea id="rMethod" rows="8" placeholder="请输入烹饪步骤..." style="width:100%;padding:10px;border-radius:8px;border:1px solid rgba(255,255,255,0.1);background:#0f1935;color:#fff;line-height:1.5;">${r.method || ''}</textarea>

    <div class="controls" style="margin-top:30px;border-top:1px solid #333;padding-top:20px;justify-content:space-between;">
       <div><a class="btn bad" id="hideBtn" style="border-color:var(--bad);color:var(--bad)">${(overlay.deletes||{})[id]?'取消隐藏':'删除/隐藏'}</a>${!isNew ? '<a class="btn" id="resetBtn">重置</a>' : ''}</div>
       <a class="btn ok" id="saveBtn" style="background:var(--ok);color:#000;font-weight:bold;padding:8px 20px;">保存</a>
    </div>
  `;
  
  const tbody = wrap.querySelector('#rows');
  function addRow(item='', qty='', unit='g'){
    const tr = document.createElement('tr');
    tr.innerHTML = `<td><input placeholder="食材" value="${item}" style="width:100%"></td><td><input type="number" step="0.1" placeholder="" value="${qty}" style="width:60px"></td><td><select><option value="g"${unit==='g'?' selected':''}>g</option><option value="ml"${unit==='ml'?' selected':''}>ml</option><option value="pcs"${unit==='pcs'?' selected':''}>个</option></select></td><td class="right"><a class="btn" style="color:var(--bad)">X</a></td>`;
    els('.btn', tr)[0].onclick = ()=> tr.remove(); tbody.appendChild(tr);
  }
  items.forEach(it => addRow(it.item || '', (typeof it.qty==='number' && isFinite(it.qty))? it.qty : '', it.unit || 'g'));
  wrap.querySelector('#addRow').onclick = ()=> addRow();
  
  wrap.querySelector('#saveBtn').onclick = ()=>{
    const name = wrap.querySelector('#rName').value.trim();
    if(!name) return alert('菜名不能为空');
    const tags = wrap.querySelector('#rTags').value.split(/[，,]/).map(s=>s.trim()).filter(Boolean);
    const method = wrap.querySelector('#rMethod').value; // 获取做法内容
    
    overlay.recipes = overlay.recipes || {};
    overlay.recipes[id] = { name, tags, method }; // 保存做法
    
    overlay.recipe_ingredients = overlay.recipe_ingredients || {};
    const arr = [];
    els('tbody#rows tr', wrap).forEach(tr => {
      const [i1,i2] = els('input', tr);
      const sel = els('select', tr)[0];
      const item = i1.value.trim(); if(!item) return;
      const qty = i2.value === '' ? null : Number(i2.value);
      const unit = sel.value || null;
      arr.push({ item, ...(qty===null?{}:{qty}), ...(unit?{unit}:{}) });
    });
    overlay.recipe_ingredients[id] = arr;
    if(overlay.deletes) delete overlay.deletes[id];
    saveOverlay(overlay);
    alert('已保存');
    history.back();
  };
  // ... rest of buttons (hide, reset) same as before
  wrap.querySelector('#hideBtn').onclick = ()=>{ if(!confirm('确定删除/隐藏？')) return; overlay.deletes = overlay.deletes || {}; if(overlay.deletes[id]) delete overlay.deletes[id]; else overlay.deletes[id] = true; saveOverlay(overlay); history.back(); };
  const rBtn = wrap.querySelector('#resetBtn'); if(rBtn) rBtn.onclick = ()=>{ if(!confirm('确定重置？')) return; if(overlay.recipes) delete overlay.recipes[id]; if(overlay.recipe_ingredients) delete overlay.recipe_ingredients[id]; if(overlay.deletes) delete overlay.deletes[id]; saveOverlay(overlay); app.innerHTML = ''; app.appendChild(renderRecipeEditor(id, base)); };
  return wrap;
}

async function onRoute(){
  app.innerHTML='';
  const base = await loadBasePack();
  const overlay = loadOverlay();
  const pack = applyOverlay(base, overlay);
  let hash = location.hash.replace('#','');
  els('nav a').forEach(a=>a.classList.remove('active'));
  if(hash==='recipes') el('#nav-recipe').classList.add('active');
  else if(hash==='shopping') el('#nav-shop').classList.add('active');
  else if(hash==='settings') el('#nav-set').classList.add('active');
  else if(!hash || hash==='inventory') el('#nav-home').classList.add('active');

  if(hash.startsWith('recipe-edit:')){
    const id = hash.split(':')[1];
    app.appendChild(renderRecipeEditor(id, base));
  }
  else if(hash.startsWith('recipe:')){
    const id = hash.split(':')[1];
    app.appendChild(renderRecipeDetail(id, pack));
  }
  else if(hash==='shopping'){ app.appendChild(renderShopping(pack)); }
  else if(hash==='recipes'){ app.appendChild(renderRecipes(pack)); }
  else if(hash==='settings'){ app.appendChild(renderSettings()); }
  else { app.appendChild(renderHome(pack)); }
}
window.addEventListener('hashchange', onRoute); onRoute();
