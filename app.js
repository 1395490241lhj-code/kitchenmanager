// v19 app.js（含在线编辑：overlay 存在 localStorage，不改底层文件）
const el = (sel, root=document) => root.querySelector(sel);
const els = (sel, root=document) => Array.from(root.querySelectorAll(sel));
const app = el('#app');
const todayISO = () => new Date().toISOString().slice(0,10);

// storage
const S = {
  save(k, v){ localStorage.setItem(k, JSON.stringify(v)); },
  load(k, d){ try{ return JSON.parse(localStorage.getItem(k)) ?? d }catch{ return d } },
  keys: { inventory:'km_v19_inventory', plan:'km_v19_plan', overlay:'km_v19_overlay' }
};

// base data
async function loadBasePack(){
  const url = new URL('./data/sichuan-recipes.json', location).href + '?v=19';
  try{ const res = await fetch(url, { cache:'no-store' }); if(!res.ok) throw 0; return await res.json(); }
  catch{ return {recipes:[], recipe_ingredients:{}}; }
}

// overlay (user edits) schema
// { version:1, recipes: {id:{name?,tags?}}, recipe_ingredients: {id:[{item,qty?,unit?},...]}, deletes: {id:true} }
function emptyOverlay(){ return {version:1, recipes:{}, recipe_ingredients:{}, deletes:{}}; }
function loadOverlay(){ return S.load(S.keys.overlay, emptyOverlay()); }
function saveOverlay(o){ S.save(S.keys.overlay, o); }

// merge base + overlay
function applyOverlay(base, overlay){
  const recipes = [];
  const ingMap = JSON.parse(JSON.stringify(base.recipe_ingredients || {}));
  const baseMap = new Map((base.recipes||[]).map(r => [r.id, {...r}]));
  // deletes
  const del = overlay.deletes || {};
  for(const [id, flag] of Object.entries(del)){ if(flag){ baseMap.delete(id); delete ingMap[id]; } }
  // overrides (name/tags)
  const ro = overlay.recipes || {};
  for(const [id, ov] of Object.entries(ro)){
    if(!baseMap.has(id)) baseMap.set(id, {id, name: ov.name || ('未命名-'+id.slice(-4)), tags: ov.tags || []});
    else baseMap.set(id, {...baseMap.get(id), ...ov});
  }
  // ingredient overrides (replace list if provided)
  const io = overlay.recipe_ingredients || {};
  for(const [id, list] of Object.entries(io)){ ingMap[id] = list.slice(); }
  // collect
  for(const r of baseMap.values()) recipes.push(r);
  // add purely-new recipes in overlay (id 以 u- 开头)
  for(const [id, ov] of Object.entries(ro)){
    if(/^u-/.test(id) && !recipes.find(x=>x.id===id)){
      recipes.push({id, name: ov.name || ('自定义-'+id.slice(-4)), tags: ov.tags || ['自定义']});
      if(!ingMap[id]) ingMap[id] = (io[id] || []);
    }
  }
  // sort by name
  recipes.sort((a,b)=> a.name.localeCompare(b.name, 'zh-Hans-CN'));
  return {recipes, recipe_ingredients:ingMap};
}

// ingredient utils (keep v18 fix)
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
    }else{
      out.push(it);
    }
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

// Renderers (recipes/recommend/inventory/shopping same as v18, but use patched pack)
function recipeCard(r, list){
  const card=document.createElement('div'); card.className='card';
  card.innerHTML=`<h3>${r.name}</h3><p class="meta">${(r.tags||[]).join(' / ')}</p><div class="ings"></div><div class="controls"></div>`;
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
  const grid=document.createElement('div'); grid.className='grid';
  const map=pack.recipe_ingredients||{};
  (pack.recipes||[]).forEach(r=>{ grid.appendChild(recipeCard(r, map[r.id])); });
  return grid;
}
function renderRecommend(pack){
  const d=document.createElement('div'); const h=document.createElement('h2'); h.className='section-title'; h.textContent='今日推荐'; d.appendChild(h);
  const sub={recipes:(pack.recipes||[]).slice(0,6), recipe_ingredients:pack.recipe_ingredients||{}};
  d.appendChild(renderRecipes(sub)); return d;
}

