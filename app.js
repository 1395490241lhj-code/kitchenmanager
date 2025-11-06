const el = (sel, root=document) => root.querySelector(sel);
const els = (sel, root=document) => Array.from(root.querySelectorAll(sel));
const app = el('#app');
const todayISO = () => new Date().toISOString().slice(0,10);

const S = { save(k, v){ localStorage.setItem(k, JSON.stringify(v)); },
  load(k, d){ try{ return JSON.parse(localStorage.getItem(k)) ?? d }catch{ return d } },
  keys: { inventory: 'km_v17_inventory', plan: 'km_v17_plan' } };

async function loadPack(){
  const url = new URL('./data/sichuan-recipes.json', location).href + '?v=17';
  try{ const res = await fetch(url, { cache: 'no-store' }); if(!res.ok) throw 0; return await res.json(); }
  catch{ return window.__FALLBACK_DATA__ || {recipes:[], recipe_ingredients:{}}; }
}
function buildCatalog(pack){
  const units = {}, set = new Set();
  for(const list of Object.values(pack.recipe_ingredients||{})){
    for(const it of list){ const n=(it.item||'').trim(); if(!n) continue; set.add(n); units[n]=units[n]||it.unit||'g'; }
  }
  return Array.from(set).sort().map(n=>({name:n, unit:units[n]||'g', shelf:guessShelfDays(n, units[n]||'g')}));
}
function guessShelfDays(name, unit){ const veg=['菜','叶','苔','苗','芹','香菜','葱','椒','瓜','番茄','西红柿','豆角','笋','蘑','菇','花菜','西兰花','菜花','茄子','豆腐','生菜','莴','空心菜','韭','蒜苗','青椒','黄瓜']; if(veg.some(w=>name.includes(w)))return 5; if(unit==='ml')return 30; if(unit==='pcs')return 14; return 7; }
function loadInventory(catalog){ const inv=S.load(S.keys.inventory,[]); for(const i of inv){ if(!i.unit){i.unit=(catalog.find(c=>c.name===i.name)?.unit)||'g'} if(!i.shelf){i.shelf=(catalog.find(c=>c.name===i.name)?.shelf)||7} } return inv; }
function saveInventory(inv){ S.save(S.keys.inventory, inv); }
function upsertInventory(inv, e){ const i=inv.findIndex(x=>x.name===e.name && (x.kind||'raw')===(e.kind||'raw')); if(i>=0) inv[i]={...inv[i],...e}; else inv.push(e); saveInventory(inv); }
function addInventoryQty(inv, name, qty, unit, kind='raw'){ const e=inv.find(x=>x.name===name && (x.kind||'raw')===kind); if(e){ e.qty=(+e.qty||0)+qty; e.unit=unit||e.unit; e.buyDate=e.buyDate||todayISO(); } else { inv.push({name, qty, unit:unit||'g', buyDate:todayISO(), kind, shelf:guessShelfDays(name, unit||'g')}); } saveInventory(inv); }
function daysBetween(a,b){ return Math.floor((new Date(b)-new Date(a))/86400000); }
function remainingDays(e){ const age=daysBetween(e.buyDate||todayISO(), todayISO()); return (+e.shelf||7)-age; }
function badgeFor(e){ const r=remainingDays(e); if(r<=1) return `<span class="kchip bad">即将过期 ${r}天</span>`; if(r<=3) return `<span class="kchip warn">优先消耗 ${r}天</span>`; return `<span class="kchip ok">新鲜 ${r}天</span>`; }

function renderRecipes(pack){
  const grid=document.createElement('div'); grid.className='grid'; const map=pack.recipe_ingredients||{}; const plan=new Set((S.load(S.keys.plan,[])).map(x=>x.id));
  (pack.recipes||[]).forEach(r=>{ const card=document.createElement('div'); card.className='card';
    card.innerHTML=`<h3>${r.name}</h3><p class="meta">${(r.tags||[]).join(' / ')}</p><div class="ings"></div><div class="controls"></div>`;
    const ul=document.createElement('ul'); ul.className='ing-list';
    for(const it of (map[r.id]||[])){ const q=(typeof it.qty==='number'&&isFinite(it.qty))?(it.qty+(it.unit||'')):''; const li=document.createElement('li'); li.textContent=q?`${it.item}  ${q}`:it.item; ul.appendChild(li); }
    card.querySelector('.ings').appendChild(ul);
    const btn=document.createElement('a'); btn.href='javascript:void(0)'; btn.className='btn'; btn.textContent=plan.has(r.id)?'已加入计划':'加入购物计划';
    btn.onclick=()=>{ const p=S.load(S.keys.plan,[]); const i=p.findIndex(x=>x.id===r.id); if(i>=0) p.splice(i,1); else p.push({id:r.id, servings:1}); S.save(S.keys.plan,p); onRoute(); };
    card.querySelector('.controls').appendChild(btn);
    grid.appendChild(card);
  }); return grid;
}
function renderRecommend(pack){ const d=document.createElement('div'); const h=document.createElement('h2'); h.className='section-title'; h.textContent='今日推荐'; d.appendChild(h); const sub={recipes:(pack.recipes||[]).slice(0,6), recipe_ingredients:pack.recipe_ingredients||{}}; d.appendChild(renderRecipes(sub)); return d; }

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
  const tbl=document.createElement('table'); tbl.className='table'; tbl.innerHTML=`
    <thead><tr><th>食材</th><th>数量</th><th>单位</th><th>购买日期</th><th>保质(天)</th><th>状态</th><th></th></tr></thead><tbody></tbody>`; wrap.appendChild(tbl);
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
      delBtn.onclick=()=>{ const i=inv.indexOf(e); if(i>=0){ inv.splice(i,1); saveInventory(inv); renderTable(); }};
      tb.appendChild(tr);
    }
  } renderTable(); return wrap;
}

