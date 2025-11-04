
// v6 loader: merge once, skip if already merged
(async function(jsonPath='./data/sichuan-recipes.json?v=6'){
  try{
    const FLAG='sichuan_v6_merged';
    if(localStorage.getItem(FLAG)){ console.log('[sichuan-loader v6] already merged'); return; }
    const res = await fetch(jsonPath, {cache:'no-store'});
    if(!res.ok) { console.warn('[sichuan-loader v6] JSON not available', res.status); return; }
    const pack = await res.json();
    const addRecipes = Array.isArray(pack.recipes)?pack.recipes:[];
    const addMap = pack.recipe_ingredients || {};

    const get=(k,d)=>{ try{ return JSON.parse(localStorage.getItem(k)) ?? d }catch(_){ return d } };
    const set=(k,v)=>{ try{ localStorage.setItem(k, JSON.stringify(v)) }catch(_){ } };

    let ings=get('ingredients',[]), recs=get('recipes',[]), rIngs=get('recipeIngs',[]);
    const seenNames=new Set(recs.map(r=>(r.name||'').trim()));

    const nextIngId = ()=> (ings.length? (ings[ings.length-1].id||0) : 0) + 1;
    const ensureIng = (name, unit='g') => {
      let x = ings.find(i=>i.name===name);
      if (x) return x;
      x = { id: nextIngId(), name, unit, shelf: unit==='pcs'?14:5 };
      ings.push(x); return x;
    };

    for(const r of addRecipes){
      const key=(r.name||'').trim();
      if(!key || seenNames.has(key)) continue;
      recs.push({ id:r.id||key, name:r.name, tags:r.tags||['川菜'] });
      seenNames.add(key);
      const list = addMap[r.id]||[];
      for(const it of list){
        const ing = ensureIng(it.item, it.unit||'g');
        rIngs.push({ recipeId: r.id||key, ingId: ing.id, name: it.item, need: it.qty, unit: it.unit||'g' });
      }
    }

    set('ingredients', ings); set('recipes', recs); set('recipeIngs', rIngs);
    localStorage.setItem(FLAG,'1'); // mark once

    if(typeof window.onTab==='function'){
      const t=(location.hash||'#recommend').slice(1); window.onTab(t||'recommend');
    }
    console.log('[sichuan-loader v6] merged', addRecipes.length, 'recipes');
  }catch(e){ console.warn('[sichuan-loader v6] error', e); }
})();