// inventory & shopping (same as v18 simplified)
function daysBetween(a,b){ return Math.floor((new Date(b)-new Date(a))/86400000); }
function remainingDays(e){ const age=daysBetween(e.buyDate||todayISO(), todayISO()); return (+e.shelf||7)-age; }
function badgeFor(e){ const r=remainingDays(e); if(r<=1) return `<span class="kchip bad">即将过期 ${r}天</span>`; if(r<=3) return `<span class="kchip warn">优先消耗 ${r}天</span>`; return `<span class="kchip ok">新鲜 ${r}天</span>`; }
function upsertInventory(inv, e){ const i=inv.findIndex(x=>x.name===e.name && (x.kind||'raw')===(e.kind||'raw')); if(i>=0) inv[i]={...inv[i],...e}; else inv.push(e); saveInventory(inv); }
function addInventoryQty(inv, name, qty, unit, kind='raw'){ const e=inv.find(x=>x.name===name && (x.kind||'raw')===kind); if(e){ e.qty=(+e.qty||0)+qty; e.unit=unit||e.unit; e.buyDate=e.buyDate||todayISO(); } else { inv.push({name, qty, unit:unit||'g', buyDate:todayISO(), kind, shelf:guessShelfDays(name, unit||'g')}); } saveInventory(inv); }

function renderInventory(pack){
  const catalog=buildCatalog(pack); const inv=loadInventory(catalog);
  const wrap=document.createElement('div'); const h=document.createElement('h2'); h.className='section-title'; h.textContent='库存管理'; wrap.appendChild(h);
  const ctr=document.createElement('div'); ctr.className='controls'; ctr.innerHTML=`
    <select id="addName"><option value="">选择食材</option>${catalog.map(c=>`<option>${c.name}</option>`).join('')}</select>
    <input id="addQty" type="number" step="1" placeholder="数量">
    <select id="addUnit"><option value="g">g</option><option value="ml">ml</option><option value="pcs">pcs</option></select>
    <input id="addDate" type="date" value="${todayISO()}">
    <select id="addKind"><option value="raw">原材料</option><option value="semi">半成品</option></select>
    <button id="addBtn" class="btn">添加 / 更新</button>`; wrap.appendChild(ctr);
  ctr.querySelector('#addBtn').onclick=()=>{ const name=ctr.querySelector('#addName').value.trim(); if(!name) return alert('请选择食材');
    const qty=+ctr.querySelector('#addQty').value||0; const unit=ctr.querySelector('#addUnit').value; const date=ctr.querySelector('#addDate').value||todayISO(); const kind=ctr.querySelector('#addKind').value;
    const cat=catalog.find(c=>c.name===name); upsertInventory(inv,{name, qty, unit, buyDate:date, kind, shelf:(cat&&cat.shelf)||7}); renderTable(); };
  const tbl=document.createElement('table'); tbl.className='table'; tbl.innerHTML=`<thead><tr><th>食材</th><th>数量</th><th>单位</th><th>购买日期</th><th>保质(天)</th><th>状态</th><th></th></tr></thead><tbody></tbody>`; wrap.appendChild(tbl);
  function renderTable(){ const tb=tbl.querySelector('tbody'); tb.innerHTML=''; inv.sort((a,b)=>remainingDays(a)-remainingDays(b));
    for(const e of inv){ const tr=document.createElement('tr'); tr.innerHTML=`
      <td>${e.name}<div class="small">${(e.kind||'raw')==='semi'?'半成品':'原材料'}</div></td>
      <td class="qty"><input type="number" step="1" value="${+e.qty||0}"></td>
      <td><select><option value="g"${e.unit==='g'?' selected':''}>g</option><option value="ml"${e.unit==='ml'?' selected':''}>ml</option><option value="pcs"${e.unit==='pcs'?' selected':''}>pcs</option></select></td>
      <td><input type="date" value="${e.buyDate||todayISO()}"></td>
      <td><input type="number" step="1" value="${+e.shelf||7}"></td>
      <td>${badgeFor(e)}</td>
      <td class="right"><a class="btn" href="javascript:void(0)">保存</a><a class="btn" href="javascript:void(0)">删除</a></td>`;
      const inputs=els('input',tr); const qtyEl=inputs[0], dateEl=inputs[1], shelfEl=inputs[2]; const unitEl=els('select',tr)[0]; const [saveBtn, delBtn]=els('.btn',tr).slice(-2);
      saveBtn.onclick=()=>{ e.qty=+qtyEl.value||0; e.unit=unitEl.value; e.buyDate=dateEl.value||todayISO(); e.shelf=+shelfEl.value||7; saveInventory(inv); renderTable(); };
      delBtn.onclick=()=>{ const i=inv.indexOf(e); if(i>=0){ inv.splice(i,1); saveInventory(inv); renderTable(); }}; tb.appendChild(tr);
    }
  } renderTable(); return wrap;
}

