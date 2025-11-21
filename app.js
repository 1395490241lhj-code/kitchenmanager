// v22 app.js - 智能库存推荐算法
const el = (sel, root=document) => root.querySelector(sel);
const els = (sel, root=document) => Array.from(root.querySelectorAll(sel));
const app = el('#app');
const todayISO = () => new Date().toISOString().slice(0,10);

// -------- Storage --------
const S = {
  save(k, v){ localStorage.setItem(k, JSON.stringify(v)); },
  load(k, d){ try{ return JSON.parse(localStorage.getItem(k)) ?? d }catch{ return d } },
  keys: { inventory:'km_v19_inventory', plan:'km_v19_plan', overlay:'km_v19_overlay' }
};

// -------- Data Loading --------
async function loadBasePack(){
  const url = new URL('./data/sichuan-recipes.json', location).href + '?v=22';
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
    if(!baseMap.has(id)) baseMap.set(id, {id, name: ov.name || ('未命名-'+id.slice(-4)), tags: ov.tags || []});
    else baseMap.set(id, {...baseMap.get(id), ...ov});
  }
  const io = overlay.recipe_ingredients || {};
  for(const [id, list] of Object.entries(io)){ ingMap[id] = list.slice(); }
  for(const r of baseMap.values()) recipes.push(r);
  for(const [id, ov] of Object.entries(ro)){
    if(/^u-/.test(id) && !recipes.find(x=>x.id===id)){
      recipes.push({id, name: ov.name || ('自定义-'+id.slice(-4)), tags: ov.tags || ['自定义']});
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
      for(const n of name.split(SEP_RE).map(s=>s.trim()).filter(Boolean)){
        out.push({ item:n, qty:null, unit:null });
      }
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

// -------- AI Recommendation Logic (核心：智能推荐算法) --------
function getSmartRecommendations(pack, inv) {
  // 1. 提取库存里的有效名称
  const invNames = inv.map(x => x.name.trim()).filter(Boolean);
  
  // 2. 如果库存为空，返回空列表（触发随机兜底）
  if (invNames.length === 0) return [];

  const scores = (pack.recipes || []).map(r => {
    const rawList = pack.recipe_ingredients[r.id] || [];
    const ingredients = explodeCombinedItems(rawList);
    
    let matchCount = 0;
    const matchedItems = [];
    
    ingredients.forEach(ing => {
        const n = (ing.item || '').trim();
        if(!n) return;
        // 模糊匹配：库存名包含用料名，或用料名包含库存名
        // 例如：库存“五花肉”可以命中“猪肉”，库存“豆腐”可以命中“麻婆豆腐”所需的“豆腐”
        const hit = invNames.some(invN => invN.includes(n) || n.includes(invN));
        if(hit) {
          matchCount++;
          matchedItems.push(n);
        }
    });
    
    return { r, matchCount, total: ingredients.length, matchedItems };
  });

  // 3. 过滤：至少命中 1 个食材
  const matched = scores.filter(s => s.matchCount > 0);
  
  // 4. 排序算法
  // 优先级 A：命中数量（越多越好）
  // 优先级 B：完成度（命中数/总数，越高越好，说明缺的少）
  matched.sort((a,b) => {
      if (b.matchCount !== a.matchCount) return b.matchCount - a.matchCount;
      const ratioA = a.total > 0 ? a.matchCount / a.total : 0;
      const ratioB = b.total > 0 ? b.matchCount / b.total : 0;
      return ratioB - ratioA;
  });
  
  // 取前 6 个
  return matched.slice(0, 6);
}

// -------- Renderers --------

function recipeCard(r, list, matchInfo=null){
  const card=document.createElement('div'); card.className='card';
  
  // 如果有匹配信息，显示徽章
  let badgeHtml = '';
  if(matchInfo && matchInfo.count > 0){
    badgeHtml = `<br><span class="match-badge">⚡ 冰箱有 ${matchInfo.count} 样食材</span>`;
  }

  card.innerHTML=`
    <div style="display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:8px;">
      <h3 style="margin:0;flex:1">${r.name}</h3>
      <a class="kchip bad small btn-edit" data-id="${r.id}" style="cursor:pointer;margin-left:8px;">编辑</a>
    </div>
    <p class="meta">
      ${(r.tags||[]).join(' / ')}
      ${badgeHtml}
    </p>
    <div class="ings"></div>
    <div class="controls"></div>`;
  
  card.querySelector('.btn-edit').onclick = (e) => {
    e.stopPropagation();
    location.hash = `#recipe-edit:${r.id}`;
  };

  const ul=document.createElement('ul'); ul.className='ing-list';
  for(const it of explodeCombinedItems(list||[])){ const q=(typeof it.qty==='number'&&isFinite(it.qty))?(it.qty+(it.unit||'')):''; const li=document.createElement('li'); li.textContent=q?`${it.item}  ${q}`:it.item; ul.appendChild(li); }
  card.querySelector('.ings').appendChild(ul);

  const plan = new Set((S.load(S.keys.plan,[])).map(x=>x.id));
  const btn=document.createElement('a'); btn.href='javascript:void(0)'; btn.className='btn'; btn.textContent=plan.has(r.id)?'已加入计划':'加入购物计划';
  btn.onclick=()=>{ const p=S.load(S.keys.plan,[]); const i=p.findIndex(x=>x.id===r.id); if(i>=0) p.splice(i,1); else p.push({id:r.id, servings:1}); S.save(S.keys.plan,p); onRoute(); };
  card.querySelector('.controls').appendChild(btn);
  return card;
}

function renderRecipes(pack){
  const wrap = document.createElement('div');
  wrap.innerHTML = `
    <div class="controls" style="margin-bottom:16px;gap:10px;">
       <input id="search" placeholder="搜菜谱..." style="flex:1;padding:10px;">
       <a class="btn ok" id="addBtn" style="padding:10px;">+ 新建</a>
       <a class="btn" id="exportBtn">导出</a>
       <label class="btn"><input type="file" id="importFile" hidden>导入</label>
    </div>
    <div class="grid" id="grid"></div>
  `;
  const grid = wrap.querySelector('#grid');
  const map = pack.recipe_ingredients||{};
  function draw(filter=''){
    grid.innerHTML = '';
    const f = filter.trim();
    (pack.recipes||[]).filter(r => !f || r.name.includes(f)).forEach(r=>{ 
       grid.appendChild(recipeCard(r, map[r.id])); 
    });
  }
  draw();
  wrap.querySelector('#search').oninput = e => draw(e.target.value);
  wrap.querySelector('#addBtn').onclick = () => {
    const id = genId();
    const overlay = loadOverlay();
    overlay.recipes = overlay.recipes || {};
    overlay.recipes[id] = { name: '新菜谱', tags: ['自定义'] };
    overlay.recipe_ingredients = overlay.recipe_ingredients || {};
    overlay.recipe_ingredients[id] = [{item:'', qty:null, unit:'g'}];
    saveOverlay(overlay); location.hash = `#recipe-edit:${id}`;
  };
  wrap.querySelector('#exportBtn').onclick = ()=>{ const blob = new Blob([JSON.stringify(loadOverlay(), null, 2)], {type:'application/json'}); const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'kitchen-overlay.json'; a.click(); };
  wrap.querySelector('#importFile').onchange = (e)=>{ const file = e.target.files[0]; if(!file) return; const reader = new FileReader(); reader.onload = ()=>{ try{ const inc = JSON.parse(reader.result); const cur = loadOverlay(); const m = {...cur, recipes:{...cur.recipes,...(inc.recipes||{})}, recipe_ingredients:{...cur.recipe_ingredients,...(inc.recipe_ingredients||{})}, deletes:{...cur.deletes,...(inc.deletes||{})} }; saveOverlay(m); alert('导入成功'); location.reload(); }catch(err){ alert('导入失败'); } }; reader.readAsText(file); };
  return wrap;
}

// 3. 首页 (AI 推荐 + 库存)
function renderHome(pack){
  const container = document.createElement('div');

  // --- AI 推荐模块 ---
  const catalog = buildCatalog(pack);
  const inv = loadInventory(catalog); // 获取库存用于计算
  
  const recDiv = document.createElement('div');
  const recScores = getSmartRecommendations(pack, inv);
  
  let title = 'AI 智能推荐 <span class="small" style="font-weight:normal;margin-left:8px">根据冰箱食材匹配</span>';
  let displayItems = [];

  if(recScores.length > 0) {
    // 有匹配结果
    displayItems = recScores.map(s => ({
        r: s.r,
        matchInfo: { count: s.matchCount }
    }));
  } else {
    // 兜底：没有库存或没有匹配时，随机推荐
    title = '今日推荐 <span class="small" style="font-weight:normal;margin-left:8px">随机探索</span>';
    const all = (pack.recipes||[]);
    // 随机洗牌取前6
    const shuffled = [...all].sort(() => 0.5 - Math.random()).slice(0, 6);
    displayItems = shuffled.map(r => ({ r: r, matchInfo: null }));
  }

  recDiv.innerHTML = `<h2 class="section-title">${title}</h2>`;
  const recGrid = document.createElement('div'); recGrid.className = 'grid';
  const map = pack.recipe_ingredients || {};
  
  displayItems.forEach(item => {
      // 传入匹配信息以便显示徽章
      recGrid.appendChild(recipeCard(item.r, map[item.r.id], item.matchInfo));
  });
  
  recDiv.appendChild(recGrid);
  container.appendChild(recDiv);

  // --- 库存模块 ---
  container.appendChild(renderInventory(pack));

  return container;
}

// 4. 库存管理 (复用 v19)
function renderInventory(pack){
  const catalog=buildCatalog(pack); const inv=loadInventory(catalog);
  const wrap=document.createElement('div'); const h=document.createElement('h2'); h.className='section-title'; h.textContent='库存管理'; wrap.appendChild(h);
  const ctr=document.createElement('div'); ctr.className='controls'; ctr.innerHTML=`
    <select id="addName"><option value="">选择食材</option>${catalog.map(c=>`<option>${c.name}</option>`).join('')}</select>
    <input id="addQty" type="number" step="1" placeholder="数量">
    <select id="addUnit"><option value="g">g</option><option value="ml">ml</option><option value="pcs">pcs</option></select>
    <input id="addDate" type="date" value="${todayISO()}">
    <select id="addKind"><option value="raw">原材料</option><option value="semi">半成品</option></select>
    <button id="addBtn" class="btn">入库</button>`; wrap.appendChild(ctr);
  ctr.querySelector('#addBtn').onclick=()=>{ const name=ctr.querySelector('#addName').value.trim(); if(!name) return alert('请选择食材');
    const qty=+ctr.querySelector('#addQty').value||0; const unit=ctr.querySelector('#addUnit').value; const date=ctr.querySelector('#addDate').value||todayISO(); const kind=ctr.querySelector('#addKind').value;
    const cat=catalog.find(c=>c.name===name); upsertInventory(inv,{name, qty, unit, buyDate:date, kind, shelf:(cat&&cat.shelf)||7}); renderTable(); };
  const tbl=document.createElement('table'); tbl.className='table'; tbl.innerHTML=`<thead><tr><th>食材</th><th>数量</th><th>单位</th><th>购买日期</th><th>保质</th><th>状态</th><th></th></tr></thead><tbody></tbody>`; wrap.appendChild(tbl);
  function renderTable(){ const tb=tbl.querySelector('tbody'); tb.innerHTML=''; inv.sort((a,b)=>remainingDays(a)-remainingDays(b));
    for(const e of inv){ const tr=document.createElement('tr'); tr.innerHTML=`
      <td>${e.name}<div class="small">${(e.kind||'raw')==='semi'?'半成品':'原材料'}</div></td>
      <td class="qty"><input type="number" step="1" value="${+e.qty||0}" style="width:60px"></td>
      <td><select><option value="g"${e.unit==='g'?' selected':''}>g</option><option value="ml"${e.unit==='ml'?' selected':''}>ml</option><option value="pcs"${e.unit==='pcs'?' selected':''}>pcs</option></select></td>
      <td><input type="date" value="${e.buyDate||todayISO()}" style="width:110px"></td>
      <td><input type="number" step="1" value="${+e.shelf||7}" style="width:50px"></td>
      <td>${badgeFor(e)}</td>
      <td class="right"><a class="btn" href="javascript:void(0)">保存</a><a class="btn" href="javascript:void(0)">删</a></td>`;
      const inputs=els('input',tr); const qtyEl=inputs[0], dateEl=inputs[1], shelfEl=inputs[2]; const unitEl=els('select',tr)[0]; const [saveBtn, delBtn]=els('.btn',tr).slice(-2);
      saveBtn.onclick=()=>{ e.qty=+qtyEl.value||0; e.unit=unitEl.value; e.buyDate=dateEl.value||todayISO(); e.shelf=+shelfEl.value||7; saveInventory(inv); renderTable(); };
      delBtn.onclick=()=>{ const i=inv.indexOf(e); if(i>=0){ inv.splice(i,1); saveInventory(inv); renderTable(); }}; tb.appendChild(tr);
    }
  } renderTable(); return wrap;
}

// 5. 购物清单
function renderShopping(pack){
  const inv=loadInventory(buildCatalog(pack)); const plan=S.load(S.keys.plan,[]); const map=pack.recipe_ingredients||{};
  const need={}; const addNeed=(n,q,u)=>{ const k=n+'|'+(u||'g'); need[k]=(need[k]||0)+(+q||0); };
  for(const p of plan){ for(const it of explodeCombinedItems(map[p.id]||[])){ if(typeof it.qty==='number') addNeed(it.item, it.qty*(p.servings||1), it.unit); }}
  const missing=[]; for(const [k,req] of Object.entries(need)){ const [n,u]=k.split('|'); const stock=(inv.filter(x=>x.name===n&&x.unit===u).reduce((s,x)=>s+(+x.qty||0),0)); const m=Math.max(0, Math.round((req-stock)*100)/100); if(m>0) missing.push({name:n, unit:u, qty:m}); }
  const d=document.createElement('div'); const h=document.createElement('h2'); h.className='section-title'; h.textContent='购物清单'; d.appendChild(h);
  const pd=document.createElement('div'); pd.className='card'; pd.innerHTML='<h3>今日计划</h3>'; const pl=document.createElement('div'); pd.appendChild(pl);
  function drawPlan(){ pl.innerHTML=''; if(plan.length===0){ const p=document.createElement('p'); p.className='small'; p.textContent='暂未添加菜谱。请去首页或菜谱页添加。'; pl.appendChild(p); return; }
    for(const p of plan){ const r=(pack.recipes||[]).find(x=>x.id===p.id); if(!r) continue; const row=document.createElement('div'); row.className='controls';
      row.innerHTML=`<span>${r.name}</span><span class="small">份数</span><input type="number" min="1" max="8" step="1" value="${p.servings||1}" style="width:80px"><a class="btn" href="javascript:void(0)">移除</a>`;
      const input=els('input',row)[0]; input.onchange=()=>{ const plans=S.load(S.keys.plan,[]); const it=plans.find(x=>x.id===p.id); if(it){ it.servings=+input.value||1; S.save(S.keys.plan,plans); onRoute(); } };
      els('.btn',row)[0].onclick=()=>{ const plans=S.load(S.keys.plan,[]); const i=plans.findIndex(x=>x.id===p.id); if(i>=0){ plans.splice(i,1); S.save(S.keys.plan,plans); onRoute(); } };
      pl.appendChild(row);
    }} drawPlan(); d.appendChild(pd);
  const tbl=document.createElement('table'); tbl.className='table'; tbl.innerHTML=`<thead><tr><th>食材</th><th>需购</th><th>单位</th><th class="right">操作</th></tr></thead><tbody></tbody>`; const tb=tbl.querySelector('tbody');
  if(missing.length===0){ const tr=document.createElement('tr'); tr.innerHTML='<td colspan="4" class="small">库存已满足，无需购买。</td>'; tb.appendChild(tr); }
  else { for(const m of missing){ const tr=document.createElement('tr'); tr.innerHTML=`<td>${m.name}</td><td>${m.qty}</td><td>${m.unit}</td><td class="right"><a class="btn" href="javascript:void(0)">标记已购</a></td>`; els('.btn',tr)[0].onclick=()=>{ const invv=S.load(S.keys.inventory,[]); addInventoryQty(invv,m.name,m.qty,m.unit,'raw'); tr.remove(); }; tb.appendChild(tr); } }
  d.appendChild(tbl);
  return d;
}

// 6. 编辑器页面
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
  wrap.querySelector('#saveBtn').onclick = ()=>{ const name = wrap.querySelector('#rName').value.trim(); if(!name) return alert('菜名不能为空'); const tags = wrap.querySelector('#rTags').value.split(/[，,]/).map(s=>s.trim()).filter(Boolean); overlay.recipes = overlay.recipes || {}; overlay.recipes[id] = { name, tags }; overlay.recipe_ingredients = overlay.recipe_ingredients || {}; const arr = []; els('tbody#rows tr', wrap).forEach(tr => { const [i1,i2] = els('input', tr); const sel = els('select', tr)[0]; const item = i1.value.trim(); if(!item) return; const qty = i2.value === '' ? null : Number(i2.value); const unit = sel.value || null; arr.push({ item, ...(qty===null?{}:{qty}), ...(unit?{unit}:{}) }); }); overlay.recipe_ingredients[id] = arr; if(overlay.deletes) delete overlay.deletes[id]; saveOverlay(overlay); alert('已保存'); history.back(); };
  wrap.querySelector('#hideBtn').onclick = ()=>{ if(!confirm('确定删除/隐藏？')) return; overlay.deletes = overlay.deletes || {}; if(overlay.deletes[id]) delete overlay.deletes[id]; else overlay.deletes[id] = true; saveOverlay(overlay); history.back(); };
  const rBtn = wrap.querySelector('#resetBtn'); if(rBtn) rBtn.onclick = ()=>{ if(!confirm('确定重置？')) return; if(overlay.recipes) delete overlay.recipes[id]; if(overlay.recipe_ingredients) delete overlay.recipe_ingredients[id]; if(overlay.deletes) delete overlay.deletes[id]; saveOverlay(overlay); app.innerHTML = ''; app.appendChild(renderRecipeEditor(id, base)); };
  return wrap;
}

// -------- Router --------
async function onRoute(){
  app.innerHTML='';
  const base = await loadBasePack();
  const overlay = loadOverlay();
  const pack = applyOverlay(base, overlay);
  let hash = location.hash.replace('#','');
  els('nav a').forEach(a=>a.classList.remove('active'));
  if(hash==='recipes') el('#nav-recipe').classList.add('active');
  else if(hash==='shopping') el('#nav-shop').classList.add('active');
  else if(!hash || hash==='inventory') el('#nav-home').classList.add('active');
  if(hash.startsWith('recipe-edit:')){ const id = hash.split(':')[1]; app.appendChild(renderRecipeEditor(id, base)); }
  else if(hash==='shopping'){ app.appendChild(renderShopping(pack)); }
  else if(hash==='recipes'){ app.appendChild(renderRecipes(pack)); }
  else { app.appendChild(renderHome(pack)); }
}
window.addEventListener('hashchange', onRoute); onRoute();
