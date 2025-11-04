
// sichuan-loader.js
(async function(jsonPath = './data/sichuan-recipes.json'){
  try{
    const res = await fetch(jsonPath, { cache: 'no-store' });
    if(!res.ok) return;
    const pack = await res.json();
    const addRecipes = Array.isArray(pack.recipes) ? pack.recipes : [];
    const addIngs = pack.recipe_ingredients || {};

    const get=(k,d)=>{ try{return JSON.parse(localStorage.getItem(k)) ?? d;}catch(e){return d;} };
    const set=(k,v)=>{ try{ localStorage.setItem(k, JSON.stringify(v)); }catch(e){} };
    const S = { ings:get('ingredients',[]), recs:get('recipes',[]), rIngs:get('recipeIngs',[]) };

    const NAME_MAP = {"猪腿肉":"猪肉","猪里脊":"猪肉","五花肉":"猪肉","鸡脯肉":"鸡肉","仔鸡":"鸡肉","仔鸡肉":"鸡肉","葱白":"葱","清汤/水":"清汤","泡红辣椒":"泡椒","木耳":"黑木耳","大米粉":"米粉"};
    const norm = n => NAME_MAP[n] || n;
    const seen = new Set(S.recs.map(r => (r.name||'').trim()));

    for(const r of addRecipes){
      const k = (r.name||'').trim();
      if(!k || seen.has(k)) continue;
      S.recs.push({ id:r.id, name:r.name, tags:r.tags||[], spice:r.spice, numbing:r.numbing, source:r.source, source_page:r.source_page });
      seen.add(k);
    }

    const nextIngId = ()=> (S.ings.at(-1)?.id || 0) + 1;
    const getOrCreateIng = (name, unitGuess='g') => {
      let ing = S.ings.find(i=>i.name===name);
      if(ing) return ing;
      const shelf = unitGuess==='pcs' ? 14 : 5;
      const id = nextIngId();
      ing = { id, name, unit: unitGuess, shelf };
      S.ings.push(ing);
      return ing;
    };

    for(const r of addRecipes){
      const list = addIngs[r.id] || [];
      for(const it of list){
        const name = norm(it.item);
        const unit = it.unit || 'g';
        const ing = getOrCreateIng(name, unit);
        S.rIngs.push({ recipeId: r.id, ingId: ing.id, name, need: it.qty, unit });
      }
    }

    set('ingredients', S.ings); set('recipes', S.recs); set('recipeIngs', S.rIngs);

    if(typeof window.onTab === 'function'){
      const hash = location.hash?.slice(1)||'recommend'; window.onTab(hash);
    }
    console.log('[sichuan-loader] merged', addRecipes.length, 'recipes');
  }catch(e){ console.warn('sichuan-loader error:', e); }
})();