function renderShopping(pack){
  const catalog=buildCatalog(pack); const inv=loadInventory(catalog); const plan=S.load(S.keys.plan,[]); const map=pack.recipe_ingredients||{};
  const need={}; const addNeed=(n,q,u)=>{ const k=n+'|'+(u||'g'); need[k]=(need[k]||0)+(+q||0); };
  for(const p of plan){ for(const it of (map[p.id]||[])){ if(typeof it.qty==='number') addNeed(it.item, it.qty*(p.servings||1), it.unit); }}
  const missing=[]; for(const [k,req] of Object.entries(need)){ const [n,u]=k.split('|'); const stock=inv.filter(x=>x.name===n&&x.unit===u).reduce((s,x)=>s+(+x.qty||0),0); const m=Math.max(0, Math.round((req-stock)*100)/100); if(m>0) missing.push({name:n, unit:u, qty:m}); }
  const d=document.createElement('div'); const h=document.createElement('h2'); h.className='section-title'; h.textContent='购物清单'; d.appendChild(h);
  const pd=document.createElement('div'); pd.className='card'; pd.innerHTML='<h3>今日计划</h3>'; const pl=document.createElement('div'); pd.appendChild(pl);
  function drawPlan(){ pl.innerHTML=''; if(plan.length===0){ const p=document.createElement('p'); p.className='small'; p.textContent='暂未添加菜谱。去“菜谱/推荐”点“加入购物计划”。'; pl.appendChild(p); return; }
    for(const p of plan){ const r=(pack.recipes||[]).find(x=>x.id===p.id); if(!r) continue; const row=document.createElement('div'); row.className='controls';
      row.innerHTML=`<span>${r.name}</span><span class="small">份数</span><input type="number" min="1" max="8" step="1" value="${p.servings||1}" style="width:80px"><a class="btn" href="javascript:void(0)">移除</a>`;
      const input=els('input',row)[0]; input.onchange=()=>{ const plans=S.load(S.keys.plan,[]); const it=plans.find(x=>x.id===p.id); if(it){ it.servings=+input.value||1; S.save(S.keys.plan,plans); onRoute(); } };
      els('.btn',row)[0].onclick=()=>{ const plans=S.load(S.keys.plan,[]); const i=plans.findIndex(x=>x.id===p.id); if(i>=0){ plans.splice(i,1); S.save(S.keys.plan,plans); onRoute(); } };
      pl.appendChild(row);
    }}
  drawPlan(); d.appendChild(pd);
  const tbl=document.createElement('table'); tbl.className='table'; tbl.innerHTML=`<thead><tr><th>食材</th><th>缺少数量</th><th>单位</th><th class="right">操作</th></tr></thead><tbody></tbody>`; const tb=tbl.querySelector('tbody');
  if(missing.length===0){ const tr=document.createElement('tr'); tr.innerHTML='<td colspan="4" class="small">库存已满足，不需要购买。</td>'; tb.appendChild(tr); }
  else { for(const m of missing){ const tr=document.createElement('tr'); tr.innerHTML=`<td>${m.name}</td><td>${m.qty}</td><td>${m.unit}</td><td class="right"><a class="btn" href="javascript:void(0)">标记已购 → 入库</a></td>`; els('.btn',tr)[0].onclick=()=>{ const invv=S.load(S.keys.inventory,[]); addInventoryQty(invv,m.name,m.qty,m.unit,'raw'); tr.remove(); }; tb.appendChild(tr); } }
  d.appendChild(tbl);
  const tools=document.createElement('div'); tools.className='controls'; const copy=document.createElement('a'); copy.className='btn'; copy.textContent='复制清单'; copy.onclick=()=>{ const lines=missing.map(m=>`${m.name} ${m.qty}${m.unit}`); navigator.clipboard.writeText(lines.join('\\n')).then(()=>alert('已复制到剪贴板')); }; tools.appendChild(copy); d.appendChild(tools);
  return d;
}

async function onRoute(){ app.innerHTML=''; const pack=await loadPack(); const hash=(location.hash||'#recipes').replace('#',''); if(hash==='recommend') app.appendChild(renderRecommend(pack));
  else if(hash==='inventory') app.appendChild(renderInventory(pack)); else if(hash==='shopping') app.appendChild(renderShopping(pack)); else app.appendChild(renderRecipes(pack)); }
window.addEventListener('hashchange', onRoute); onRoute();

window.__FALLBACK_DATA__={"recipes":[{"id":"ex-huiguorou-0001","name":"回锅肉","tags":["川菜","肉食类"]},{"id":"ex-yuxiangroupian-0002","name":"鱼香肉片","tags":["川菜","肉食类"]},{"id":"ex-shuizhu-0003","name":"水煮肉片","tags":["川菜","肉食类"]}],"recipe_ingredients":{"ex-huiguorou-0001":[{"item":"猪肉","qty":650,"unit":"g"},{"item":"蒜苗","qty":100,"unit":"g"}],"ex-yuxiangroupian-0002":[{"item":"瘦肉","qty":250,"unit":"g"},{"item":"木耳","qty":50,"unit":"g"},{"item":"胡萝卜","qty":60,"unit":"g"}],"ex-shuizhu-0003":[{"item":"猪里脊","qty":250,"unit":"g"},{"item":"白菜嫩叶","qty":100,"unit":"g"}]}};
