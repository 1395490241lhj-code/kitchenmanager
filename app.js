<script>
// —— 加载并合并四川菜谱 ——
// 你可以把文件路径改成 './sichuan-recipes.json' 或 './data/sichuan-recipes.json'
async function loadSichuanRecipes(jsonPath = './data/sichuan-recipes.json') {
  try {
    const res = await fetch(jsonPath, { cache: 'no-store' });
    if (!res.ok) return;

    const add = await res.json();

    // 1) 取出当前已有菜谱（你项目里若有全局变量如 RECIPES/DB.recipes，这里都会兼容）
    const localKey = 'recipes';
    const fromLocal = JSON.parse(localStorage.getItem(localKey) || '[]');
    const fromGlobal = (window.RECIPES && Array.isArray(window.RECIPES)) ? window.RECIPES : [];
    let merged = [...fromGlobal, ...fromLocal, ...add];

    // 2) 去重（以菜名为键）
    const seen = new Set();
    merged = merged.filter(r => {
      const k = (r.name || '').trim();
      if (!k || seen.has(k)) return false;
      seen.add(k);
      return true;
    });

    // 3) 回写到全局与本地，供现有渲染逻辑使用
    window.RECIPES = merged;
    try { localStorage.setItem(localKey, JSON.stringify(merged)); } catch (e) {}
    
    // 4) 如果你的页面有刷新列表的函数，这里尝试调用；没有也不会报错
    if (typeof window.renderRecipeList === 'function') window.renderRecipeList(merged);
  } catch (err) {
    console.warn('loadSichuanRecipes failed:', err);
  }
}

// 页面初始化时加载
document.addEventListener('DOMContentLoaded', () => loadSichuanRecipes());
</script>

// ---- storage helpers ----
const store = {
  get(key, def){ try{ return JSON.parse(localStorage.getItem(key)) ?? def }catch(e){ return def } },
  set(key, val){ localStorage.setItem(key, JSON.stringify(val)) },
}
const nowISO = () => new Date().toISOString().slice(0,10)
const plusDays = (d, n) => new Date(new Date(d).getTime() + n*86400000).toISOString().slice(0,10)
const daysBetween = (a,b) => Math.ceil((new Date(a)-new Date(b))/86400000)

// ---- seed sample data on first load ----
function seedIfEmpty(){
  if (!store.get('ingredients', null)){
    const ingredients = [
      {id:1,name:'西兰花',unit:'g',shelf:4},
      {id:2,name:'鸡胸',unit:'g',shelf:2},
      {id:3,name:'蒜',unit:'g',shelf:10},
      {id:4,name:'番茄',unit:'g',shelf:6},
      {id:5,name:'鸡蛋',unit:'pcs',shelf:14},
      {id:6,name:'土豆',unit:'g',shelf:20},
      {id:7,name:'牛腩',unit:'g',shelf:3},
      {id:8,name:'洋葱',unit:'g',shelf:10},
      {id:9,name:'青椒',unit:'g',shelf:7},
      {id:10,name:'菠菜',unit:'g',shelf:4},
      {id:11,name:'蘑菇',unit:'g',shelf:3},
    ]
    const recipes = [
      {id:101,name:'西兰花炒鸡胸',tags:['家常','清淡']},
      {id:102,name:'番茄炒蛋',tags:['家常']},
      {id:103,name:'土豆烧牛肉',tags:['家常','炖']},
      {id:104,name:'青椒土豆丝',tags:['家常','快手']},
      {id:105,name:'蘑菇炒菠菜',tags:['清淡','素食']},
    ]
    const rIngs = [
      {recipeId:101, ingId:1, name:'西兰花', need:300, unit:'g'},
      {recipeId:101, ingId:2, name:'鸡胸', need:250, unit:'g'},
      {recipeId:101, ingId:3, name:'蒜', need:10, unit:'g'},

      {recipeId:102, ingId:4, name:'番茄', need:300, unit:'g'},
      {recipeId:102, ingId:5, name:'鸡蛋', need:3, unit:'pcs'},
      {recipeId:102, ingId:3, name:'蒜', need:5, unit:'g'},

      {recipeId:103, ingId:7, name:'牛腩', need:400, unit:'g'},
      {recipeId:103, ingId:6, name:'土豆', need:300, unit:'g'},
      {recipeId:103, ingId:8, name:'洋葱', need:100, unit:'g'},

      {recipeId:104, ingId:9, name:'青椒', need:100, unit:'g'},
      {recipeId:104, ingId:6, name:'土豆', need:250, unit:'g'},
      {recipeId:104, ingId:3, name:'蒜', need:10, unit:'g'},

      {recipeId:105, ingId:11, name:'蘑菇', need:200, unit:'g'},
      {recipeId:105, ingId:10, name:'菠菜', need:250, unit:'g'},
      {recipeId:105, ingId:3, name:'蒜', need:10, unit:'g'}
    ]

    const today = nowISO()
    const stock = [
      {id:1, ingId:1, qty:320, unit:'g', purchase: today, expire: plusDays(today,3), location:'fridge'},
      {id:2, ingId:2, qty:220, unit:'g', purchase: today, expire: plusDays(today,2), location:'fridge'},
      {id:3, ingId:4, qty:400, unit:'g', purchase: today, expire: plusDays(today,5), location:'fridge'},
      {id:4, ingId:6, qty:800, unit:'g', purchase: today, expire: plusDays(today,14), location:'pantry'}
    ]

    store.set('ingredients', ingredients)
    store.set('recipes', recipes)
    store.set('recipeIngs', rIngs)
    store.set('stock', stock)
    store.set('prefs', {disliked:[], allergens:[], cuisines:['家常'], spice:1})
    store.set('list', [])
  }
}
seedIfEmpty()

