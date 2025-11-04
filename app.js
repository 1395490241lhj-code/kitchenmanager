
// ---- helpers ----
function jget(k, def){ try{ const v = localStorage.getItem(k); return v? JSON.parse(v): def } catch(e){ return def } }
function jset(k, v){ try{ localStorage.setItem(k, JSON.stringify(v)); }catch(e){} }
function today(){ return new Date().toISOString().slice(0,10) }
function plusDays(d, n){ return new Date(new Date(d).getTime()+n*86400000).toISOString().slice(0,10) }
function ddays(a,b){ return Math.ceil((new Date(a)-new Date(b))/86400000) }
function lastId(arr){ return arr && arr.length ? (arr[arr.length-1].id||0) : 0 }

// ---- initial seed (only when empty) ----
(function seed(){
  if (jget('ingredients', null)) return;
  const ingredients=[
    {id:1,name:'西兰花',unit:'g',shelf:4},{id:2,name:'鸡胸',unit:'g',shelf:2},{id:3,name:'蒜',unit:'g',shelf:10},
    {id:4,name:'番茄',unit:'g',shelf:6},{id:5,name:'鸡蛋',unit:'pcs',shelf:14},{id:6,name:'土豆',unit:'g',shelf:20},
    {id:7,name:'牛腩',unit:'g',shelf:3},{id:8,name:'洋葱',unit:'g',shelf:10},{id:9,name:'青椒',unit:'g',shelf:7},{id:10,name:'菠菜',unit:'g',shelf:4},{id:11,name:'蘑菇',unit:'g',shelf:3},
  ];
  const recipes=[
    {id:101,name:'西兰花炒鸡胸',tags:['家常','清淡']},
    {id:102,name:'番茄炒蛋',tags:['家常']},
    {id:103,name:'土豆烧牛肉',tags:['家常','炖']},
    {id:104,name:'青椒土豆丝',tags:['家常','快手']},
    {id:105,name:'蘑菇炒菠菜',tags:['清淡','素食']},
  ];
  const rIngs=[
    {recipeId:101,ingId:1,name:'西兰花',need:300,unit:'g'},
    {recipeId:101,ingId:2,name:'鸡胸',need:250,unit:'g'},
    {recipeId:101,ingId:3,name:'蒜',need:10,unit:'g'},
    {recipeId:102,ingId:4,name:'番茄',need:300,unit:'g'},
    {recipeId:102,ingId:5,name:'鸡蛋',need:3,unit:'pcs'},
    {recipeId:102,ingId:3,name:'蒜',need:5,unit:'g'},
    {recipeId:103,ingId:7,name:'牛腩',need:400,unit:'g'},
    {recipeId:103,ingId:6,name:'土豆',need:300,unit:'g'},
    {recipeId:103,ingId:8,name:'洋葱',need:100,unit:'g'},
    {recipeId:104,ingId:9,name:'青椒',need:100,unit:'g'},
    {recipeId:104,ingId:6,name:'土豆',need:250,unit:'g'},
    {recipeId:104,ingId:3,name:'蒜',need:10,unit:'g'},
    {recipeId:105,ingId:11,name:'蘑菇',need:200,unit:'g'},
    {recipeId:105,ingId:10,name:'菠菜',need:250,unit:'g'},
    {recipeId:105,ingId:3,name:'蒜',need:10,unit:'g'},
  ];
  const t=today();
  const stock=[
    {id:1,ingId:1,qty:320,unit:'g',purchase:t,expire:plusDays(t,3),location:'fridge'},
    {id:2,ingId:2,qty:220,unit:'g',purchase:t,expire:plusDays(t,2),location:'fridge'},
    {id:3,ingId:4,qty:400,unit:'g',purchase:t,expire:plusDays(t,5),location:'fridge'},
    {id:4,ingId:6,qty:800,unit:'g',purchase:t,expire:plusDays(t,14),location:'pantry'}
  ];
  jset('ingredients',ingredients); jset('recipes',recipes); jset('recipeIngs',rIngs); jset('stock',stock);
  jset('prefs',{disliked:[],allergens:[],cuisines:['家常','川菜'],spice:2}); jset('list',[]);
})();

