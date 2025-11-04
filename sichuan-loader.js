
(async function(jsonPath='./data/sichuan-recipes.json?v=7'){
  try{
    const FLAG='sichuan_v7_merged';
    if(localStorage.getItem(FLAG)){ console.log('[sichuan v7] already merged'); return; }
    const res = await fetch(jsonPath,{cache:'no-store'}); if(!res.ok) return;
    const pack = await res.json(); const addRecipes=Array.isArray(pack.recipes)?pack.recipes:[]; const addMap=pack.recipe_ingredients||{};
    const get=(k,d)=>{ try{ return JSON.parse(localStorage.getItem(k)) ?? d }catch(_){ return d } };
    const set=(k,v)=>{ try{ localStorage.setItem(k, JSON.stringify(v)) }catch(_){ } };
    let ings=get('ingredients',[]), recs=get('recipes',[]), rIngs=get('recipeIngs',[]);
    const seen=new Set(recs.map(r=>(r.name||'').trim()));
    const nextIngId=()=> (ings.length? (ings[ings.length-1].id||0):0)+1;
    function ensureIng(name, unit){ let x=ings.find(i=>i.name===name); if(x) return x; x={id:nextIngId(), name, unit:unit||'g', shelf:(unit==='pcs'?14:5)}; ings.push(x); return x; }
    for(const r of addRecipes){
      const key=(r.name||'').trim(); if(!key||seen.has(key)) continue;
      recs.push({id:r.id||key, name:r.name, tags:r.tags||['川菜']}); seen.add(key);
      const list=addMap[r.id]||[];
      for(const it of list){ const ing=ensureIng(it.item, it.unit||'g'); rIngs.push({recipeId:r.id||key, ingId:ing.id, name:it.item, need:it.qty, unit:it.unit||'g'}); }
    }
    set('ingredients',ings); set('recipes',recs); set('recipeIngs',rIngs);
    localStorage.setItem(FLAG,'1');
    if(typeof window.onTab==='function'){ const t=(location.hash||'#recommend').slice(1); window.onTab(t||'recommend'); }
  }catch(e){ console.warn('sichuan v7 loader error', e); }
})();
