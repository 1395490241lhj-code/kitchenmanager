
(async function loadSichuanRecipes(jsonPath = './data/sichuan-recipes.json?v=4'){
  try {
    const res = await fetch(jsonPath, { cache: 'no-store' });
    if (!res.ok) return;
    const pack = await res.json();
    const addRecipes = Array.isArray(pack.recipes) ? pack.recipes : [];
    const addIngsMap = pack.recipe_ingredients || {};

    const get = (k,d=[]) => { try { return JSON.parse(localStorage.getItem(k)) ?? d } catch { return d } }
    const set = (k,v) => { try { localStorage.setItem(k, JSON.stringify(v)) } catch(e){} }
    let ings = get('ingredients', []);
    let recipes = get('recipes', []);
    let rIngs = get('recipeIngs', []);

    const seen = new Set(recipes.map(r => (r.name||'').trim()));
    const nextIngId = ()=> (ings.at(-1)?.id || 0) + 1;
    const getOrCreateIng = (name, unitGuess='g') => {
      let ing = ings.find(i=>i.name===name);
      if(ing) return ing;
      const shelf = unitGuess==='pcs' ? 14 : 5;
      const id = nextIngId();
      ing = { id, name, unit: unitGuess, shelf };
      ings.push(ing);
      return ing;
    };

    for(const r of addRecipes){
      const k = (r.name||'').trim();
      if(!k || seen.has(k)) continue;
      recipes.push({ id: r.id, name: r.name, tags: r.tags||[] });
      seen.add(k);
      const items = addIngsMap[r.id] || [];
      for(const it of items){
        const unit = it.unit || 'g';
        const ing = getOrCreateIng(it.item, unit);
        rIngs.push({ recipeId: r.id, ingId: ing.id, name: it.item, need: it.qty, unit });
      }
    }
    set('ingredients', ings); set('recipes', recipes); set('recipeIngs', rIngs);
    if(typeof window.onTab==='function'){ onTab('recommend'); }
    console.log('[Sichuan] merged', addRecipes.length, 'recipes');
  } catch (err) { console.warn('loadSichuanRecipes failed:', err); }
})();