// ---- state getters ----
const S = {
  get ings(){ return jget('ingredients',[]) }, set ings(v){ jset('ingredients',v) },
  get stock(){ return jget('stock',[]) }, set stock(v){ jset('stock',v) },
  get recipes(){ return jget('recipes',[]) }, set recipes(v){ jset('recipes',v) },
  get rIngs(){ return jget('recipeIngs',[]) }, set rIngs(v){ jset('recipeIngs',v) },
  get prefs(){ return jget('prefs',{disliked:[],allergens:[],cuisines:[],spice:1}) }, set prefs(v){ jset('prefs',v) },
  get list(){ return jget('list',[]) }, set list(v){ jset('list',v) },
};
function ingName(id){ const it = S.ings.find(x=>x.id===id); return it? it.name : '#'+id }
function perishScore(b){ const shelf=Math.max(1, ddays(b.expire,b.purchase)); const left=ddays(b.expire,today()); return Math.max(0,Math.min(1,1-left/shelf)) }
function aggregateStock(){
  const m=new Map(); for(const b of S.stock){ const v=m.get(b.ingId)||{available:0,perish:0}; v.available+=b.qty; v.perish=Math.max(v.perish,perishScore(b)); m.set(b.ingId,v) } return m
}

// ---- recommendation ----
function recommendTop(K){
  const stock=aggregateStock(); const pref=S.prefs;
  const out=[];
  for(const r of S.recipes){
    const list=S.rIngs.filter(x=>x.recipeId===r.id);
    if(pref.allergens && list.some(it=>pref.allergens.indexOf(it.name)>=0)) continue;
    if(pref.disliked && list.some(it=>pref.disliked.indexOf(it.name)>=0)) continue;
    let coverSum=0, perishSum=0, miss=0, N=list.length;
    const breakdown=list.map(it=>{
      const s=stock.get(it.ingId)||{available:0,perish:0}; const cover=Math.min(1,(s.available||0)/(it.need||1));
      if(cover<1) miss++; coverSum+=cover; perishSum+= (s.perish||0)*cover;
      return {name:ingName(it.ingId),avail:s.available||0,need:it.need,perish:s.perish||0};
    });
    const cover=N?coverSum/N:0; const perishWeighted=N?perishSum/N:0; const tasteBonus=(r.tags||[]).some(t=> (pref.cuisines||[]).indexOf(t)>=0)?0.1:0;
    const score=0.45*perishWeighted + 0.35*cover - 0.15*miss + 0.05*tasteBonus;
    out.push({recipe:r,score,cover,miss,perishWeighted,breakdown});
  }
  out.sort((a,b)=>b.score-a.score);
  return out.slice(0,K||5);
}
function diffForRecipe(recipeId){
  const stock=aggregateStock(); const res=[];
  for(const it of S.rIngs.filter(x=>x.recipeId===recipeId)){
    const avail=(stock.get(it.ingId)||{available:0}).available; const short=Math.max(0, (it.need||0)- (avail||0));
    if(short>0) res.push({name:ingName(it.ingId),shortage:short,unit:it.unit});
  }
  return res;
}
function cookAndDeduct(recipeId){
  const items=S.rIngs.filter(x=>x.recipeId===recipeId); const batches=S.stock.slice().sort((a,b)=> (a.expire<b.expire?-1:1));
  for(const it of items){
    let remaining=it.need;
    for(const b of batches){
      if(b.ingId!==it.ingId || remaining<=0) continue;
      const take=Math.min(b.qty, remaining); b.qty-=take; remaining-=take;
      const idx=S.stock.findIndex(x=>x.id===b.id); if(b.qty<=0){ S.stock.splice(idx,1) } else { S.stock[idx]=b }
    }
  }
  jset('stock',S.stock);
}

// ---- UI helpers ----
function $(s){ return document.querySelector(s) }
function chip(t){ return `<span class="chip">${t}</span>` }
function fmt(q,u){ if(u==='pcs') return `${t}个`; if(q>=1000) return `${(q/1000).toFixed(1)}${u==='g'?'kg':'L'}`; return `${q}${u}` }

