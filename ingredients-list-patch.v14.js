
// ingredients-list-patch.v14.js
(function(){
  function tokenize(t){
    return t.split(/[，,、]/g).map(s=>s.trim()).filter(Boolean).filter(s => !/nullg/i.test(s));
  }
  function isIngredientParagraph(el){
    if(!el) return false;
    const txt = (el.textContent||"").trim();
    if(txt.length < 6) return false;
    const seps = (txt.match(/[，,、]/g)||[]).length;
    if(seps < 2) return false;
    if(/步骤|做法|说明|提示/.test(txt)) return false;
    return true;
  }
  function renderList(el){
    const items = tokenize(el.textContent||"");
    if(items.length <= 1) return;
    const ul = document.createElement("ul");
    ul.className = "ing-list";
    for(const it of items){
      const li = document.createElement("li");
      li.textContent = it;
      ul.appendChild(li);
    }
    el.replaceWith(ul);
  }
  function findIngredientBlock(card){
    const candidates = [];
    const labels = Array.from(card.querySelectorAll("*")).filter(x=>/用料/.test(x.textContent||""));
    for(const lab of labels){
      let n = lab;
      for(let i=0;i<5;i++){
        n = n && n.nextElementSibling;
        if(!n) break;
        candidates.push(n);
      }
    }
    const textBlocks = Array.from(card.querySelectorAll("p,div,span"));
    for(const el of textBlocks){
      if(isIngredientParagraph(el)) candidates.push(el);
    }
    for(const el of candidates){
      if(isIngredientParagraph(el)) return el;
    }
    return null;
  }
  function patch(){
    const cards = Array.from(document.querySelectorAll(".card, .recipe, .recipe-card, [class*='card']"));
    if(cards.length===0){
      const el = findIngredientBlock(document.body);
      if(el) renderList(el);
      return;
    }
    for(const c of cards){
      const el = findIngredientBlock(c);
      if(el) renderList(el);
    }
  }
  function ready(fn){ 
    if(document.readyState!=="loading") fn(); 
    else document.addEventListener("DOMContentLoaded", fn); 
  }
  ready(function(){
    patch();
    setTimeout(patch, 800);
    const _pushState = history.pushState;
    history.pushState = function(){ _pushState.apply(this, arguments); setTimeout(patch, 250); };
  });
})();
