
// helpers
var store={get:function(k,d){try{return JSON.parse(localStorage.getItem(k))??d}catch(e){return d}},set:function(k,v){try{localStorage.setItem(k,JSON.stringify(v))}catch(e){}}};
function nowISO(){return new Date().toISOString().slice(0,10)}
function plusDays(d,n){return new Date(new Date(d).getTime()+n*86400000).toISOString().slice(0,10)}
function daysBetween(a,b){return Math.ceil((new Date(a)-new Date(b))/86400000)}
function last(arr){return (arr&&arr.length)?arr[arr.length-1]:undefined}

// seed
function seedIfEmpty(){
  if(store.get('ingredients',null)) return;
  var ingredients=[
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
    {id:11,name:'蘑菇',unit:'g',shelf:3}
  ];
  var recipes=[
    {id:101,name:'西兰花炒鸡胸',tags:['家常','清淡']},
    {id:102,name:'番茄炒蛋',tags:['家常']},
    {id:103,name:'土豆烧牛肉',tags:['家常','炖']},
    {id:104,name:'青椒土豆丝',tags:['家常','快手']},
    {id:105,name:'蘑菇炒菠菜',tags:['清淡','素食']}
  ];
  var rIngs=[
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
    {recipeId:105,ingId:3,name:'蒜',need:10,unit:'g'}
  ];
  var today=nowISO();
  var stock=[
    {id:1,ingId:1,qty:320,unit:'g',purchase:today,expire:plusDays(today,3),location:'fridge'},
    {id:2,ingId:2,qty:220,unit:'g',purchase:today,expire:plusDays(today,2),location:'fridge'},
    {id:3,ingId:4,qty:400,unit:'g',purchase:today,expire:plusDays(today,5),location:'fridge'},
    {id:4,ingId:6,qty:800,unit:'g',purchase:today,expire:plusDays(today,14),location:'pantry'}
  ];
  store.set('ingredients',ingredients); store.set('recipes',recipes); store.set('recipeIngs',rIngs);
  store.set('stock',stock); store.set('prefs',{disliked:[],allergens:[],cuisines:['家常','川菜'],spice:2}); store.set('list',[]);
}
seedIfEmpty();

// state
var S={
  get ings(){return store.get('ingredients',[])}, set ings(v){store.set('ingredients',v)},
  get stock(){return store.get('stock',[])}, set stock(v){store.set('stock',v)},
  get recipes(){return store.get('recipes',[])}, set recipes(v){store.set('recipes',v)},
  get rIngs(){return store.get('recipeIngs',[])}, set rIngs(v){store.set('recipeIngs',v)},
  get prefs(){return store.get('prefs',{disliked:[],allergens:[],cuisines:[],spice:1})}, set prefs(v){store.set('prefs',v)},
  get list(){return store.get('list',[])}, set list(v){store.set('list',v)}
};
function byId(arr,id){for(var i=0;i<arr.length;i++){if(arr[i].id===id)return arr[i]}return null}
function ingName(id){var o=byId(S.ings,id);return o?o.name:('#'+id)}
function perishScore(b){var shelf=Math.max(1,daysBetween(b.expire,b.purchase)); var left=daysBetween(b.expire,nowISO()); return Math.max(0,Math.min(1,1-left/shelf))}
function aggregateStock(){var m=new Map(); for(var i=0;i<S.stock.length;i++){var b=S.stock[i]; var prev=m.get(b.ingId)||{available:0,perish:0}; m.set(b.ingId,{available:prev.available+b.qty,perish:Math.max(prev.perish,perishScore(b))});} return m}

