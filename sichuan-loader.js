
// v8 loader: merge once for Sichuan data already in /data/sichuan-recipes.json
(async function(jsonPath='./data/sichuan-recipes.json?v=8'){
  try{
    const FLAG='sichuan_v8_merged';
    if(localStorage.getItem(FLAG)){ console.log('[sichuan v8] already merged'); return; }
    const res = await fetch(jsonPath, {cache:'no-store'}); if(!res.ok) return;
    const pack = await res.json(); const addRecipes = Array.isArray(pack.recipes)?pack.recipes:[]; const addMap=pack.recipe_ingredients||{};
    const get=(k,d)=>{ try{ return JSON.parse(localStorage.getItem(k)) ?? d }catch(_){ return d } };
    const set=(k,v)=>{ try{ localStorage.setItem(k, JSON.stringify(v)) }catch(_){ } };
    let ings=get('ingredients',[]), recs=get('recipes',[]), rIngs=get('recipeIngs',[]);
    const seen=new Set(recs.map(r=>(r.name||'').trim()));
    const nextIngId=()=> (ings.length?(ings[ings.length-1].id||0):0)+1;
    function ensureIng(name, unit){ var x=ings.find(function(i){return i.name===name}); if(x) return x; x={id:nextIngId(), name:name, unit:unit||'g', shelf: (unit==='pcs'?14:5)}; ings.push(x); return x; }
    for(var i=0;i<addRecipes.length;i++){
      var r=addRecipes[i]; var key=(r.name||'').trim(); if(!key||seen.has(key)) continue;
      recs.push({id:r.id||key, name:r.name, tags:r.tags||['川菜']}); seen.add(key);
      var list=addMap[r.id]||[]; for(var j=0;j<list.length;j++){ var it=list[j]; var ing=ensureIng(it.item, it.unit||'g'); rIngs.push({recipeId:r.id||key, ingId:ing.id, name:it.item, need:it.qty, unit:it.unit||'g'}); }
    }
    set('ingredients', ings); set('recipes', recs); set('recipeIngs', rIngs); localStorage.setItem(FLAG,'1');
    if(typeof window.onTab==='function'){ var t=(location.hash||'#recommend').slice(1); window.onTab(t||'recommend'); }
    console.log('[sichuan v8] merged', addRecipes.length);
  }catch(e){ console.warn('sichuan v8 error', e); }
})();