function renderShopping(pack){
  const inv=loadInventory(buildCatalog(pack)); const plan=S.load(S.keys.plan,[]); const map=pack.recipe_ingredients||{};
  const need={}; const addNeed=(n,q,u)=>{ const k=n+'|'+(u||'g'); need[k]=(need[k]||0)+(+q||0); };
  for(const p of plan){ for(const it of explodeCombinedItems(map[p.id]||[])){ if(typeof it.qty==='number') addNeed(it.item, it.qty*(p.servings||1), it.unit); }}
  const missing=[]; for(const [k,req] of Object.entries(need)){ const [n,u]=k.split('|'); const stock=(inv.filter(x=>x.name===n&&x.unit===u).reduce((s,x)=>s+(+x.qty||0),0)); const m=Math.max(0, Math.round((req-stock)*100)/100); if(m>0) missing.push({name:n, unit:u, qty:m}); }
  const d=document.createElement('div'); const h=document.createElement('h2'); h.className='section-title'; h.textContent='购物清单'; d.appendChild(h);
  const pd=document.createElement('div'); pd.className='card'; pd.innerHTML='<h3>今日计划</h3>'; const pl=document.createElement('div'); pd.appendChild(pl);
  function drawPlan(){ pl.innerHTML=''; if(plan.length===0){ const p=document.createElement('p'); p.className='small'; p.textContent='暂未添加菜谱。去“菜谱/推荐”点“加入购物计划”。'; pl.appendChild(p); return; }
    for(const p of plan){ const r=(pack.recipes||[]).find(x=>x.id===p.id); if(!r) continue; const row=document.createElement('div'); row.className='controls';
      row.innerHTML=`<span>${r.name}</span><span class="small">份数</span><input type="number" min="1" max="8" step="1" value="${p.servings||1}" style="width:80px"><a class="btn" href="javascript:void(0)">移除</a>`;
      const input=els('input',row)[0]; input.onchange=()=>{ const plans=S.load(S.keys.plan,[]); const it=plans.find(x=>x.id===p.id); if(it){ it.servings=+input.value||1; S.save(S.keys.plan,plans); onRoute(); } };
      els('.btn',row)[0].onclick=()=>{ const plans=S.load(S.keys.plan,[]); const i=plans.findIndex(x=>x.id===p.id); if(i>=0){ plans.splice(i,1); S.save(S.keys.plan,plans); onRoute(); } };
      pl.appendChild(row);
    }} drawPlan(); d.appendChild(pd);
  const tbl=document.createElement('table'); tbl.className='table'; tbl.innerHTML=`<thead><tr><th>食材</th><th>缺少数量</th><th>单位</th><th class="right">操作</th></tr></thead><tbody></tbody>`; const tb=tbl.querySelector('tbody');
  if(missing.length===0){ const tr=document.createElement('tr'); tr.innerHTML='<td colspan="4" class="small">库存已满足，不需要购买。</td>'; tb.appendChild(tr); }
  else { for(const m of missing){ const tr=document.createElement('tr'); tr.innerHTML=`<td>${m.name}</td><td>${m.qty}</td><td>${m.unit}</td><td class="right"><a class="btn" href="javascript:void(0)">标记已购 → 入库</a></td>`; els('.btn',tr)[0].onclick=()=>{ const invv=S.load(S.keys.inventory,[]); addInventoryQty(invv,m.name,m.qty,m.unit,'raw'); tr.remove(); }; tb.appendChild(tr); } }
  d.appendChild(tbl);
  const tools=document.createElement('div'); tools.className='controls'; const copy=document.createElement('a'); copy.className='btn'; copy.textContent='复制清单'; copy.onclick=()=>{ const lines=missing.map(m=>`${m.name} ${m.qty}${m.unit}`); navigator.clipboard.writeText(lines.join('\\n')).then(()=>alert('已复制到剪贴板')); }; tools.appendChild(copy); d.appendChild(tools);
  return d;
}