// recommend
function recommendTop(k){k=k||5; var stock=aggregateStock(); var pref=S.prefs; 
  var arr=[]; for(var i=0;i<S.recipes.length;i++){var r=S.recipes[i]; 
    var list=S.rIngs.filter(function(x){return x.recipeId===r.id});
    if(pref.allergens&&pref.allergens.length&&list.some(function(it){return pref.allergens.indexOf(it.name)>-1})) continue;
    if(pref.disliked&&pref.disliked.length&&list.some(function(it){return pref.disliked.indexOf(it.name)>-1})) continue;
    var coverSum=0, perishSum=0, miss=0, breakdown=[];
    for(var j=0;j<list.length;j++){var it=list[j]; var s=stock.get(it.ingId)||{available:0,perish:0}; var avail=s.available; var perish=s.perish; var need=it.need; var cover=Math.min(1, (need>0?avail/need:1)); if(cover<1)miss++; coverSum+=cover; perishSum+= perish*Math.min(1,(need>0?avail/need:1)); breakdown.push({name:ingName(it.ingId),avail:avail,need:need,perish:perish});}
    var cover=list.length?coverSum/list.length:0; var perishWeighted=list.length?perishSum/list.length:0;
    var tasteBonus=(pref.cuisines && r.tags && r.tags.some(function(t){return pref.cuisines.indexOf(t)>-1}))?0.1:0;
    var score=0.45*perishWeighted + 0.35*cover - 0.15*miss + 0.05*tasteBonus;
    arr.push({recipe:r,score:score,cover:cover,miss:miss,perishWeighted:perishWeighted,breakdown:breakdown});
  }
  arr.sort(function(a,b){return b.score-a.score}); return arr.slice(0,k);
}
function diffForRecipe(id){var stock=aggregateStock(); 
  return S.rIngs.filter(function(x){return x.recipeId===id}).map(function(it){
    var avail=(stock.get(it.ingId)||{available:0}).available; var short=Math.max(0,it.need-avail); return short>0?{name:ingName(it.ingId),shortage:short,unit:it.unit}:null;
  }).filter(Boolean);
}
function cookAndDeduct(id){
  var items=S.rIngs.filter(function(x){return x.recipeId===id}); var batches=S.stock.slice().sort(function(a,b){return a.expire.localeCompare(b.expire)});
  for(var i=0;i<items.length;i++){var it=items[i]; var remaining=it.need;
    for(var j=0;j<batches.length;j++){var b=batches[j]; if(b.ingId!==it.ingId)continue; if(remaining<=0)break; var take=Math.min(b.qty,remaining); b.qty-=take; remaining-=take;
      var idx=S.stock.findIndex?S.stock.findIndex(function(x){return x.id===b.id}):S.stock.map(function(x){return x.id}).indexOf(b.id);
      if(b.qty<=0){ if(idx>-1) S.stock.splice(idx,1); } else { if(idx>-1) S.stock[idx]=b; }
    }
  } store.set('stock',S.stock);
}

// UI helpers
function $(s){return document.querySelector(s)}
function chip(t){return '<span class="chip">'+t+'</span>'}
function fmt(q,u){ if(u==='pcs') return String(Math.round(q))+'个'; if(q>=1000) return (q/1000).toFixed(1)+(u==='g'?'kg':'L'); return String(q)+(u||'') }

