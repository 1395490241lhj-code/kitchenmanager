
// 自动加载四川菜谱（带缓存破除）
(async function(jsonPath = './data/sichuan-recipes.json?v=5'){
  try{
    const res = await fetch(jsonPath, { cache: 'no-store' });
    if(!res.ok) { console.warn('sichuan-loader: JSON not found', res.status); return; }
    const pack = await res.json();
    const addRecipes = Array.isArray(pack.recipes)? pack.recipes : [];
    const addIngs = pack.recipe_ingredients || {};

    const get=(k,d)=>{ try{return JSON.parse(localStorage.getItem(k)) ?? d;}catch(_){return d;} };
    const set=(k,v)=>{ try{ localStorage.setItem(k, JSON.stringify(v)); }catch(_){ } };
    const ings=get('ingredients',[]), recs=get('recipes',[]), rIngs=get('recipeIngs',[]);
    const seen=new Set(recs.map(r=>(r.name||'').trim()));

    function nextIngId(){ return ings.length? (ings[ings.length-1].id||0)+1 : 1 }
    function ensureIng(name, unit){ var it=ings.find(i=>i.name===name); if(it) return it; var obj={id:nextIngId(), name, unit:unit||'g', shelf:5}; ings.push(obj); return obj; }

    for(const r of addRecipes){
      const k=(r.name||'').trim(); if(!k || seen.has(k)) continue;
      recs.push({ id:r.id||k, name:r.name, tags:r.tags||['川菜'] });
      seen.add(k);
      const list=addIngs[r.id]||[];
      for(const it of list){
        const ing=ensureIng(it.item, it.unit); rIngs.push({ recipeId: r.id||k, ingId: ing.id, name: it.item, need: it.qty, unit: it.unit||'g' });
      }
    }
    set('ingredients',ings); set('recipes',recs); set('recipeIngs',rIngs);

    // 若当前在推荐或菜谱页，刷新一次
    if(typeof window.onTab==='function'){
      const t=(location.hash||'#recommend').slice(1); window.onTab(t||'recommend');
    }
    console.log('[sichuan-loader v5] merged', addRecipes.length, 'recipes');
  }catch(e){ console.warn('sichuan-loader error', e); }
})();
