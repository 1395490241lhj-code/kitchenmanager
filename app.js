 (cd "$(git rev-parse --show-toplevel)" && git apply --3way <<'EOF' 
diff --git a/app.js b/app.js
index 6fc8d1c86ba0bf779417c185c35da7f6c7d75cef..0ff23306a9ee3d2df2aa0fe151f374cc6fdf9306 100644
--- a/app.js
+++ b/app.js
@@ -1,34 +1,35 @@
 // v81 app.js - 修复 AI 模型 ID (Groq 专用配置) + 完整功能
 const el = (sel, root=document) => root.querySelector(sel);
 const els = (sel, root=document) => Array.from(root.querySelectorAll(sel));
 const app = el('#app');
 const todayISO = () => new Date().toISOString().slice(0,10);
 
 // --- AI 配置 (修正为 Groq 真实支持的模型) ---
 const CUSTOM_AI = {
-  URL: "(https://api.groq.com/openai/v1/chat/completions)",
+  // API 根地址（去掉意外的括号，避免请求失败）
+  URL: "https://api.groq.com/openai/v1/chat/completions",
   KEY: "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", // 您的 Key
   // 文本模型：Groq 目前最强文本模型
   MODEL: "qwen/qwen3-32b", 
   // 视觉模型：Groq 目前最强视觉模型
   VISION_MODEL: "meta-llama/llama-4-maverick-17b-128e-instruct" 
 };
 
 // --- 食材归一化字典 ---
 const INGREDIENT_ALIASES = {
   "五花肉": ["五花猪肉", "猪五花", "三线肉", "带皮五花肉", "五花"],
   "肥膘": ["猪肥膘", "肥膘肉", "熟猪肥膘", "熟猪肥膘肉", "熟猪肥膘片", "板油", "猪板油", "肥肉"],
   "瘦肉": ["猪瘦肉", "精瘦肉", "里脊", "里脊肉"],
   "猪肉": ["肉", "猪肉片", "猪肉丝", "肉丝", "肉片", "肉末", "猪腿肉", "二刀肉", "肥瘦肉", "肥瘦猪肉"], 
   "排骨": ["猪排", "猪排骨", "小排", "大排", "纤排"],
   "猪蹄": ["猪脚", "猪手", "蹄花"],
   "猪肚": ["肚头", "猪肚头"],
   "猪腰": ["猪腰子", "腰花", "腰片"],
   "猪肝": ["沙肝", "肝片"],
   "牛肉": ["黄牛肉", "嫩牛肉", "牛肉片", "牛肉丝", "牛柳", "肥牛"],
   "牛腩": ["牛肋条"],
   "羊肉": ["羊肉片", "羊肉卷"],
   "鸡肉": ["仔鸡", "公鸡", "嫩鸡", "土鸡", "三黄鸡", "鸡块", "鸡丁", "鸡丝", "鸡条", "生鸡肉"],
   "鸡脯肉": ["鸡脯", "鸡胸", "鸡胸肉", "鸡柳", "生鸡脯", "熟鸡脯"],
   "鸡腿": ["大鸡腿", "小鸡腿", "琵琶腿", "鸡腿肉", "熟鸡腿"],
   "鸡翅": ["鸡翅膀", "鸡中翅", "翅尖"],
@@ -639,58 +640,77 @@ function renderHome(pack){
        recDiv.querySelector('.section-title').appendChild(clearBtn);
      } else { showRecommendationCards(recGrid, getLocalRecommendations(pack, inv), pack); }
   } else { showRecommendationCards(recGrid, getLocalRecommendations(pack, inv), pack); }
   
   const aiBtn = recDiv.querySelector('#callAiBtn'); 
   aiBtn.onclick = async () => { 
     aiBtn.innerHTML = '<span class="spinner"></span> 思考中...'; aiBtn.style.opacity = '0.7'; 
     try { 
       const aiResult = await callCloudAI(pack, inv); 
       S.save(S.keys.ai_recs, aiResult);
       const newCards = processAiData(aiResult, pack);
       if(newCards.length > 0) { showRecommendationCards(recGrid, newCards, pack); setTimeout(() => onRoute(), 500); } 
     } catch(e) { 
       if (e.message === "FALLBACK_LOCAL" || e.message.includes("429")) {
          alert("AI 服务繁忙，已自动为您切换到本地推荐模式！");
          showRecommendationCards(recGrid, getLocalRecommendations(pack, inv), pack);
       } else {
          alert(e.message); 
       }
     } 
     finally { aiBtn.innerHTML = '✨ 呼叫 AI'; aiBtn.style.opacity = '1'; } 
   }; 
   return container; 
 }
 
