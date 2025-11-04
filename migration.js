
// v8 migration: ensure no duplicates by name; run once
(function(){
  var FLAG='mig_v8_done'; if(localStorage.getItem(FLAG)) return;
  function get(k,d){ try{ return JSON.parse(localStorage.getItem(k)) ?? d }catch(_){ return d } }
  function set(k,v){ try{ localStorage.setItem(k, JSON.stringify(v)) }catch(_){ } }
  var ings=get('ingredients',[]), recs=get('recipes',[]), rIngs=get('recipeIngs',[]), stock=get('stock',[]);
  var byName={}, map={}, out=[]; 
  for(var i=0;i<ings.length;i++){var it=ings[i], k=(it.name||'').trim(); if(!k) continue; if(!byName[k]){byName[k]=it; map[it.id]=it.id; out.push(it);} else {map[it.id]=byName[k].id;}}
  for(var i=0;i<rIngs.length;i++){var row=rIngs[i]; if(map[row.ingId]!=null) row.ingId=map[row.ingId];}
  for(var i=0;i<stock.length;i++){var b=stock[i]; if(map[b.ingId]!=null) b.ingId=map[b.ingId];}
  set('ingredients',out);

  byName={}; map={}; var outR=[];
  for(var i=0;i<recs.length;i++){var it=recs[i], k2=(it.name||'').trim(); if(!k2) continue; if(!byName[k2]){byName[k2]=it; map[it.id]=it.id; outR.push(it);} else {map[it.id]=byName[k2].id;}}
  for(var i=0;i<rIngs.length;i++){var row=rIngs[i]; if(map[row.recipeId]!=null) row.recipeId=map[row.recipeId];}
  set('recipeIngs', rIngs); set('recipes', outR); set('stock', stock);
  localStorage.setItem(FLAG,'1');
  console.log('[migration v8] done');
})();