// ---- util & state ----
const S = {
  get ings(){ return store.get('ingredients', []) },
  set ings(v){ store.set('ingredients', v) },
  get stock(){ return store.get('stock', []) },
  set stock(v){ store.set('stock', v) },
  get recipes(){ return store.get('recipes', []) },
  set recipes(v){ store.set('recipes', v) },
  get rIngs(){ return store.get('recipeIngs', []) },
  set rIngs(v){ store.set('recipeIngs', v) },
  get prefs(){ return store.get('prefs', {disliked:[], allergens:[], cuisines:[], spice:1}) },
  set prefs(v){ store.set('prefs', v) },
  get list(){ return store.get('list', []) },
  set list(v){ store.set('list', v) },
}
const byId = (arr, id) => arr.find(x=>x.id===id)
const ingName = id => byId(S.ings, id)?.name || '#'+id
function perishScore(batch){
  const shelf = Math.max(1, daysBetween(batch.expire, batch.purchase))
  const left = daysBetween(batch.expire, nowISO())
  return Math.max(0, Math.min(1, 1 - left/shelf))
}
function aggregateStock(){
  const map = new Map()
  for(const b of S.stock){
    const prev = map.get(b.ingId) || {available:0, perish:0}
    map.set(b.ingId, {available: prev.available + b.qty, perish: Math.max(prev.perish, perishScore(b))})
  }
  return map
}

// ---- recommend ----
function recommendTop(k=5){
  const stock = aggregateStock()
  const pref = S.prefs
  const results = S.recipes.map(r=>{
    const list = S.rIngs.filter(x=>x.recipeId===r.id)
    if (pref.allergens?.length && list.some(it=>pref.allergens.includes(it.name))) return null
    if (pref.disliked?.length && list.some(it=>pref.disliked.includes(it.name))) return null
    let coverSum=0, perishSum=0, miss=0
    const breakdown = list.map(it=>{
      const avail = stock.get(it.ingId)?.available ?? 0
      const perish = stock.get(it.ingId)?.perish ?? 0
      const need = it.need
      const cover = Math.min(1, avail/need)
      if (cover<1) miss+=1
      coverSum+=cover
      perishSum+= perish * Math.min(1, avail/need)
      return {name: ingName(it.ingId), avail, need, perish}
    })
    const cover = breakdown.length? coverSum/breakdown.length : 0
    const perishWeighted = breakdown.length? perishSum/breakdown.length : 0
    const tasteBonus = (pref.cuisines && r.tags?.some(t=>pref.cuisines.includes(t))) ? 0.1 : 0
    const score = 0.45*perishWeighted + 0.35*cover - 0.15*miss + 0.05*tasteBonus
    return { recipe:r, score, cover, miss, perishWeighted, breakdown }
  }).filter(Boolean).sort((a,b)=>b.score-a.score).slice(0,k)
  return results
}
function diffForRecipe(recipeId){
  const stock = aggregateStock()
  return S.rIngs.filter(x=>x.recipeId===recipeId).map(it=>{
    const avail = stock.get(it.ingId)?.available ?? 0
    const short = Math.max(0, it.need - avail)
    return short>0 ? { name: ingName(it.ingId), shortage: short, unit: it.unit } : null
  }).filter(Boolean)
}
function cookAndDeduct(recipeId){
  const items = S.rIngs.filter(x=>x.recipeId===recipeId)
  const batches = [...S.stock].sort((a,b)=> a.expire.localeCompare(b.expire)) // FEFO
  for(const it of items){
    let remaining = it.need
    for(const b of batches){
      if (b.ingId!==it.ingId) continue
      if (remaining<=0) break
      const take = Math.min(b.qty, remaining)
      b.qty -= take
      remaining -= take
      if (b.qty<=0){
        const idx = S.stock.findIndex(x=>x.id===b.id)
        S.stock.splice(idx,1)
      }else{
        const idx = S.stock.findIndex(x=>x.id===b.id)
        S.stock[idx] = b
      }
    }
  }
  store.set('stock', S.stock)
}

