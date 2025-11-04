
// PATCH v6: replace fmt implementation and avoid noisy error overlay
(function(){
  if (!window.__fmt_patched_v6){
    window.__fmt_patched_v6 = true;
    window.fmt = function(q,u){
      if(u==='pcs') return String(Math.round(q))+'个';
      if(q>=1000) return (q/1000).toFixed(1)+(u==='g'?'kg':'L');
      return String(q)+(u||'');
    };
  }
})();
