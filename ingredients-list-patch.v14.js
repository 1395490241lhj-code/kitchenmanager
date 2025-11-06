// ingredients-list-patch.v14.js
// Purpose: Turn comma-joined ingredient text into <ul><li>...</li></ul>
// Works without changing your existing app code.
(function(){
  function tokenize(t){
    // split by Chinese/English comma or '、'
    return t.split(/[，,、]/g)
      .map(s=>s.trim())
      .filter(s=>s && !/nullg/i.test(s)); // drop "nullg" artifacts
  }
  function isIngredientParagraph(el){
    if(!el) return false;
    const txt = (el.textContent||"").trim();
    if(!txt) return false;
    // too short -> probably not the long list
    if(txt.length < 6) return false;
    // must contain at least two separators
    const seps = (txt.match(/[，,、]/g)||[]).length;
    if(seps < 2) return false;
    // avoid matching long descriptions with punctuation like "步骤"
    if(/步骤|做法|说明|提示/.test(txt)) return false;
    return true;
  }
  function renderList(el){
    const txt = el.textContent || "";
    const items = tokenize(txt);
    if(items.length <= 1) return;
    const ul = document.createElement("ul");
    ul.className = "ing-list";
    for(const it of items){
      const li = document.createElement("li");
      li.textContent = it;
      ul.appendChild(li);
    }
    // replace
    el.replaceWith(ul);
  }
  function findIngredientBlock(card){
    // try common selectors
    const candidates = [];
    // any element after a "用料" label in this card
    const labels = Array.from(card.querySelectorAll("*")).filter(x=>/用料/.test(x.textContent||""));
    for(const lab of labels){
      let n = lab;
      for(let i=0;i<5;i++){
        n = n && n.nextElementSibling;
        if(!n) break;
        candidates.push(n);
      }
    }
    // also scan all <p>/<div> that look like comma-joined text
    const textBlocks = Array.from(card.querySelectorAll("p,div,span"));
    for(const el of textBlocks){
      if(isIngredientParagraph(el)) candidates.push(el);
    }
    // return first good one
    for(const el of candidates){
      if(isIngredientParagraph(el)) return el;
    }
    return null;
  }
  function patch(){
    const cards = Array.from(document.querySelectorAll(".card, .recipe, .recipe-card, [class*='card']"));
    if(cards.length===0){
      // Fallback: try the whole document
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
    // patch again after SPA route changes
    setTimeout(patch, 800);
    const _pushState = history.pushState;
    history.pushState = function(){ _pushState.apply(this, arguments); setTimeout(patch, 250); };
  });
})();