// ---- UI helpers ----
const $ = s => document.querySelector(s)
function chip(text){ return `<span class="chip">${text}</span>` }
function fmt(qty, unit){ if(unit==='pcs') return `${qty}个`; if(qty>=1000) return `${(qty/1000).toFixed(1)}${unit==='g'?'kg':'L'}`; return `${qty}${unit}` }

// ---- PAGES RENDER ----
function renderRecommend(){
  const res = recommendTop(5)
  if (res.length===0){ $('#page').innerHTML = `<div class="card">没有可推荐的菜谱。请先添加库存与菜谱。</div>`; return }
  $('#page').innerHTML = res.map(it=>`
    <div class="card">
      <div class="row" style="justify-content:space-between">
        <h3 class="title">${it.recipe.name}</h3>
        ${chip('推荐分 '+it.score.toFixed(2))}
      </div>
      <div class="kpi">
        ${chip('覆盖率 '+(it.cover*100).toFixed(0)+'%')}
        ${chip('缺料 '+it.miss+' 项')}
        ${chip('易腐加权 '+(it.perishWeighted*100).toFixed(0)+'%')}
      </div>
      <div class="muted" style="margin-top:8px">将消耗：${it.breakdown.filter(b=>b.perish>0.4).map(b=>b.name).join('、') || '普通食材'}</div>
      ${ (()=>{
        const miss = diffForRecipe(it.recipe.id)
        if (miss.length===0) return ''
        return `<div style="margin-top:8px">
          <div class="label">缺料清单：</div>
          <ul class="list">
            ${miss.map(m=>`<li class="row" style="justify-content:space-between"><span>${m.name}</span><span class="muted">${fmt(Math.ceil(m.shortage),'g')}</span></li>`).join('')}
          </ul>
        </div>`
      })() }
      <div class="row" style="margin-top:12px">
        <button class="ok" onclick="onCook(${it.recipe.id})">我就做这个</button>
        <button class="ghost" onclick="onAddMissing(${it.recipe.id})">加入购物清单</button>
      </div>
    </div>
  `).join('')
}
function renderInventory(){
  const ings = S.ings, batches = [...S.stock].sort((a,b)=> a.expire.localeCompare(b.expire))
  function badge(b){
    const left = daysBetween(b.expire, nowISO())
    const color = left<=0? 'danger' : (1 - left/Math.max(1,daysBetween(b.expire,b.purchase)))>0.7? 'warn':'ok'
    const label = left<=0? '已过期' : `剩 ${left} 天`
    return `<span class="chip" style="border-color:transparent;background:rgba(255,255,255,.04)"><span class="muted">到期</span> <b class="${color}">${label}</b></span>`
  }
  $('#page').innerHTML = `
    <div class="card">
      <h3 class="title">添加库存（按批次）</h3>
      <div class="row">
        <input id="ingName" placeholder="食材名称（如：西兰花）">
      </div>
      <div class="row">
        <input id="qty" type="number" placeholder="数量">
        <select id="unit">
          <option value="g">g</option><option value="ml">ml</option><option value="pcs">个</option>
        </select>
        <input id="days" type="number" placeholder="保质期（天）" value="3">
        <select id="loc">
          <option value="fridge">冷藏</option><option value="freezer">冷冻</option><option value="pantry">常温</option>
        </select>
      </div>
      <div class="row" style="margin-top:8px">
        <button onclick="onAddBatch()">保存</button>
      </div>
    </div>
    <div class="card">
      <h3 class="title">当前库存</h3>
      <div class="list">
        ${batches.map(b=>`
          <div class="row" style="justify-content:space-between">
            <div>
              <div>${ingName(b.ingId)} · ${b.qty}${b.unit}</div>
              <div class="muted">购入 ${b.purchase} · 到期 ${b.expire}</div>
            </div>
            <div class="row" style="gap:8px; align-items:center; justify-content:flex-end">
              ${badge(b)}
              <button class="ghost" onclick="onRemoveBatch(${b.id})">删除</button>
            </div>
          </div>
        `).join('') || '<div class="muted">暂无库存，先添加一些吧。</div>'}
      </div>
    </div>
  `
}
function renderRecipes(){
  const rs = S.recipes, rIngs = S.rIngs
  $('#page').innerHTML = `
    <div class="card">
      <h3 class="title">新增菜谱</h3>
      <div class="row">
        <input id="rname" placeholder="菜名">
        <input id="rtime" type="number" placeholder="时长(min)" value="15">
        <button onclick="onAddRecipe()">保存</button>
      </div>
    </div>
    ${rs.map(r=>`
      <div class="card">
        <div class="row" style="justify-content:space-between">
          <h3 class="title">${r.name}</h3>
          <button class="ghost" onclick="onRemoveRecipe(${r.id})">删除</button>
        </div>
        <div class="muted">用料：</div>
        <ul class="list">
          ${rIngs.filter(x=>x.recipeId===r.id).map(x=>`
            <li class="row" style="justify-content:space-between">
              <span>${x.name}</span>
              <span class="muted">${x.need}${x.unit}</span>
            </li>
          `).join('') || '<div class="muted">暂无用料</div>'}
        </ul>
        <div class="row" style="margin-top:8px">
          <input id="ing-${r.id}" placeholder="用料名称">
          <input id="qty-${r.id}" type="number" placeholder="数量">
          <select id="unit-${r.id}"><option value="g">g</option><option value="ml">ml</option><option value="pcs">个</option></select>
          <button onclick="onAddRecipeIng(${r.id})">加入</button>
        </div>
      </div>
    `).join('')}
  `
}
function renderList(){
  const items = S.list
  $('#page').innerHTML = `
    <div class="card">
      <h3 class="title">添加到购物清单</h3>
      <div class="row">
        <input id="lname" placeholder="名称">
        <input id="lqty" type="number" placeholder="数量">
        <select id="lunit"><option value="g">g</option><option value="ml">ml</option><option value="pcs">个</option></select>
        <button onclick="onAddList()">添加</button>
      </div>
    </div>
    <div class="card">
      <div class="row" style="justify-content:space-between">
        <h3 class="title">购物清单</h3>
        <button class="ghost" onclick="onClearList()">清空</button>
      </div>
      <div class="list">
        ${items.map(i=>`
          <div class="row" style="justify-content:space-between">
            <span>${i.name}</span>
            <div class="row" style="flex:none; gap:8px">
              <span class="muted">${i.qty}${i.unit}</span>
              <button class="ghost" onclick="onRemoveList('${i.name}')">删除</button>
            </div>
          </div>
        `).join('') || '<div class="muted">暂无条目</div>'}
      </div>
    </div>
  `
}
function renderSettings(){
  const p = S.prefs
  $('#page').innerHTML = `
    <div class="card">
      <h3 class="title">口味与禁忌</h3>
      <div class="row"><input id="disliked" placeholder="不喜欢的食材（逗号分隔）" value="${(p.disliked||[]).join(',')}"></div>
      <div class="row"><input id="allergens" placeholder="过敏原（逗号分隔）" value="${(p.allergens||[]).join(',')}"></div>
      <div class="row"><input id="cuisines" placeholder="偏好菜系（如 家常, 川菜）" value="${(p.cuisines||[]).join(',')}"></div>
      <div class="row"><label class="label">辣度</label><input id="spice" type="range" min="0" max="3" value="${p.spice||1}" oninput="document.getElementById('spiceValue').innerText=this.value"><span id="spiceValue" class="muted">${p.spice||1}</span></div>
      <div class="row" style="margin-top:8px"><button onclick="onSavePrefs()">保存</button></div>
    </div>
    <div class="card"><h3 class="title">关于</h3><div class="muted">把整个文件夹上传到任意静态托管即可使用（支持离线）。</div></div>
  `
}

