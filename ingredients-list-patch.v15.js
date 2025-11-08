// ingredients-list-patch.v15.js（一个分隔符也拆分，范围限定到 .ings/用料邻近）
(function(){
  const SEP = /[，,、/;；|]+/g;
  function tokenize(t){ return (t||'').split(SEP).map(s=>s.trim()).filter(Boolean).filter(s=>!/nullg/i.test(s)); }
  function isCandidate(el){
    if(!el) return false;
    const okParent = el.closest('.ings') || el.closest('.card') || el.closest('.recipe-card');
    if(!okParent) return false;
    const txt = (el.textContent||"").trim(); if(!txt) return false;
    const seps = (txt.match(SEP)||[]).length; if(seps < 1) return false;
    if(/步骤|做法|说明|提示/.test(txt)) return false;
    return true;
  }
  function renderList(el){
    const items = tokenize(el.textContent||""); if(items.length <= 1) return;
    const ul = document.createElement("ul"); ul.className = "ing-list";
    for(const it of items){ const li = document.createElement("li"); li.textContent = it; ul.appendChild(li); }
    el.replaceWith(ul);
  }
  function patchCard(card){
    const holder = card.querySelector('.ings');
    if(holder){ const blocks = Array.from(holder.querySelectorAll('p,div,span')); for(const b of blocks){ if(isCandidate(b)) { renderList(b); return; } } }
    const labels = Array.from(card.querySelectorAll("*")).filter(x=>/用料/.test(x.textContent||""));
    for(const lab of labels){ let n = lab; for(let i=0;i<3;i++){ n = n && n.nextElementSibling; if(!n) break; if(isCandidate(n)) { renderList(n); return; } } }
  }
  function patch(){ const cards = Array.from(document.querySelectorAll(".card, .recipe, .recipe-card, [class*='card']"));
    if(cards.length===0){ if(isCandidate(document.body)) renderList(document.body); return; }
    for(const c of cards){ patchCard(c); } }
  function ready(fn){ document.readyState!=="loading" ? fn() : document.addEventListener("DOMContentLoaded", fn); }
  ready(function(){ patch(); setTimeout(patch, 800); const ps = history.pushState; history.pushState = function(){ ps.apply(this, arguments); setTimeout(patch, 250); }; });
})();
