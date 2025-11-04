
// v6 migration: deduplicate recipes & ingredients and remap IDs; run once
(function(){
  var FLAG='mig_v6_done';
  if (localStorage.getItem(FLAG)) return;

  function get(k,d){ try{ return JSON.parse(localStorage.getItem(k)) ?? d }catch(e){ return d } }
  function set(k,v){ try{ localStorage.setItem(k, JSON.stringify(v)) }catch(e){} }

  var ings = get('ingredients', []);
  var recipes = get('recipes', []);
  var rIngs = get('recipeIngs', []);
  var stock = get('stock', []);

  // --- Ingredient de-dup by name ---
  var ingByName = Object.create(null);
  var ingIdMap = Object.create(null);
  var newIngs = [];
  for (var i=0;i<ings.length;i++){
    var ing = ings[i]; var key = (ing.name||'').trim();
    if (!key) continue;
    if (!ingByName[key]){
      ingByName[key] = ing;
      ingIdMap[ing.id] = ing.id;
      newIngs.push(ing);
    } else {
      ingIdMap[ing.id] = ingByName[key].id;
    }
  }
  // Remap references
  for (var i=0;i<rIngs.length;i++){
    var row = rIngs[i];
    if (row && row.ingId!=null && ingIdMap[row.ingId]!=null){
      row.ingId = ingIdMap[row.ingId];
    }
  }
  for (var i=0;i<stock.length;i++){
    var b = stock[i];
    if (b && b.ingId!=null && ingIdMap[b.ingId]!=null){
      b.ingId = ingIdMap[b.ingId];
    }
  }

  // --- Recipe de-dup by name ---
  var recByName = Object.create(null);
  var recIdMap = Object.create(null);
  var newRecs = [];
  for (var i=0;i<recipes.length;i++){
    var r = recipes[i]; var key = (r.name||'').trim();
    if (!key) continue;
    if (!recByName[key]){
      recByName[key] = r;
      recIdMap[r.id] = r.id;
      newRecs.push(r);
    } else {
      recIdMap[r.id] = recByName[key].id;
    }
  }
  // Remap recipeId in rIngs
  for (var i=0;i<rIngs.length;i++){
    var row = rIngs[i];
    if (row && row.recipeId!=null && recIdMap[row.recipeId]!=null){
      row.recipeId = recIdMap[row.recipeId];
    }
  }
  // Filter rIngs to existing recipes
  var keepIds = {}; for (var i=0;i<newRecs.length;i++){ keepIds[newRecs[i].id]=1 }
  rIngs = rIngs.filter(function(x){ return keepIds[x.recipeId] });

  set('ingredients', newIngs);
  set('recipes', newRecs);
  set('recipeIngs', rIngs);
  set('stock', stock);

  localStorage.setItem(FLAG,'1');
  console.log('[migration v6] dedup done: ings=',newIngs.length,'recipes=',newRecs.length,'links=',rIngs.length);
})();