-function renderInventory(pack){ const catalog=buildCatalog(pack); const inv=loadInventory(catalog); const wrap=document.createElement('div'); 
+function renderInventory(pack){ const catalog=buildCatalog(pack); const inv=loadInventory(catalog); const wrap=document.createElement('div');
   const header = document.createElement('div'); header.className = 'section-title'; header.innerHTML = '<span>库存管理</span>'; wrap.appendChild(header);
-  const searchDiv = document.createElement('div'); searchDiv.className = 'controls'; searchDiv.style.marginBottom = '8px'; 
-  searchDiv.innerHTML = `<div style="display:flex; gap:8px; width:100%; justify-content:flex-end;"><label class="btn ai icon-only" style="cursor:pointer;"><input type="file" id="camInput" accept="image/*" capture="environment" hidden>📷</label><a class="btn ok icon-only" id="toggleAddBtn">＋</a></div><div id="scanStatus" class="small" style="color:var(--accent); display:none; margin-top:4px;"></div>`; wrap.appendChild(searchDiv);
+  const searchDiv = document.createElement('div'); searchDiv.className = 'controls'; searchDiv.style.marginBottom = '8px';
+  const icons = {
+    camera: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M9.5 5L8 7H5a2 2 0 00-2 2v8a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-3l-1.5-2h-5z" fill="none" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"></path><circle cx="12" cy="13" r="3.5" fill="none" stroke-width="1.6"></circle></svg>`,
+    plus: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M12 5v14M5 12h14" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"></path></svg>`,
+    minus: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M5 12h14" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"></path></svg>`,
+  };
+  searchDiv.innerHTML = `<div style="display:flex; gap:8px; width:100%; justify-content:flex-end;">
+      <label class="btn ai icon-only" id="camButton" style="cursor:pointer;" aria-label="拍照识别">
+        <input type="file" id="camInput" accept="image/*" capture="environment" hidden>
+        ${icons.camera}
+      </label>
+      <button type="button" class="btn ok icon-only" id="toggleAddBtn" aria-label="展开入库表单"></button>
+    </div>
+    <div id="scanStatus" class="small" style="color:var(--accent); display:none; margin-top:4px;"></div>`; wrap.appendChild(searchDiv);
   const formContainer = document.createElement('div'); formContainer.className = 'add-form-container'; 
   formContainer.innerHTML = `<div style="display:flex; gap:8px; margin-bottom:8px;"><div style="flex:1; min-width:120px;"><input id="addName" list="catalogList" placeholder="食材名称" style="width:100%;"><datalist id="catalogList">${catalog.map(c=>`<option value="${c.name}">`).join('')}</datalist></div><input id="addQty" type="number" step="1" placeholder="数量" style="width:70px;"><select id="addUnit" style="width:70px;"><option value="g">g</option><option value="ml">ml</option><option value="pcs">pcs</option></select></div><div style="display:flex; gap:8px;"><input id="addDate" type="date" value="${todayISO()}" style="flex:1;"><button id="addBtn" class="btn ok" style="flex:1;">入库</button></div>`; wrap.appendChild(formContainer);
-  searchDiv.querySelector('#toggleAddBtn').onclick = () => { formContainer.classList.toggle('open'); searchDiv.querySelector('#toggleAddBtn').textContent = formContainer.classList.contains('open') ? '－' : '＋'; };
-  formContainer.querySelector('#addName').addEventListener('input', (e)=>{ const val = e.target.value.trim(); const match = catalog.find(c => c.name === val); if(match && match.unit){ formContainer.querySelector('#addUnit').value = match.unit; } }); 
+  const toggleAddBtn = searchDiv.querySelector('#toggleAddBtn');
+  const updateToggleIcon = () => {
+    const isOpen = formContainer.classList.contains('open');
+    toggleAddBtn.innerHTML = isOpen ? icons.minus : icons.plus;
+    toggleAddBtn.setAttribute('aria-label', isOpen ? '收起入库表单' : '展开入库表单');
+  };
+  updateToggleIcon();
+  toggleAddBtn.onclick = () => { formContainer.classList.toggle('open'); updateToggleIcon(); };
+  formContainer.querySelector('#addName').addEventListener('input', (e)=>{ const val = e.target.value.trim(); const match = catalog.find(c => c.name === val); if(match && match.unit){ formContainer.querySelector('#addUnit').value = match.unit; } });
   formContainer.querySelector('#addBtn').onclick=()=>{ const name=formContainer.querySelector('#addName').value.trim(); if(!name) return alert('请输入食材名称'); const qty=+formContainer.querySelector('#addQty').value||0; const unit=formContainer.querySelector('#addUnit').value; const date=formContainer.querySelector('#addDate').value||todayISO(); upsertInventory(inv,{name, qty, unit, buyDate:date, kind:'raw', shelf:guessShelfDays(name, unit)}); formContainer.querySelector('#addName').value = ''; formContainer.querySelector('#addQty').value = ''; renderTable(); };
   const tbl=document.createElement('table'); tbl.className='table'; tbl.innerHTML=`<thead><tr><th style="width:35%">食材</th><th style="width:20%">数量</th><th style="width:25%">保质</th><th class="right">操作</th></tr></thead><tbody></tbody>`; wrap.appendChild(tbl);
   const scanStatus = searchDiv.querySelector('#scanStatus');
   searchDiv.querySelector('#camInput').onchange = async (e) => {
     const file = e.target.files[0]; if(!file) return;
     scanStatus.style.display = 'block'; scanStatus.innerHTML = '<span class="spinner"></span> 识别中...';
     try {
       const items = await recognizeReceipt(file);
       scanStatus.innerHTML = `✅ 成功！入库 ${items.length} 项`;
       for(const it of items) { if(!it.name) continue; let unit = it.unit || 'g'; const name = getCanonicalName(it.name); const match = catalog.find(c => c.name === name); if(match && match.unit) unit = match.unit; upsertInventory(inv, { name: name, qty: Number(it.qty) || 1, unit: unit, buyDate: todayISO(), kind: 'raw', shelf: guessShelfDays(name, unit) }); }
       setTimeout(() => { scanStatus.style.display = 'none'; renderTable(); }, 1500);
     } catch(err) { scanStatus.innerHTML = `<span style="color:var(--danger)">❌ ${err.message}</span>`; }
   };
   function renderTable(){ 
     const tb=tbl.querySelector('tbody'); tb.innerHTML=''; 
     const filteredInv = inv; 
     filteredInv.sort((a,b)=>remainingDays(a)-remainingDays(b)); 
     if(filteredInv.length === 0) { tb.innerHTML = `<tr><td colspan="4" class="small" style="text-align:center;padding:20px;">${inv.length===0 ? '库存空空如也，快去进货！' : '未找到'}</td></tr>`; return; } 
     for(const e of filteredInv){ 
       const tr=document.createElement('tr'); 
       tr.innerHTML=`<td><span style="font-weight:600;color:var(--text-main)">${e.name}</span></td><td><div style="display:flex;align-items:center;gap:4px;"><input class="qty-input" type="number" step="1" value="${+e.qty||0}" style="width:40px;padding:2px;text-align:center;border:1px solid var(--separator);border-radius:4px;"><small>${e.unit}</small></div></td><td>${badgeFor(e)}</td><td class="right"><a class="btn bad small" style="padding:4px 8px;">删</a></td>`; 
       const qtyInput = tr.querySelector('input'); qtyInput.onchange = () => { e.qty = +qtyInput.value||0; saveInventory(inv); };
       els('.btn',tr)[0].onclick=()=>{ const i=inv.indexOf(e); if(i>=0){ inv.splice(i,1); saveInventory(inv); renderTable(); }}; tb.appendChild(tr); 
     } 
   } 
 
EOF
)