// renders
function renderRecommend(){
  var res=recommendTop(5); if(res.length===0){$('#page').innerHTML='<div class="card">没有可推荐的菜谱。请先添加库存与菜谱。</div>'; return;}
  $('#page').innerHTML=res.map(function(it){
    var miss=diffForRecipe(it.recipe.id);
    var missHtml=miss.length?('<div style="margin-top:8px"><div class="label">缺料清单：</div><ul class="list">'+miss.map(function(m){return '<li class="row" style="justify-content:space-between"><span>'+m.name+'</span><span class="muted">'+fmt(Math.ceil(m.shortage),'g')+'</span></li>'}).join('')+'</ul></div>') : '';
    return '<div class="card">'
      +'<div class="row" style="justify-content:space-between"><h3 class="title">'+it.recipe.name+'</h3>'+chip('推荐分 '+it.score.toFixed(2))+'</div>'
      +'<div class="kpi">'+chip('覆盖率 '+(it.cover*100).toFixed(0)+'%')+chip('缺料 '+it.miss+' 项')+chip('易腐加权 '+(it.perishWeighted*100).toFixed(0)+'%')+'</div>'
      +'<div class="muted" style="margin-top:8px">将消耗：'+(it.breakdown.filter(function(b){return b.perish>0.4}).map(function(b){return b.name}).join('、')||'普通食材')+'</div>'
      +missHtml
      +'<div class="row" style="margin-top:12px"><button class="ok" onclick="onCook('+it.recipe.id+')">我就做这个</button><button class="ghost" onclick="onAddMissing('+it.recipe.id+')">加入购物清单</button></div>'
      +'</div>';
  }).join('');
}
function renderInventory(){
  var batches=S.stock.slice().sort(function(a,b){return a.expire.localeCompare(b.expire)});
  function badge(b){var left=daysBetween(b.expire,nowISO()); var color=(left<=0)?'danger':((1-left/Math.max(1,daysBetween(b.expire,b.purchase)))>0.7?'warn':'ok'); var label=(left<=0)?'已过期':('剩 '+left+' 天'); return '<span class="chip" style="border-color:transparent;background:rgba(255,255,255,.04)"><span class="muted">到期</span> <b class="'+color+'">'+label+'</b></span>'}
  $('#page').innerHTML=''
    +'<div class="card"><h3 class="title">添加库存（按批次）</h3>'
    +'<div class="row"><input id="ingName" placeholder="食材名称（如：西兰花）"></div>'
    +'<div class="row"><input id="qty" type="number" placeholder="数量">'
    +'<select id="unit"><option value="g">g</option><option value="ml">ml</option><option value="pcs">个</option></select>'
    +'<input id="days" type="number" placeholder="保质期（天）" value="3">'
    +'<select id="loc"><option value="fridge">冷藏</option><option value="freezer">冷冻</option><option value="pantry">常温</option></select></div>'
    +'<div class="row" style="margin-top:8px"><button onclick="onAddBatch()">保存</button></div></div>'
    +'<div class="card"><h3 class="title">当前库存</h3><div class="list">'
    +(batches.map(function(b){
      return '<div class="row" style="justify-content:space-between"><div><div>'+ingName(b.ingId)+' · '+b.qty+b.unit+'</div><div class="muted">购入 '+b.purchase+' · 到期 '+b.expire+'</div></div><div class="row" style="gap:8px;align-items:center;justify-content:flex-end">'+badge(b)+'<button class="ghost" onclick="onRemoveBatch('+b.id+')">删除</button></div></div>'
    }).join('') || '<div class="muted">暂无库存，先添加一些吧。</div>')
    +'</div></div>';
}
function renderRecipes(){
  var rs=S.recipes, rIngs=S.rIngs;
  $('#page').innerHTML=''
    +'<div class="card"><h3 class="title">新增菜谱</h3><div class="row"><input id="rname" placeholder="菜名"><input id="rtime" type="number" placeholder="时长(min)" value="15"><button onclick="onAddRecipe()">保存</button></div></div>'
    +rs.map(function(r){
      return '<div class="card"><div class="row" style="justify-content:space-between"><h3 class="title">'+r.name+'</h3><button class="ghost" onclick="onRemoveRecipe('+r.id+')">删除</button></div>'
      +'<div class="muted">用料：</div><ul class="list">'+(rIngs.filter(function(x){return x.recipeId===r.id}).map(function(x){return '<li class="row" style="justify-content:space-between"><span>'+x.name+'</span><span class="muted">'+x.need+x.unit+'</span></li>'}).join('') || '<div class="muted">暂无用料</div>')+'</ul>'
      +'<div class="row" style="margin-top:8px"><input id="ing-'+r.id+'" placeholder="用料名称"><input id="qty-'+r.id+'" type="number" placeholder="数量"><select id="unit-'+r.id+'"><option value="g">g</option><option value="ml">ml</option><option value="pcs">个</option></select><button onclick="onAddRecipeIng('+r.id+')">加入</button></div>'
      +'</div>';
    }).join('');
}
function renderList(){
  var items=S.list;
  $('#page').innerHTML=''
    +'<div class="card"><h3 class="title">添加到购物清单</h3><div class="row"><input id="lname" placeholder="名称"><input id="lqty" type="number" placeholder="数量"><select id="lunit"><option value="g">g</option><option value="ml">ml</option><option value="pcs">个</option></select><button onclick="onAddList()">添加</button></div></div>'
    +'<div class="card"><div class="row" style="justify-content:space-between"><h3 class="title">购物清单</h3><button class="ghost" onclick="onClearList()">清空</button></div><div class="list">'
    +(items.map(function(i){return '<div class="row" style="justify-content:space-between"><span>'+i.name+'</span><div class="row" style="flex:none;gap:8px"><span class="muted">'+i.qty+i.unit+'</span><button class="ghost" onclick="onRemoveList(\''+i.name+'\')">删除</button></div></div>'}).join('') || '<div class="muted">暂无条目</div>')
    +'</div></div>';
}
function renderSettings(){
  var p=S.prefs;
  $('#page').innerHTML=''
    +'<div class="card"><h3 class="title">口味与禁忌</h3>'
    +'<div class="row"><input id="disliked" placeholder="不喜欢的食材（逗号分隔）" value="'+(p.disliked||[]).join(',')+'"></div>'
    +'<div class="row"><input id="allergens" placeholder="过敏原（逗号分隔）" value="'+(p.allergens||[]).join(',')+'"></div>'
    +'<div class="row"><input id="cuisines" placeholder="偏好菜系（如 家常, 川菜）" value="'+(p.cuisines||[]).join(',')+'"></div>'
    +'<div class="row"><label class="label">辣度</label><input id="spice" type="range" min="0" max="3" value="'+(p.spice||1)+'" oninput="document.getElementById(\'spiceValue\').innerText=this.value"><span id="spiceValue" class="muted">'+(p.spice||1)+'</span></div>'
    +'<div class="row" style="margin-top:8px"><button onclick="onSavePrefs()">保存</button></div></div>'
    +'<div class="card"><h3 class="title">关于</h3><div class="muted">本页面支持离线；若页面异常，请强制刷新或清除站点数据。</div></div>';
}