// ---- PAGES ----
function renderRecommend(){
  const res=recommendTop(6);
  if(!res.length){ $('#page').innerHTML = `<div class="card">没有可推荐的菜谱。请先添加库存与菜谱。</div>`; return; }
  $('#page').innerHTML = res.map(it=>`
    <div class="card">
      <div class="row" style="justify-content:space-between">
        <h3 class="title">${it.recipe.name}</h3>
        ${chip('推荐分 '+it.score.toFixed(2))}
      </div>
      <div class="kpi">
        ${chip('覆盖率 '+Math.round(it.cover*100)+'%')}
        ${chip('缺料 '+it.miss+' 项')}
        ${chip('易腐加权 '+Math.round(it.perishWeighted*100)+'%')}
      </div>
      <div class="muted" style="margin-top:8px">
        将消耗：${it.breakdown.filter(b=>b.perish>0.4).map(b=>b.name).join('、') || '普通食材'}
      </div>
      <div style="margin-top:8px">
        ${(function(){ const miss=diffForRecipe(it.recipe.id); if(!miss.length) return ''; return `<div class="label">缺料清单：</div>
        <ul class="list">` + miss.map(m=>`<li class="row" style="justify-content:space-between"><span>${m.name}</span><span class="muted">${m.shortage}${m.unit||''}</span></li>`).join('') + `</ul>` })()}
      </div>
      <div class="row" style="margin-top:12px">
        <button class="ok" onclick="onCook(${it.recipe.id})">我就做这个</button>
        <button class="ghost" onclick="onAddMissing(${it.recipe.id})">加入购物清单</button>
      </div>
    </div>
  `).join('');
}
function renderInventory(){
  const bs=S.stock.slice().sort((a,b)=> (a.expire<b.expire?-1:1));
  function badge(b){ const left=ddays(b.expire,today()); const color=left<=0?'danger': (1-left/Math.max(1,ddays(b.expire,b.purchase)))>0.7?'warn':'ok'; const label=left<=0?'已过期':`剩 ${left} 天`; return `<span class="chip"><span class="muted">到期</span> ${label}</span>` }
  $('#page').innerHTML = `
    <div class="card">
      <h3 class="title">添加库存（按批次）</h3>
      <div class="row"><input id="ingName" placeholder="食材名称（如：西兰花）"></div>
      <div class="row">
        <input id="qty" type="number" placeholder="数量">
        <select id="unit"><option value="g">g</option><option value="ml">ml</option><option value="pcs">个</option></select>
        <input id="days" type="number" placeholder="保质期（天）" value="3">
        <select id="loc"><option value="fridge">冷藏</option><option value="freezer">冷冻</option><option value="pantry">常温</option></select>
      </div>
      <div class="row" style="margin-top:8px"><button onclick="onAddBatch()">保存</button></div>
    </div>
    <div class="card"><h3 class="title">当前库存</h3>
      <div class="list">
        ${bs.map(b=>`
          <div class="row" style="justify-content:space-between">
            <div><div>${ingName(b.ingId)} · ${b.qty}${b.unit}</div><div class="muted">购入 ${b.purchase} · 到期 ${b.expire}</div></div>
            <div class="row" style="gap:8px">${badge(b)}<button class="ghost" onclick="onRemoveBatch(${b.id})">删除</button></div>
          </div>
        `).join('') || '<div class="muted">暂无库存，先添加一些吧。</div>'}
      </div>
    </div>`;
}
function renderRecipes(){
  const rs=S.recipes, rI=S.rIngs;
  $('#page').innerHTML = `
    <div class="card">
      <h3 class="title">新增菜谱</h3>
      <div class="row">
        <input id="rname" placeholder="菜名"><input id="rtime" type="number" placeholder="时长(min)" value="15">
        <button onclick="onAddRecipe()">保存</button>
      </div>
    </div>
    ${rs.map(r=>`
      <div class="card">
        <div class="row" style="justify-content:space-between"><h3 class="title">${r.name}</h3><button class="ghost" onclick="onRemoveRecipe(${r.id})">删除</button></div>
        <div class="muted">用料：</div>
        <ul class="list">
          ${rI.filter(x=>x.recipeId===r.id).map(x=>`<li class="row" style="justify-content:space-between"><span>${x.name}</span><span class="muted">${x.need}${x.unit}</span></li>`).join('') || '<div class="muted">暂无用料</div>'}
        </ul>
        <div class="row" style="margin-top:8px">
          <input id="ing-${r.id}" placeholder="用料名称"><input id="qty-${r.id}" type="number" placeholder="数量">
          <select id="unit-${r.id}"><option value="g">g</option><option value="ml">ml</option><option value="pcs">个</option></select>
          <button onclick="onAddRecipeIng(${r.id})">加入</button>
        </div>
      </div>
    `).join('')}`;
}
function renderList(){
  const items=S.list;
  $('#page').innerHTML = `
    <div class="card"><h3 class="title">添加到购物清单</h3>
      <div class="row"><input id="lname" placeholder="名称"><input id="lqty" type="number" placeholder="数量">
      <select id="lunit"><option value="g">g</option><option value="ml">ml</option><option value="pcs">个</option></select>
      <button onclick="onAddList()">添加</button></div>
    </div>
    <div class="card">
      <div class="row" style="justify-content:space-between"><h3 class="title">购物清单</h3><button class="ghost" onclick="onClearList()">清空</button></div>
      <div class="list">
        ${items.map(i=>`<div class="row" style="justify-content:space-between"><span>${i.name}</span><div class="row" style="flex:none;gap:8px"><span class="muted">${i.qty}${i.unit}</span><button class="ghost" onclick="onRemoveList('${i.name}')">删除</button></div></div>`).join('') || '<div class="muted">暂无条目</div>'}
      </div>
    </div>`;
}
function renderSettings(){
  const p=S.prefs;
  $('#page').innerHTML = `
    <div class="card"><h3 class="title">口味与禁忌</h3>
      <div class="row"><input id="disliked" placeholder="不喜欢的食材（逗号分隔）" value="${(p.disliked||[]).join(',')}"></div>
      <div class="row"><input id="allergens" placeholder="过敏原（逗号分隔）" value="${(p.allergens||[]).join(',')}"></div>
      <div class="row"><input id="cuisines" placeholder="偏好菜系（如 家常, 川菜）" value="${(p.cuisines||[]).join(',')}"></div>
      <div class="row"><span class="muted">辣度</span><input id="spice" type="range" min="0" max="3" value="${p.spice||1}" oninput="document.getElementById('spVal').innerText=this.value"><span id="spVal" class="muted">${p.spice||1}</span></div>
      <div class="row" style="margin-top:8px"><button onclick="onSavePrefs()">保存</button></div>
    </div>
    <div class="card"><h3 class="title">关于</h3><div class="muted">把整个文件夹上传到 GitHub Pages（支持离线）。</div></div>`;
}