// -------- Editor (Online) --------
function genId(){ return 'u-' + Math.random().toString(36).slice(2,8) + '-' + Date.now().toString(36).slice(-4); }

function renderEditor(base){
  const overlay = loadOverlay();
  const pack = applyOverlay(base, overlay);

  const wrap = document.createElement('div'); wrap.className='editor';

  // left list
  const left = document.createElement('div'); left.className='list';
  left.innerHTML = `<div class="controls">
    <input class="search" placeholder="搜索菜名">
    <a class="btn" id="newBtn">新建菜谱</a>
    <a class="btn" id="exportBtn">导出补丁</a>
    <label class="btn"><input type="file" id="importFile" accept="application/json" hidden>导入补丁</label>
    <a class="btn" id="clearBtn" title="仅清除补丁，不影响底层文件">清空补丁</a>
  </div>
  <div id="list"></div>`;
  wrap.appendChild(left);

  const listDiv = left.querySelector('#list');
  function renderList(filter=''){
    const f = filter.trim();
    const arr = (pack.recipes||[]).filter(r => !f || r.name.includes(f));
    listDiv.innerHTML = '';
    arr.forEach(r => {
      const row = document.createElement('div'); row.className='controls';
      const del = (overlay.deletes||{})[r.id];
      row.innerHTML = `<a class="btn" data-id="${r.id}">${r.name}</a> ${del?'<span class="badge">（已在补丁中隐藏）</span>':''}`;
      els('.btn', row)[0].onclick = () => openRecipe(r.id);
      listDiv.appendChild(row);
    });
  }
  renderList();
  left.querySelector('.search').oninput = (e)=> renderList(e.target.value);

  // right panel
  const right = document.createElement('div'); right.className='panel';
  right.innerHTML = `<h3>编辑区</h3><div id="pane" class="small">从左侧选择一个菜谱，或点击“新建菜谱”。</div>`;
  wrap.appendChild(right);
  const pane = right.querySelector('#pane');

  function openRecipe(id){
    const baseIng = base.recipe_ingredients || {};
    const overIng = overlay.recipe_ingredients || {};
    // merged recipe
    const rBase = (base.recipes||[]).find(x => x.id===id);
    const rOv = (overlay.recipes||{})[id] || {};
    const r = {...(rBase||{id}), ...rOv};
    const items = (overIng[id] ?? baseIng[id] ?? []).map(x => ({...x}));
    const isNew = /^u-/.test(id) && !rBase;

    pane.innerHTML = `
      <div class="controls">
        <label>菜名</label>
        <input id="rName" value="${r.name||''}" placeholder="菜名">
        <label>标签(逗号分隔)</label>
        <input id="rTags" value="${(r.tags||[]).join(',')}" placeholder="例如：川菜,家常">
        <span class="badge">${isNew?'[自定义菜谱]':'[来源：基础数据]'}</span>
      </div>
      <table class="table">
        <thead><tr><th>用料</th><th>数量</th><th>单位</th><th class="right"><a class="btn" id="addRow">新增用料</a></th></tr></thead>
        <tbody id="rows"></tbody>
      </table>
      <div class="controls right">
        <a class="btn" id="hideBtn">${(overlay.deletes||{})[id]?'取消隐藏':'在补丁中隐藏'}</a>
        <a class="btn" id="resetBtn">恢复原版</a>
        <a class="btn" id="saveBtn">保存到补丁</a>
      </div>
    `;
    const tbody = pane.querySelector('#rows');

    function addRow(item='', qty='', unit='g'){
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td><input placeholder="食材名" value="${item}"></td>
        <td><input type="number" step="1" placeholder="" value="${qty}"></td>
        <td>
          <select>
            <option value="g"${unit==='g'?' selected':''}>g</option>
            <option value="ml"${unit==='ml'?' selected':''}>ml</option>
            <option value="pcs"${unit==='pcs'?' selected':''}>pcs</option>
          </select>
        </td>
        <td class="right"><a class="btn">删除</a></td>`;
      els('.btn', tr)[0].onclick = ()=> tr.remove();
      tbody.appendChild(tr);
    }
    items.forEach(it => addRow(it.item || '', (typeof it.qty==='number' && isFinite(it.qty))? it.qty : '', it.unit || 'g'));
    pane.querySelector('#addRow').onclick = ()=> addRow();

    pane.querySelector('#saveBtn').onclick = ()=>{
      const name = pane.querySelector('#rName').value.trim();
      const tags = pane.querySelector('#rTags').value.split(',').map(s=>s.trim()).filter(Boolean);
      overlay.recipes = overlay.recipes || {};
      overlay.recipes[id] = { name, tags };
      overlay.recipe_ingredients = overlay.recipe_ingredients || {};
      const arr = [];
      els('tbody#rows tr', pane).forEach(tr => {
        const [i1,i2] = els('input', tr);
        const sel = els('select', tr)[0];
        const item = i1.value.trim();
        if(!item) return;
        const qty = i2.value === '' ? null : Number(i2.value);
        const unit = sel.value || null;
        arr.push({ item, ...(qty===null?{}:{qty}), ...(unit?{unit}:{}) });
      });
      overlay.recipe_ingredients[id] = arr;
      // not hidden when saved
      if(overlay.deletes) delete overlay.deletes[id];
      saveOverlay(overlay);
      alert('已保存到补丁（未修改底层文件）。');
    };

    pane.querySelector('#resetBtn').onclick = ()=>{
      if(overlay.recipes) delete overlay.recipes[id];
      if(overlay.recipe_ingredients) delete overlay.recipe_ingredients[id];
      if(overlay.deletes) delete overlay.deletes[id];
      saveOverlay(overlay); openRecipe(id);
    };

    pane.querySelector('#hideBtn').onclick = ()=>{
      overlay.deletes = overlay.deletes || {};
      if(overlay.deletes[id]) delete overlay.deletes[id];
      else overlay.deletes[id] = true;
      saveOverlay(overlay); openRecipe(id);
    };
  }

  left.querySelector('#newBtn').onclick = ()=>{
    const id = genId();
    // preset a blank in overlay
    overlay.recipes = overlay.recipes || {};
    overlay.recipes[id] = { name: '新菜谱', tags: ['自定义'] };
    overlay.recipe_ingredients = overlay.recipe_ingredients || {};
    overlay.recipe_ingredients[id] = [{item:'', qty:null, unit:'g'}];
    saveOverlay(overlay);
    openRecipe(id);
  };

  left.querySelector('#exportBtn').onclick = ()=>{
    const blob = new Blob([JSON.stringify(overlay, null, 2)], {type:'application/json'});
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'kitchen-overlay.json';
    a.click();
    URL.revokeObjectURL(a.href);
  };
  left.querySelector('#importFile').onchange = (e)=>{
    const file = e.target.files[0]; if(!file) return;
    const reader = new FileReader();
    reader.onload = ()=>{
      try{
        const incoming = JSON.parse(reader.result);
        const cur = loadOverlay();
        const merged = {...cur};
        merged.recipes = {...cur.recipes, ...(incoming.recipes||{})};
        merged.recipe_ingredients = {...cur.recipe_ingredients, ...(incoming.recipe_ingredients||{})};
        merged.deletes = {...cur.deletes, ...(incoming.deletes||{})};
        saveOverlay(merged);
        alert('已导入补丁。');
        onRoute();
      }catch(err){ alert('导入失败：'+err.message); }
    };
    reader.readAsText(file, 'utf-8');
  };
  left.querySelector('#clearBtn').onclick = ()=>{
    if(confirm('确认清空本地补丁？此操作不会影响底层文件。')){
      saveOverlay(emptyOverlay()); onRoute();
    }
  };

  return wrap;
}

// Router
async function onRoute(){
  app.innerHTML='';
  const base = await loadBasePack();
  const overlay = loadOverlay();
  const pack = applyOverlay(base, overlay);

  const hash = (location.hash || '#recipes').replace('#','');
  if(hash==='recommend'){ app.appendChild(renderRecommend(pack)); }
  else if(hash==='inventory'){ app.appendChild(renderInventory(pack)); }
  else if(hash==='shopping'){ app.appendChild(renderShopping(pack)); }
  else if(hash==='editor'){ app.appendChild(renderEditor(base)); }
  else { app.appendChild(renderRecipes(pack)); }
}
window.addEventListener('hashchange', onRoute); onRoute();
