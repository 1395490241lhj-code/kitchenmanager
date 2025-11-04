
// very small app shell + seed (kept minimal; loader supplies recipes)
localStorage.getItem('ingredients')||localStorage.setItem('ingredients','[]');
localStorage.getItem('recipes')||localStorage.setItem('recipes','[]');
localStorage.getItem('recipeIngs')||localStorage.setItem('recipeIngs','[]');
window.onTab=function(t){document.getElementById('page').innerHTML='<div>已加载：'+(JSON.parse(localStorage.getItem('recipes')||'[]').length)+' 道菜谱</div>';};
window.addEventListener('DOMContentLoaded',()=>{document.getElementById('app').innerHTML='<div id=page>...</div>';onTab('recommend');});
if('serviceWorker' in navigator){window.addEventListener('load',()=>navigator.serviceWorker.register('sw.js').catch(()=>{}))}