// ---- handlers ----
function onTab(t){
  var tabs=document.querySelectorAll('.tabbar button'); for(var i=0;i<tabs.length;i++) tabs[i].classList.remove('active');
  var cur=document.getElementById('tab-'+t); if(cur) cur.classList.add('active');
  location.hash = '#'+t;
  if(t==='recommend') renderRecommend();
  else if(t==='inventory') renderInventory();
  else if(t==='recipes') renderRecipes();
  else if(t==='list') renderList();
  else if(t==='settings') renderSettings();
}
function onAddBatch(){
  const name=$('#ingName').value.trim(); const qty=Number($('#qty').value); const unit=$('#unit').value; const days=Number($('#days').value||3); const loc=$('#loc').value;
  if(!name || qty<=0) return alert('请输入名称与数量');
  let ing=S.ings.find(i=>i.name===name);
  if(!ing){ const id=lastId(S.ings)+1; ing={id,name,unit,shelf:days}; S.ings.push(ing); jset('ingredients',S.ings); }
  const id=lastId(S.stock)+1; const p=today(); const e=plusDays(p,days);
  S.stock.push({id,ingId:ing.id,qty,unit,purchase:p,expire:e,location:loc}); jset('stock',S.stock); renderInventory();
}
function onRemoveBatch(id){ S.stock=S.stock.filter(b=>b.id!==id); jset('stock',S.stock); renderInventory(); }
function onAddRecipe(){
  const name=$('#rname').value.trim(); if(!name) return alert('请输入菜名'); const id=lastId(S.recipes)+1; S.recipes.push({id,name,tags:['家常']}); jset('recipes',S.recipes); renderRecipes();
}
function onRemoveRecipe(id){ S.recipes=S.recipes.filter(r=>r.id!==id); S.rIngs=S.rIngs.filter(x=>x.recipeId!==id); jset('recipes',S.recipes); jset('recipeIngs',S.rIngs); renderRecipes(); }
function onAddRecipeIng(recipeId){
  const name=$('#ing-'+recipeId).value.trim(); const qty=Number($('#qty-'+recipeId).value); const unit=$('#unit-'+recipeId).value;
  if(!name||qty<=0) return alert('请输入用料名称与数量');
  let ing=S.ings.find(i=>i.name===name); if(!ing){ const id=lastId(S.ings)+1; ing={id,name,unit,shelf:5}; S.ings.push(ing); jset('ingredients',S.ings); }
  S.rIngs.push({recipeId,ingId:ing.id,name:ing.name,need:qty,unit}); jset('recipeIngs',S.rIngs); renderRecipes();
}
function onCook(id){ cookAndDeduct(id); alert('已扣减库存'); onTab('inventory'); }
function onAddMissing(id){
  const miss=diffForRecipe(id); const list=S.list; for(const m of miss){ const ex=list.find(x=>x.name===m.name && x.unit===m.unit); if(ex) ex.qty+=Math.ceil(m.shortage); else list.push({name:m.name,qty:Math.ceil(m.shortage),unit:m.unit}); }
  jset('list',list); alert('已加入购物清单');
}
function onAddList(){ const name=$('#lname').value.trim(); const qty=Number($('#lqty').value); const unit=$('#lunit').value; if(!name||qty<=0) return; S.list.push({name,qty,unit}); jset('list',S.list); renderList(); }
function onRemoveList(name){ S.list=S.list.filter(i=>i.name!==name); jset('list',S.list); renderList(); }
function onClearList(){ S.list=[]; jset('list',S.list); renderList(); }
function onSavePrefs(){
  const p={ disliked:$('#disliked').value.split(/[，,\\s]+/).map(s=>s.trim()).filter(Boolean),
            allergens:$('#allergens').value.split(/[，,\\s]+/).map(s=>s.trim()).filter(Boolean),
            cuisines:$('#cuisines').value.split(/[，,\\s]+/).map(s=>s.trim()).filter(Boolean),
            spice:Number($('#spice').value||1) };
  S.prefs=p; jset('prefs',p); alert('已保存偏好设置');
}