// ---- handlers ----
function onTab(t){
  document.querySelectorAll('.tabbar button').forEach(b=>b.classList.remove('active'))
  document.getElementById('tab-'+t).classList.add('active')
  location.hash = t
  if (t==='recommend') renderRecommend()
  if (t==='inventory') renderInventory()
  if (t==='recipes') renderRecipes()
  if (t==='list') renderList()
  if (t==='settings') renderSettings()
}
function onAddBatch(){
  const name = document.getElementById('ingName').value.trim()
  const qty = Number(document.getElementById('qty').value)
  const unit = document.getElementById('unit').value
  const days = Number(document.getElementById('days').value||3)
  const loc = document.getElementById('loc').value
  if(!name || qty<=0) return alert('请输入名称与数量')
  let ing = S.ings.find(i=>i.name===name)
  if(!ing){
    const id = (S.ings.at(-1)?.id||0)+1
    ing = {id, name, unit, shelf:days}
    S.ings.push(ing); store.set('ingredients', S.ings)
  }
  const id = (S.stock.at(-1)?.id||0)+1
  const purchase = nowISO()
  const expire = plusDays(purchase, days)
  S.stock.push({id, ingId: ing.id, qty, unit, purchase, expire, location:loc})
  store.set('stock', S.stock)
  renderInventory()
}
function onRemoveBatch(id){ S.stock = S.stock.filter(b=>b.id!==id); store.set('stock', S.stock); renderInventory() }
function onAddRecipe(){
  const name = document.getElementById('rname').value.trim()
  const time = Number(document.getElementById('rtime').value||15)
  if(!name) return alert('请输入菜名')
  const id = (S.recipes.at(-1)?.id||100)+1
  S.recipes.push({id, name, tags:['家常']})
  store.set('recipes', S.recipes)
  renderRecipes()
}
function onRemoveRecipe(id){
  S.recipes = S.recipes.filter(r=>r.id!==id)
  S.rIngs = S.rIngs.filter(x=>x.recipeId!==id)
  store.set('recipes', S.recipes); store.set('recipeIngs', S.rIngs)
  renderRecipes()
}
function onAddRecipeIng(recipeId){
  const name = document.getElementById('ing-'+recipeId).value.trim()
  const qty = Number(document.getElementById('qty-'+recipeId).value)
  const unit = document.getElementById('unit-'+recipeId).value
  if(!name || qty<=0) return alert('请输入用料名称与数量')
  let ing = S.ings.find(i=>i.name===name)
  if(!ing){
    const id = (S.ings.at(-1)?.id||0)+1
    ing = {id, name, unit, shelf:5}
    S.ings.push(ing); store.set('ingredients', S.ings)
  }
  S.rIngs.push({recipeId, ingId: ing.id, name: ing.name, need: qty, unit})
  store.set('recipeIngs', S.rIngs)
  renderRecipes()
}
function onCook(id){ cookAndDeduct(id); alert('已扣减库存'); onTab('inventory') }
function onAddMissing(id){
  const miss = diffForRecipe(id)
  const list = S.list
  miss.forEach(m=>{
    const exist = list.find(x=>x.name===m.name && x.unit===m.unit)
    if (exist) exist.qty += Math.ceil(m.shortage)
    else list.push({name:m.name, qty:Math.ceil(m.shortage), unit:m.unit})
  })
  store.set('list', list)
  alert('已加入购物清单')
}
function onAddList(){
  const name = document.getElementById('lname').value.trim()
  const qty = Number(document.getElementById('lqty').value)
  const unit = document.getElementById('lunit').value
  if(!name || qty<=0) return
  S.list.push({name, qty, unit})
  store.set('list', S.list)
  renderList()
}
function onRemoveList(name){ S.list = S.list.filter(i=>i.name!==name); store.set('list', S.list); renderList() }
function onClearList(){ S.list = []; store.set('list', S.list); renderList() }
function onSavePrefs(){
  const p = {
    disliked: document.getElementById('disliked').value.split(/[，,\\s]+/).map(x=>x.trim()).filter(Boolean),
    allergens: document.getElementById('allergens').value.split(/[，,\\s]+/).map(x=>x.trim()).filter(Boolean),
    cuisines: document.getElementById('cuisines').value.split(/[，,\\s]+/).map(x=>x.trim()).filter(Boolean),
    spice: Number(document.getElementById('spice').value||1)
  }
  S.prefs = p; alert('已保存偏好设置')
}

// ---- initial render & hash routing ----
function renderApp(){
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
    </div>
  `
  const t = location.hash?.slice(1) || 'recommend'
  onTab(t)
}
renderApp()

// ---- service worker registration ----
if ('serviceWorker' in navigator){
  window.addEventListener('load', ()=>{
    navigator.serviceWorker.register('sw.js').catch(()=>{})
  })
}