// handlers
function onTab(t){
  var tabs=document.querySelectorAll('.tabbar button'); for(var i=0;i<tabs.length;i++) tabs[i].classList.remove('active');
  var el=document.getElementById('tab-'+t); if(el) el.classList.add('active');
  location.hash=t;
  if(t==='recommend') renderRecommend();
  if(t==='inventory') renderInventory();
  if(t==='recipes') renderRecipes();
  if(t==='list') renderList();
  if(t==='settings') renderSettings();
}
function onAddBatch(){
  var name=document.getElementById('ingName').value.trim();
  var qty=Number(document.getElementById('qty').value);
  var unit=document.getElementById('unit').value;
  var days=Number(document.getElementById('days').value||3);
  var loc=document.getElementById('loc').value;
  if(!name||qty<=0){alert('请输入名称与数量');return}
  var ing=S.ings.find?S.ings.find(function(i){return i.name===name}):null;
  if(!ing){var id=(last(S.ings)?last(S.ings).id:0)+1; ing={id:id,name:name,unit:unit,shelf:days}; S.ings.push(ing); store.set('ingredients',S.ings);}
  var id2=(last(S.stock)?last(S.stock).id:0)+1; var purchase=nowISO(); var expire=plusDays(purchase,days);
  S.stock.push({id:id2,ingId:ing.id,qty:qty,unit:unit,purchase:purchase,expire:expire,location:loc}); store.set('stock',S.stock); renderInventory();
}
function onRemoveBatch(id){S.stock=S.stock.filter(function(b){return b.id!==id}); store.set('stock',S.stock); renderInventory()}
function onAddRecipe(){
  var name=document.getElementById('rname').value.trim(); var time=Number(document.getElementById('rtime').value||15);
  if(!name){alert('请输入菜名');return}
  var id=(last(S.recipes)?last(S.recipes).id:100)+1; S.recipes.push({id:id,name:name,tags:['家常']}); store.set('recipes',S.recipes); renderRecipes();
}
function onRemoveRecipe(id){S.recipes=S.recipes.filter(function(r){return r.id!==id}); S.rIngs=S.rIngs.filter(function(x){return x.recipeId!==id}); store.set('recipes',S.recipes); store.set('recipeIngs',S.rIngs); renderRecipes()}
function onAddRecipeIng(id){var name=document.getElementById('ing-'+id).value.trim(); var qty=Number(document.getElementById('qty-'+id).value); var unit=document.getElementById('unit-'+id).value;
  if(!name||qty<=0){alert('请输入用料名称与数量');return}
  var ing=S.ings.find?S.ings.find(function(i){return i.name===name}):null;
  if(!ing){var nid=(last(S.ings)?last(S.ings).id:0)+1; ing={id:nid,name:name,unit:unit,shelf:5}; S.ings.push(ing); store.set('ingredients',S.ings);}
  S.rIngs.push({recipeId:id,ingId:ing.id,name:ing.name,need:qty,unit:unit}); store.set('recipeIngs',S.rIngs); renderRecipes();
}
function onCook(id){cookAndDeduct(id); alert('已扣减库存'); onTab('inventory')}
function onAddMissing(id){var miss=diffForRecipe(id); var list=S.list; for(var i=0;i<miss.length;i++){var m=miss[i]; var ex=list.find?list.find(function(x){return x.name===m.name&&x.unit===m.unit}):null; if(ex)ex.qty+=Math.ceil(m.shortage); else list.push({name:m.name,qty:Math.ceil(m.shortage),unit:m.unit});} store.set('list',list); alert('已加入购物清单')}
function onAddList(){var name=document.getElementById('lname').value.trim(); var qty=Number(document.getElementById('lqty').value); var unit=document.getElementById('lunit').value; if(!name||qty<=0)return; S.list.push({name:name,qty:qty,unit:unit}); store.set('list',S.list); renderList()}
function onRemoveList(name){S.list=S.list.filter(function(i){return i.name!==name}); store.set('list',S.list); renderList()}
function onClearList(){S.list=[]; store.set('list',S.list); renderList()}
function onSavePrefs(){var p={disliked:document.getElementById('disliked').value.split(/[，,\\s]+/).map(function(x){return x.trim()}).filter(Boolean),allergens:document.getElementById('allergens').value.split(/[，,\\s]+/).map(function(x){return x.trim()}).filter(Boolean),cuisines:document.getElementById('cuisines').value.split(/[，,\\s]+/).map(function(x){return x.trim()}).filter(Boolean),spice:Number(document.getElementById('spice').value||1)}; S.prefs=p; alert('已保存偏好设置')}

// init
function renderApp(){
  document.getElementById('app').innerHTML=''
    +'<div class="app">'
    +'<header><h1>Kitchen Assistant · 厨房</h1></header>'
    +'<main class="container"><div id="page"></div></main>'
    +'<nav class="tabbar">'
    +'<button id="tab-recommend" onclick="onTab(\\'recommend\\')">推荐</button>'
    +'<button id="tab-inventory" onclick="onTab(\\'inventory\\')">库存</button>'
    +'<button id="tab-recipes" onclick="onTab(\\'recipes\\')">菜谱</button>'
    +'<button id="tab-list" onclick="onTab(\\'list\\')">清单</button>'
    +'<button id="tab-settings" onclick="onTab(\\'settings\\')">我的</button>'
    +'</nav></div>';
  var t=(location.hash&&location.hash.slice(1))||'recommend'; onTab(t);
}
renderApp();

// SW
if('serviceWorker' in navigator){window.addEventListener('load',function(){navigator.serviceWorker.register('sw.js').catch(function(){})})}