// ---- app shell ----
function boot(){
  document.getElementById('app').innerHTML = `
    <div class="app">
      <header><img src="icons/pwa-192.png" width="28" height="28" style="border-radius:8px"/><h1>Kitchen Assistant · 厨房</h1></header>
      <main class="container"><div id="page"></div></main>
      <nav class="tabbar">
        <button id="tab-recommend" onclick="onTab('recommend')">推荐</button>
        <button id="tab-inventory" onclick="onTab('inventory')">库存</button>
        <button id="tab-recipes" onclick="onTab('recipes')">菜谱</button>
        <button id="tab-list" onclick="onTab('list')">清单</button>
        <button id="tab-settings" onclick="onTab('settings')">我的</button>
      </nav>
    </div>`;
  var t=(location.hash||'#recommend').slice(1); onTab(t||'recommend');
}
window.addEventListener('DOMContentLoaded', boot);

// ---- SW ----
if('serviceWorker' in navigator){ window.addEventListener('load', ()=> navigator.serviceWorker.register('sw.js').catch(()=>{}) ) }

// ---- error overlay ----
window.addEventListener('error', function(e){ 
  var box=document.createElement('div'); box.className='error'; 
  box.textContent='脚本错误：'+(e.message||''); document.body.appendChild(box);
});
