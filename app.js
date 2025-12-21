// v130 app.js - 更新API Key + 包含之前所有功能(库存编辑/冷冻管理/列表购买日期)
// 1. 全局错误捕获
window.onerror = function(msg, url, line, col, error) {
  const app = document.querySelector('body');
  if(app && !document.getElementById('global-err-console')) {
    const errDiv = document.createElement('div');
    errDiv.id = 'global-err-console';
    errDiv.style.cssText = "position:fixed;top:0;left:0;width:100%;height:100%;background:white;color:red;z-index:99999;padding:20px;overflow:auto;font-family:monospace;font-size:14px;border-bottom:2px solid red;";
    errDiv.innerHTML = `<h3>⚠️ 发生错误</h3><p>${msg}</p><p>Line: ${line}</p><button onclick="this.parentElement.remove()" style="padding:5px 10px;border:1px solid #333;margin-top:10px;">关闭</button>`;
    app.appendChild(errDiv);
  }
};

const el = (sel, root=document) => root.querySelector(sel);
const els = (sel, root=document) => Array.from(root.querySelectorAll(sel));
const app = el('#app');
const todayISO = () => new Date().toISOString().slice(0,10);

// --- AI 配置 ---
const CUSTOM_AI = {
  URL: "https://api.groq.com/openai/v1/chat/completions",
  KEY: "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", 
  MODEL: "qwen/qwen3-32b", 
  VISION_MODEL: "meta-llama/llama-4-scout-17b-16e-instruct" 
};

// --- Storage ---
const S = {
  save(k, v){ try { localStorage.setItem(k, JSON.stringify(v)); } catch(e){} },
  load(k, d){ try { return JSON.parse(localStorage.getItem(k)) ?? d } catch(e){ return d; } },
  keys: { 
    inventory:'km_v19_inventory', 
    plan:'km_v19_plan', 
    overlay:'km_v19_overlay', 
    settings:'km_v23_settings',
    ai_recs: 'km_v48_ai_recs',
    local_recs: 'km_v49_local_recs',
    rec_time: 'km_v49_rec_time'
  }
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
  "鸭肉": ["鸭", "鸭子", "仔鸭", "公鸭", "母鸭", "鸭脯", "鸭肉丝", "鸭肉片"],
  "鸭掌": ["鸭脚"],
  "鲜鱼": ["鱼肉", "鱼头", "鱼片", "鲜鱼中段", "鱼"], 
  "鲫鱼": ["土鲫鱼", "活鲫鱼"],
  "鲤鱼": ["江鲤", "活鲤鱼", "岩鲤"],
  "草鱼": ["鲩鱼"],
  "鲢鱼": ["白鲢", "花鲢"],
  "虾": ["鲜虾", "基围虾", "对虾", "明虾"],
  "虾仁": ["鲜虾仁", "冻虾仁"],
  "鱿鱼": ["鲜鱿鱼", "水发鱿鱼", "干鱿鱼", "鱿鱼须", "鱿鱼圈"],
  "海参": ["水发海参", "刺参", "开乌参"],
  "田鸡": ["田鸡腿", "青蛙"],
  "冬笋": ["鲜冬笋", "冬笋尖", "冬笋片"],
  "春笋": ["鲜春笋"],
  "玉兰片": ["兰片", "水发兰片", "水发玉兰片"], 
  "青菜": ["小白菜", "上海青", "瓢儿白", "油菜", "青菜头", "菜心", "青菜心", "小白菜秧"],
  "白菜": ["大白菜", "黄芽白", "绍菜", "莲花白", "卷心菜", "黄秧白"],
  "菠菜": ["菠菜叶", "菠菜心"],
  "芹菜": ["西芹", "旱芹", "药芹", "芹黄"],
  "蒜苗": ["青蒜"], 
  "蒜苔": ["蒜薹"],
  "韭菜": ["韭黄", "韭菜头", "白头韭菜"],
  "土豆": ["马铃薯", "洋芋", "土豆片", "土豆丝"],
  "红苕": ["红薯", "地瓜", "甘薯", "红心红苕"],
  "莴笋": ["青笋", "莴苣", "莴笋头", "莴笋尖", "凤尾"],
  "蚕豆": ["胡豆", "鲜蚕豆", "扁豆", "蚕豆（扁豆）"],
  "豌豆": ["青豆", "鲜豌豆", "豌豆尖", "豆尖", "鲜豌豆仁"],
  "香菇": ["冬菇", "花菇", "干香菇", "水发香菇", "冬菇（香菇）"],
  "口蘑": ["干口蘑", "水发口蘑"],
  "木耳": ["黑木耳", "云耳", "水发木耳"],
  "黄花菜": ["兰花", "干黄花菜", "兰花（干黄花菜）", "金针菜"],
  "竹荪": ["水发竹荪", "干竹荪"],
  "面粉": ["中筋面粉", "白面", "面粉（面点）"],
  "花椒": ["红花椒", "青花椒", "花椒粒", "花椒面"],
  "干辣椒": ["干海椒", "干红辣椒", "辣椒节", "辣椒面"],
  "泡辣椒": ["泡海椒", "鱼辣椒", "泡椒", "泡红辣椒", "泡鱼辣椒"],
  "豆瓣": ["豆瓣酱", "郫县豆瓣", "细豆瓣"],
  "豆粉": ["淀粉", "生粉", "水豆粉", "湿淀粉", "干豆粉"],
  "醪糟": ["醪糟汁", "醪糟浮子", "酒酿"],
  "姜": ["老姜", "生姜", "姜片", "姜米", "姜丝"],
  "子姜": ["嫩姜", "紫姜", "仔姜"],
  "蒜": ["大蒜", "蒜瓣", "独蒜", "蒜头", "蒜米", "蒜片"],
  "葱": ["大葱", "小葱", "香葱", "葱白", "葱花", "葱段", "葱节"]
};

function getCanonicalName(name) {
  if(!name) return "";
  let n = String(name).trim();
  if (checkAlias(n)) return checkAlias(n);
  const noParens = n.replace(/（.*?）|\(.*?\)/g, '').trim();
  if (noParens !== n && checkAlias(noParens)) return checkAlias(noParens);
  const prefixes = ["熟", "生", "鲜", "干", "水发", "净", "嫩"];
  let cleanPrefix = n;
  for (const p of prefixes) {
    if (cleanPrefix.startsWith(p)) cleanPrefix = cleanPrefix.substring(p.length).trim();
  }
  if (checkAlias(cleanPrefix)) return checkAlias(cleanPrefix);
  const suffixes = ["肉", "片", "丝", "末", "丁", "块", "条", "泥", "茸", "尖", "头", "仁", "皮", "腿"];
  let cleanSuffix = cleanPrefix;
  for (const s of suffixes) {
     if (cleanSuffix.endsWith(s)) {
       const tryName = cleanSuffix.slice(0, -s.length);
       if (checkAlias(tryName)) return checkAlias(tryName);
     }
  }
  return n;
}
function checkAlias(name) {
  if (INGREDIENT_ALIASES[name]) return name;
  for (const [canonical, aliases] of Object.entries(INGREDIENT_ALIASES)) {
    if (aliases.includes(name)) return canonical;
  }
  return null;
}

// --- 佐料/常备品过滤 ---
const SEASONINGS = new Set([
  "姜", "葱", "蒜", "大蒜", "生姜", "老姜", "葱白", "葱花", "姜米", "蒜泥", "大葱",
  "盐", "糖", "醋", "酱油", "生抽", "老抽", "味精", "鸡精", "料酒", "米酒", "花椒", "干辣椒", "辣椒面", "胡椒", "胡椒面",
  "油", "猪油", "菜油", "香油", "芝麻油", "豆粉", "淀粉", "水豆粉", "豆瓣", "豆瓣酱", "甜面酱", "豆豉", "泡椒", "酸菜", "酸豆角", "清汤", "水",
  "八角", "桂皮", "香叶", "五香粉", "孜然", "茴香", "鸡蛋" 
]);
function isSeasoning(name) {
  if (!name) return true;
  const n = String(name).trim();
  if (SEASONINGS.has(n)) return true;
  if (n.length <= 3 && (n.includes("盐") || n.includes("糖") || n.includes("醋") || n.includes("酱") || n.includes("油"))) return true;
  return false;
}

// -------- Data Loading --------
async function loadBasePack(){
  const url = new URL('./data/sichuan-recipes.json', location).href + '?v=23';
  let pack = {recipes:[], recipe_ingredients:{}};
  try{ 
      const res = await fetch(url, { cache:'no-store' }); 
      if(res.ok) {
          pack = await res.json(); 
          if (!Array.isArray(pack.recipes)) pack.recipes = [];
          if (!pack.recipe_ingredients) pack.recipe_ingredients = {};
      }
  } catch(e){ console.error('Base pack error', e); }
  
  const staticMethods = window.RECIPE_METHODS || {};
  const existingNames = new Set(pack.recipes.map(r => r.name));
  
  Object.keys(staticMethods).forEach(name => {
    if(!existingNames.has(name)){
      const newId = 'static-' + Math.abs(name.split('').reduce((a,b)=>{a=((a<<5)-a)+b.charCodeAt(0);return a&a},0));
      pack.recipes.push({ id: newId, name: name, tags: ["家常菜", "新增"] });
      existingNames.add(name);
    }
  });

  const hocData = window.HOC_DATA || [];
  hocData.forEach(item => {
      if(!existingNames.has(item.name)){
          const newId = 'hoc-' + Math.abs(item.name.split('').reduce((a,b)=>{a=((a<<5)-a)+b.charCodeAt(0);return a&a},0));
          pack.recipes.push({
              id: newId,
              name: item.name,
              tags: item.tags || ["家常菜"],
              staticMethod: item.method
          });
          if(item.ingredients && Array.isArray(item.ingredients)){
              pack.recipe_ingredients[newId] = item.ingredients.map(ingName => ({
                  item: ingName, qty: null, unit: null
              }));
          }
          existingNames.add(item.name);
      }
  });

  return pack;
}

function emptyOverlay(){ return {version:1, recipes:{}, recipe_ingredients:{}, deletes:{}}; }
function loadOverlay(){ return S.load(S.keys.overlay, emptyOverlay()); }
function saveOverlay(o){ S.save(S.keys.overlay, o); }
function genId(){ return 'u-' + Math.random().toString(36).slice(2,8) + '-' + Date.now().toString(36).slice(-4); }

function applyOverlay(base, overlay){
  const recipes = [];
  const ingMap = JSON.parse(JSON.stringify(base.recipe_ingredients || {}));
  const baseMap = new Map((base.recipes||[]).map(r => [r.id, {...r}]));
  const del = overlay.deletes || {};
  for(const [id, flag] of Object.entries(del)){ if(flag){ baseMap.delete(id); delete ingMap[id]; } }
  const ro = overlay.recipes || {};
  for(const [id, ov] of Object.entries(ro)){
    if(!baseMap.has(id)) {
      baseMap.set(id, {id, name: ov.name||'未命名', tags: ov.tags||[], method: ov.method||''});
    } else {
      const old = baseMap.get(id);
      const finalMethod = ov.method || old.staticMethod || old.method || '';
      baseMap.set(id, {...old, ...ov, method: finalMethod});
    }
  }
  const io = overlay.recipe_ingredients || {};
  for(const [id, list] of Object.entries(io)){ ingMap[id] = list.slice(); }
  for(const r of baseMap.values()) {
    if(!r.method && r.staticMethod) r.method = r.staticMethod;
    recipes.push(r);
  }
  for(const [id, ov] of Object.entries(ro)){
    if(/^u-/.test(id) && !recipes.find(x=>x.id===id)){
      recipes.push({id, name: ov.name||'自定义', tags: ov.tags||['自定义'], method: ov.method||''});
      if(!ingMap[id]) ingMap[id] = (io[id] || []);
    }
  }
  recipes.sort((a,b)=> a.name.localeCompare(b.name, 'zh-Hans-CN'));
  return {recipes, recipe_ingredients:ingMap};
}

// 辅助函数
const SEP_RE = /[，,、/;；|]+/;
function explodeCombinedItems(list){
  const out = [];
  for(const it of (list||[])){
    const name = String(it.item||'').trim();
    if(!name) continue;
    const hasQty = typeof it.qty === 'number' && isFinite(it.qty);
    if(SEP_RE.test(name) && !hasQty){
      for(const n of name.split(SEP_RE).map(s=>s.trim()).filter(Boolean)){ out.push({ item:n, qty:null, unit:null }); }
    }else{ out.push(it); }
  }
  return out;
}
function guessShelfDays(name, unit){ const veg=['菜','叶','苔','苗','芹','香菜','葱','椒','瓜','番茄','西红柿','豆角','笋','蘑','菇','花菜','西兰花','菜花','茄子','豆腐','生菜','莴','空心菜','韭','蒜苗','青椒','黄瓜']; if(veg.some(w=>name.includes(w)))return 5; if(unit==='ml')return 30; if(unit==='pcs')return 14; return 7; }

function buildCatalog(pack){
  const units = {}, set = new Set();
  for(const list of Object.values(pack.recipe_ingredients||{})){
    for(const it of explodeCombinedItems(list)){ 
      const n=(it.item||'').trim(); 
      if(!n) continue; 
      units[n]=units[n]||it.unit||'g';
      set.add(n);
    }
  }
  return Array.from(set).sort().map(n=>({name:n, unit:units[n]||'g', shelf:guessShelfDays(n, units[n]||'g')}));
}

function loadInventory(catalog){ const inv=S.load(S.keys.inventory,[]); for(const i of inv){ if(!i.unit){i.unit=(catalog.find(c=>c.name===i.name)?.unit)||'g'} if(!i.shelf){i.shelf=(catalog.find(c=>c.name===i.name)?.shelf)||7} } return inv; }
function saveInventory(inv){ S.save(S.keys.inventory, inv); }
function daysBetween(a,b){ return Math.floor((new Date(b)-new Date(a))/86400000); }
function remainingDays(e){ const age=daysBetween(e.buyDate||todayISO(), todayISO()); return (+e.shelf||7)-age; }

// [修改] 更新 badgeFor 函数，支持冷冻状态显示
function badgeFor(e){ 
  if(e.isFrozen) return `<span class="kchip" style="background:#3498db;color:white;cursor:pointer" title="点击切换为冷藏">❄️ 冷冻</span>`;
  const r=remainingDays(e); 
  let html = '';
  if(r<=1) html = `<span class="kchip bad" style="cursor:pointer" title="点击切换为冷冻">即将过期 ${r}天</span>`; 
  else if(r<=3) html = `<span class="kchip warn" style="cursor:pointer" title="点击切换为冷冻">优先消耗 ${r}天</span>`; 
  else html = `<span class="kchip ok" style="cursor:pointer" title="点击切换为冷冻">新鲜 ${r}天</span>`; 
  return html;
}

function upsertInventory(inv, e){ const i=inv.findIndex(x=>x.name===e.name && (x.kind||'raw')===(e.kind||'raw')); if(i>=0) inv[i]={...inv[i],...e}; else inv.push(e); saveInventory(inv); }
function addInventoryQty(inv, name, qty, unit, kind='raw'){ const e=inv.find(x=>x.name===name && (x.kind||'raw')===kind); if(e){ e.qty=(+e.qty||0)+qty; e.unit=unit||e.unit; e.buyDate=e.buyDate||todayISO(); } else { inv.push({name, qty, unit:unit||'g', buyDate:todayISO(), kind, shelf:guessShelfDays(name, unit||'g')}); } saveInventory(inv); }

// --- AI 逻辑 ---
function getAiConfig() {
  const localSettings = S.load(S.keys.settings, {});
  let apiKey = localSettings.apiKey || CUSTOM_AI.KEY;
  let apiUrl = localSettings.apiUrl || CUSTOM_AI.URL;
  let model = localSettings.model || CUSTOM_AI.MODEL;
  const visionModel = CUSTOM_AI.VISION_MODEL;

  // 自动修复 URL (确保 Groq URL 正确)
  if (apiUrl && apiUrl.includes("api.groq.com") && !apiUrl.includes("/chat/completions")) {
      apiUrl = apiUrl.replace(/\/$/, ''); 
      if (apiUrl.endsWith("/v1")) apiUrl += "/chat/completions";
      else apiUrl = "https://api.groq.com/openai/v1/chat/completions";
  }
  
  if (!apiKey) return null;
  return { apiKey, apiUrl, textModel: model, visionModel };
}

// ★★★ 强力 JSON 提取与清洗 ★★★
function extractJson(text) {
  let cleaned = text.replace(/<think>[\s\S]*?<\/think>/gi, '')
                    .replace(/<think>[\s\S]*/gi, '')
                    .replace(/```json/gi, '')
                    .replace(/```/g, '')
                    .trim();

  const firstOpenBrace = cleaned.indexOf('{');
  const lastCloseBrace = cleaned.lastIndexOf('}');
  
  if (firstOpenBrace !== -1 && lastCloseBrace !== -1 && lastCloseBrace > firstOpenBrace) {
    return cleaned.substring(firstOpenBrace, lastCloseBrace + 1);
  }
  throw new Error("AI 未返回有效的 JSON 数据");
}

function compressImage(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.readAsDataURL(file);
    reader.onload = (e) => {
      const img = new Image();
      img.src = e.target.result;
      img.onload = () => {
        const canvas = document.createElement('canvas');
        const ctx = canvas.getContext('2d');
        let w = img.width, h = img.height;
        const MAX = 1024; 
        if (w > h) { if (w > MAX) { h *= MAX / w; w = MAX; } } 
        else { if (h > MAX) { w *= MAX / h; h = MAX; } }
        canvas.width = w; canvas.height = h;
        ctx.drawImage(img, 0, 0, w, h);
        resolve(canvas.toDataURL('image/jpeg', 0.7));
      };
    };
    reader.onerror = reject;
  });
}

async function callAiService(prompt, imageBase64 = null) {
  const conf = getAiConfig();
  if (!conf) throw new Error("未配置 API Key，转为本地模式");

  let messages = [];
  let activeModel = conf.textModel; 
  
  if (imageBase64) {
    activeModel = conf.visionModel; 
    messages = [{ role: "user", content: [{ type: "text", text: prompt }, { type: "image_url", image_url: { url: imageBase64 } }] }];
  } else {
    messages = [{ role: "user", content: prompt }];
  }
  
  try {
    const res = await fetch(conf.apiUrl, {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${conf.apiKey}` },
      body: JSON.stringify({ model: activeModel, messages: messages, temperature: 0.2 }) 
    });
    
    if(!res.ok) {
        const errData = await res.json().catch(()=>({}));
        throw new Error(`API 错误 (${res.status}): ${errData.error?.message || '未知错误'}`);
    }
    const data = await res.json();
    return extractJson(data.choices?.[0]?.message?.content || ""); 
  } catch(e) { throw e; }
}

async function recognizeReceipt(file) {
  const base64 = await compressImage(file);
  const prompt = `你是一个中文食材管理助手。请分析图片收据。1. 提取【食品/食材】。2. **重要：请自动忽略所有佐料（如葱、姜、蒜、盐、糖、酱油、醋、味精、花椒、辣椒等），只保留核心肉类、蔬菜、蛋奶等。**3. 提取【名称】、【数量】(默认1)、【单位】。4. 尽可能将英文名或别名转换为通用中文名。返回 JSON 数组: [{"name": "五花肉", "qty": 0.5, "unit": "kg"}]`;
  const jsonStr = await callAiService(prompt, base64);
  return JSON.parse(jsonStr);
}

// [修改] 强制要求返回 JSON 格式
async function callAiForMethod(recipeName, ingredients) {
  const ingStr = ingredients.map(i => i.item).join('、');
  const prompt = `你是一位精通川菜和中式家常菜的资深大厨。请为菜品【${recipeName}】编写一份做法。已知用料：${ingStr}。
  
**严格要求**：
1. 拒绝黑暗料理，不合理则修正。
2. 正宗或家常做法，步骤清晰。
3. 请务必返回如下 **JSON 格式**（不要 markdown）：
{ "method": "1. 第一步...\\n2. 第二步..." }`;

  const jsonStr = await callAiService(prompt);
  try {
      // 尝试解析 JSON 并返回 method 字段
      const res = JSON.parse(jsonStr);
      return res.method || jsonStr;
  } catch(e) {
      // 如果解析失败，说明 AI 可能还是返回了纯文本，直接返回原文
      return jsonStr; 
  }
}

async function callAiSearchRecipe(query, invNames) {
  const prompt = `我冰箱里有：【${invNames}】。我想找菜谱：【${query}】。请提供一道符合搜索的菜谱。要求：1. "ingredients" 字段中，**请剔除所有姜、葱、蒜、花椒、辣椒、油、盐、酱、醋等佐料**，只列出肉、菜等核心食材。2. "method" 字段包含详细做法。返回 JSON：{ "name": "标准菜名", "ingredients": "核心食材1,核心食材2", "method": "1. 步骤... 2. 步骤..." }`;
  const jsonStr = await callAiService(prompt);
  return JSON.parse(jsonStr);
}

async function callCloudAI(pack, inv) {
  const invNames = inv.map(x => x.name).join('、');
  const recipeNames = (pack.recipes||[]).map(r=>r.name).join(',');
  
  // v124: 进一步优化 Prompt，严防离谱替代
  const prompt = `你是一位严谨的、拥有30年经验的中式家庭大厨。请根据冰箱库存：【${invNames}】规划今日菜单。

请严格按照以下 JSON 格式返回：
{
  "local": [ 
    {"name": "从菜谱库【${recipeNames}】中挑选3道最匹配库存的菜名", "reason": "基于库存匹配度的推荐理由"} 
  ],
  "creative": { 
    "name": "推荐一道不在菜谱库中，但非常经典、大众熟知的家常菜", 
    "reason": "简短介绍这道菜的口味特点", 
    "ingredients": "核心食材1,核心食材2" 
  }
}

**严格约束（必读）**：
1. **拒绝离谱替代**：绝不允许用葱姜蒜、九层塔、香菜等佐料去替代叶菜、肉类等主材（例如：不能说“用九层塔替代空心菜”）。
2. **拒绝黑暗料理**：禁止奇怪的食材混搭。推荐必须是大众耳熟能详的传统家常菜（如：番茄炒蛋、青椒肉丝）。
3. **实事求是**：如果库存食材不足以做某道大菜，就推荐简单的快手菜，不要强行编造。
4. **Ingredients 字段**：只列出肉、菜、蛋、豆制品等核心主材，**严禁**包含葱姜蒜、盐糖油酱醋等佐料。`;
  
  try {
    const jsonStr = await callAiService(prompt);
    return JSON.parse(jsonStr);
  } catch (e) {
    throw e;
  }
}

// --- 核心推荐逻辑 (已升级：完成度+临期优先) ---
function calculateStockStatus(recipe, pack, inv) {
  const rawIngs = pack.recipe_ingredients[recipe.id] || [];
  let ingredients = explodeCombinedItems(rawIngs);
  ingredients = ingredients.filter(ing => !isSeasoning(ing.item));
  if (ingredients.length === 0) return { status: 'unknown', missing: [] };

  const missing = [];
  let matchCount = 0;
  const invMap = new Map();
  inv.forEach(i => invMap.set(getCanonicalName(i.name), i));

  ingredients.forEach(ing => {
    const needName = getCanonicalName(ing.item);
    if (invMap.has(needName)) { matchCount++; } 
    else { missing.push({ name: ing.item }); }
  });

  if (missing.length === 0) return { status: 'ok', missing: [] };
  if (matchCount > 0) return { status: 'partial', missing };
  return { status: 'none', missing };
}

function getLocalRecommendations(pack, inv, forceRefresh = false) {
  const now = Date.now();
  const lastRecTime = parseInt(S.load(S.keys.rec_time, 0));
  const savedRecs = S.load(S.keys.local_recs, null);

  if (!forceRefresh && savedRecs && (now - lastRecTime < 3600000)) {
    return savedRecs.map(s => {
       const r = (pack.recipes||[]).find(x => x.id === s.id);
       return r ? { r, matchCount: s.matchCount, reason: s.reason } : null;
    }).filter(Boolean);
  }
  
  const invMap = new Map();
  inv.forEach(i => invMap.set(getCanonicalName(i.name), i));

  let scores = (pack.recipes || []).map(r => {
    const rawIngs = explodeCombinedItems(pack.recipe_ingredients[r.id] || []);
    // 过滤掉佐料，只保留核心食材
    const coreIngs = rawIngs.filter(ing => !isSeasoning(ing.item));
    
    // 如果没有核心食材（比如白饭），则不参与智能推荐
    if (coreIngs.length === 0) return { r, score: 0, matchCount: 0, reason: "基础菜品" };

    let matchCount = 0;
    let expiringBonus = 0;
    
    coreIngs.forEach(ing => {
      const canon = getCanonicalName(ing.item);
      // 尝试精确匹配或模糊匹配
      let invItem = invMap.get(canon);
      if (!invItem) {
          for (const [k, v] of invMap) {
              if (k.includes(canon) || canon.includes(k)) {
                  invItem = v;
                  break;
              }
          }
      }

      if (invItem) {
        matchCount++;
        // 临期加分：如果食材剩余保质期 <= 2天，大幅加分
        if (remainingDays(invItem) <= 2) expiringBonus += 1; 
      }
    });

    // 核心算法：完成度占比权重最大 + 临期奖励 + 绝对数量微调
    const completionRatio = matchCount / coreIngs.length;
    const score = (completionRatio * 50) + (expiringBonus * 15) + (matchCount * 10);

    let reason = "";
    if (matchCount > 0) {
        const pct = Math.round(completionRatio * 100);
        reason = `匹配 ${matchCount}/${coreIngs.length} 项食材 (${pct}%)`;
        if (expiringBonus > 0) reason = `⚠️ 优先消耗临期食材 | ${reason}`;
    }

    return { r, score, matchCount, reason };
  });
  
  // 过滤掉完全不匹配的（除非库存实在没得选）
  const hasMatches = scores.some(s => s.matchCount > 0);
  if (hasMatches) {
      scores = scores.filter(s => s.matchCount > 0);
  }
  
  scores.sort((a,b) => b.score - a.score).slice(0, 6);
  let top = scores.slice(0, 6);

  if (top.length === 0) {
    const all = (pack.recipes||[]);
    top = [...all].sort(() => 0.5 - Math.random()).slice(0, 6).map(r => ({ r, matchCount: 0, reason: '随机探索' }));
  }

  const toSave = top.map(s => ({ id: s.r.id, matchCount: s.matchCount, reason: s.reason }));
  S.save(S.keys.local_recs, toSave);
  S.save(S.keys.rec_time, now);
  return top.map(s => ({ r: s.r, matchCount: s.matchCount, reason: s.reason }));
}

function searchResultCard(r, statusData) {
  const card = document.createElement('div'); card.className = 'card';
  let statusBadge = statusData.status === 'ok' ? `<span class="kchip ok">✅ 库存充足</span>` : (statusData.status === 'partial' ? `<span class="kchip warn">⚠️ 缺食材</span>` : `<span class="kchip bad">❌ 暂无食材</span>`);
  
  card.innerHTML = `<div style="display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:8px;"><h3 style="margin:0;flex:1;cursor:pointer;text-decoration:underline" class="r-title">${r.name}</h3>${statusBadge}</div><p class="meta">${(r.tags||[]).join(' / ')}</p><div class="controls"><button type="button" class="btn small" onclick="location.hash='#recipe:${r.id}'">查看做法</button><button type="button" class="btn small" id="addMissingBtn">🛒 加入清单</button></div>`;
  
  const addBtn = card.querySelector('#addMissingBtn');
  if (addBtn) {
    addBtn.onclick = () => {
      const plan = S.load(S.keys.plan, []);
      if (!plan.find(x => x.id === r.id)) { plan.push({ id: r.id, servings: 1 }); S.save(S.keys.plan, plan); alert(`已加入清单。`); } 
      else { alert('已在清单中。'); }
    };
  }
  return card;
}

function showRecommendationCards(container, list, pack) { 
  container.innerHTML = ''; 
  if(!list || list.length===0) { 
    container.innerHTML = '<div class="card small" style="min-width:100%;text-align:center;">暂无推荐。</div>'; 
    return; 
  } 
  const map = pack.recipe_ingredients || {}; 
  list.forEach(item => { 
    const isAi = item.isAi !== undefined ? item.isAi : false;
    container.appendChild(recipeCard(item.r, item.list || map[item.r.id], {reason: item.reason, isAi: isAi})); 
  }); 
} 

function processAiData(aiResult, pack) {
  const cards = [];
  if(aiResult.local && Array.isArray(aiResult.local)){ 
    aiResult.local.forEach(l => { 
       const found = (pack.recipes||[]).find(r => r.name === l.name); 
       if(found) cards.push({ r: found, reason: l.reason, isAi: true }); 
    }); 
  }
  if(aiResult.creative){ 
    cards.push({ 
       r: { id: 'creative-ai-temp', name: aiResult.creative.name, tags: ['AI创意菜'] }, 
       list: [{item: aiResult.creative.ingredients}], 
       reason: aiResult.creative.reason, 
       isAi: true 
    }); 
  }
  return cards;
}

function recipeCard(r, list, extraInfo=null){
  const card=document.createElement('div'); card.className='card';
  let topHtml = (extraInfo && extraInfo.isAi) ? `<div class="ai-badge">✨ AI 推荐</div>` : '';
  
  // 核心修复：使用 button 替代 a 标签
  card.innerHTML=`${topHtml}<div style="display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:8px;"><h3 style="margin:0;flex:1;cursor:pointer;text-decoration:underline" class="r-title">${r.name}</h3>${!r.id.startsWith('creative-') ? `<button type="button" class="kchip bad small btn-edit" data-id="${r.id}" style="cursor:pointer;margin-left:8px;border:none;">编辑</button>` : ''}</div><p class="meta">${(r.tags||[]).join(' / ')}</p><div class="ing-compact-container"></div>${extraInfo && extraInfo.reason ? `<div class="ai-reason" style="margin-top:8px;padding:8px;font-size:12px;">${extraInfo.reason}</div>` : ''}<div class="controls"></div>`;
  
  card.querySelector('.r-title').onclick = () => location.hash = `#recipe:${r.id}`;
  const editBtn = card.querySelector('.btn-edit');
  if(editBtn) editBtn.onclick = (e) => { e.stopPropagation(); location.hash = `#recipe-edit:${r.id}`; };
  
  const tagContainer = card.querySelector('.ing-compact-container');
  let items = explodeCombinedItems(list||[]);
  const coreItems = items.filter(it => !isSeasoning(it.item));
  const displayItems = coreItems.length > 0 ? coreItems : items; 
  const showItems = displayItems.slice(0, 4); 
  for(const it of showItems){ const span = document.createElement('span'); span.className = 'ing-tag-pill'; span.innerHTML = `${it.item}`; tagContainer.appendChild(span); }
  
  if(!r.id.startsWith('creative-')){
    const plan = new Set((S.load(S.keys.plan,[])).map(x=>x.id));
    const btn = document.createElement('button'); btn.type = 'button'; btn.className='btn ok small'; 
    btn.textContent = plan.has(r.id) ? '已加入' : '加入清单';
    btn.onclick = () => { const p=S.load(S.keys.plan,[]); const i=p.findIndex(x=>x.id===r.id); if(i>=0) p.splice(i,1); else p.push({id:r.id, servings:1}); S.save(S.keys.plan,p); onRoute(); };
    
    const detailBtn = document.createElement('button'); detailBtn.type = 'button'; detailBtn.className='btn small'; detailBtn.textContent='查看';
    detailBtn.onclick = () => location.hash = `#recipe:${r.id}`;
    
    card.querySelector('.controls').appendChild(btn);
    card.querySelector('.controls').appendChild(detailBtn);
  }
  return card;
}

function renderRecipeDetail(id, pack) {
  let r = (pack.recipes||[]).find(x=>x.id===id);
  if (!r && id === 'creative-ai-temp') {
      const aiData = S.load(S.keys.ai_recs, null);
      if (aiData && aiData.creative) { 
        r = { id: 'creative-ai-temp', name: aiData.creative.name, tags: ['AI创意菜'], method: '', isCreative: true }; 
      }
  }
  if(!r) {
      const div = document.createElement('div');
      div.innerHTML = `<div style="padding:20px;text-align:center;">菜谱不存在。<br><button class="btn" onclick="history.back()">返回</button></div>`;
      return div;
  }
  
  const overlay = loadOverlay();
  const ovRecipe = (overlay.recipes || {})[id];
  if (ovRecipe) { r = { ...r, ...ovRecipe, method: ovRecipe.method || r.method || '' }; }
  
  let items = [];
  if (r.isCreative) { 
    const aiData = S.load(S.keys.ai_recs, null); 
    items = [{item: aiData.creative.ingredients || '请参考AI描述'}]; 
  } else { 
    const ingList = pack.recipe_ingredients[id] || []; 
    items = explodeCombinedItems(ingList); 
  }
  
  const div = document.createElement('div'); div.className = 'detail-view';
  const methodContent = r.method ? `<div class="method-text">${r.method}</div>` : `<div class="small" style="margin-bottom:10px;padding:10px;border:1px dashed #ccc;border-radius:8px;">暂无详细做法。点击按钮让 AI 生成。</div><button type="button" class="btn ai" id="genMethodBtn">✨ 让 AI 生成做法</button>`;
  
  div.innerHTML = `<div style="margin-bottom:20px;display:flex;justify-content:space-between;"><button type="button" class="btn" onclick="history.back()">← 返回</button><a class="btn" href="#recipe-edit:${r.id}">✎ 编辑 / 录入</a></div><h2 style="color:var(--text-main);font-size:24px;">${r.name}</h2><div class="tags meta" style="margin-bottom:24px;border-bottom:1px solid var(--separator);padding-bottom:10px;">${(r.tags||[]).join(' / ')}</div><div class="block"><h4>用料 Ingredients</h4><div class="ing-compact-container">${items.map(it => `<div class="ing-tag-pill">${it.item} ${it.qty ? `<span class="qty">${it.qty}${it.unit||''}</span>` : ''}</div>`).join('')}</div></div><div class="block"><h4>制作方法 Method</h4><div id="methodArea">${methodContent}</div></div>`;
  
  const genBtn = div.querySelector('#genMethodBtn');
  if(genBtn) {
    genBtn.onclick = async () => {
      // [新增] 增加重试逻辑
      genBtn.setAttribute('disabled', 'true');
      genBtn.innerHTML = '<span class="spinner"></span> 生成中...';
      
      const maxRetries = 1; // 允许自动重试1次
      let attempt = 0;
      let success = false;
      
      // 超时保护
      const safetyTimer = setTimeout(() => {
         if(!success) {
             genBtn.innerHTML = '✨ 生成超时，请重试';
             genBtn.removeAttribute('disabled');
             alert("AI 生成超时，请检查网络后重试。");
         }
      }, 30000); // 30秒超时

      while(attempt <= maxRetries && !success) {
          try {
            attempt++;
            const text = await callAiForMethod(r.name, items);
            clearTimeout(safetyTimer);
            success = true;
            
            const currentOverlay = loadOverlay();
            currentOverlay.recipes = currentOverlay.recipes || {};
            currentOverlay.recipes[id] = { ...(currentOverlay.recipes[id]||{}), method: text };
            saveOverlay(currentOverlay);
            div.querySelector('#methodArea').innerHTML = `<div class="method-text">${text}</div><div class="small ok" style="margin-top:10px">已保存到补丁</div>`;
          } catch(e) {
            console.warn(`Attempt ${attempt} failed:`, e);
            if (attempt > maxRetries) {
                clearTimeout(safetyTimer);
                alert('生成失败：' + e.message); 
                genBtn.innerHTML = '✨ AI 生成';
                genBtn.removeAttribute('disabled');
            } else {
                genBtn.innerHTML = `<span class="spinner"></span> 正在重试 (${attempt}/${maxRetries})...`;
                await new Promise(r => setTimeout(r, 1000)); // 等1秒重试
            }
          }
      }
    };
  }
  return div;
}

function renderRecipeSearchResults(query, pack, inv) {
  const container = document.createElement('div');
  container.innerHTML = `<h2 class="section-title">搜索结果：${query}</h2><div class="grid" id="search-grid"></div>`;
  const grid = container.querySelector('#search-grid');
  const results = (pack.recipes||[]).filter(r => r.name.includes(query));
  if (results.length > 0) {
    results.forEach(r => {
      const status = calculateStockStatus(r, pack, inv);
      grid.appendChild(searchResultCard(r, status));
    });
  } else {
    container.innerHTML += `<div style="text-align:center; padding:40px;"><p style="color:var(--text-secondary)">未找到相关菜谱。</p><button type="button" class="btn ai" id="aiSearchBtn">🤖 呼叫 AI 搜索并生成【${query}】</button></div>`;
    setTimeout(() => {
        const btn = container.querySelector('#aiSearchBtn');
        if(btn) {
            btn.onclick = async () => {
                btn.innerHTML = '<span class="spinner"></span> AI 搜索中...';
                try {
                    const invNames = inv.map(x=>x.name).join(',');
                    const aiRes = await callAiSearchRecipe(query, invNames);
                    const tempId = 'ai-search-' + Date.now();
                    const overlay = loadOverlay();
                    overlay.recipes = overlay.recipes || {};
                    overlay.recipes[tempId] = { name: aiRes.name, tags: ['AI搜索'], method: aiRes.method };
                    overlay.recipe_ingredients = overlay.recipe_ingredients || {};
                    const ings = (aiRes.ingredients||'').split(/[，,]/).map(s => ({item: s.trim()}));
                    overlay.recipe_ingredients[tempId] = ings;
                    saveOverlay(overlay);
                    location.hash = `#recipe:${tempId}`; location.reload();
                } catch(e) { alert('AI 搜索失败：' + e.message); btn.innerHTML = '🤖 呼叫 AI 搜索'; }
            };
        }
    }, 0);
  }
  return container;
}

function renderHome(pack){ 
  const container = document.createElement('div'); 
  const catalog = buildCatalog(pack); 
  const inv = loadInventory(catalog); 
  const searchBar = document.createElement('div');
  searchBar.style.marginBottom = '24px';
  searchBar.innerHTML = `<div style="display:flex; gap:10px;"><input id="mainSearch" placeholder="🔍 搜菜谱 (如：回锅肉)" style="flex:1; padding:12px; border-radius:12px; border:1px solid var(--separator); box-shadow:var(--shadow);"><button type="button" class="btn ok" id="doSearch">搜索</button></div>`;
  container.appendChild(searchBar);
  const doSearch = () => {
      const q = searchBar.querySelector('#mainSearch').value.trim();
      if(q) {
          container.innerHTML = ''; container.appendChild(searchBar);
          searchBar.querySelector('#mainSearch').value = q; searchBar.querySelector('#doSearch').onclick = doSearch;
          container.appendChild(renderRecipeSearchResults(q, pack, inv));
      }
  };
  searchBar.querySelector('#doSearch').onclick = doSearch;
  container.appendChild(renderInventory(pack));
  const recDiv = document.createElement('div'); recDiv.style.marginTop = '32px'; 
  
  // ★★★ 核心修复：将 <a> 换成 <button> ★★★
  recDiv.innerHTML = `<div style="display:flex;justify-content:space-between;align-items:center;margin:0 4px 12px;"><h2 class="section-title" style="margin:0;font-size:18px;">今日推荐</h2><button type="button" class="btn ai small" id="callAiBtn" style="padding:6px 12px;">✨ 呼叫 AI</button></div><div id="rec-content" class="horizontal-scroll"></div>`; 
  
  const recGrid = recDiv.querySelector('#rec-content'); 
  container.appendChild(recDiv); 
  
  const savedAiRecs = S.load(S.keys.ai_recs, null);
  if (savedAiRecs) {
     const savedCards = processAiData(savedAiRecs, pack);
     if (savedCards.length > 0) {
       showRecommendationCards(recGrid, savedCards, pack);
       // 清除按钮也改为 button
       if (!recDiv.querySelector('#clearAiBtn')) {
           const clearBtn = document.createElement('button'); 
           clearBtn.type = 'button';
           clearBtn.className = 'btn bad small'; 
           clearBtn.id = 'clearAiBtn';
           clearBtn.style.marginLeft='10px'; 
           clearBtn.textContent = '清除推荐';
           clearBtn.onclick = () => { localStorage.removeItem(S.keys.ai_recs); onRoute(); };
           recDiv.querySelector('.section-title').appendChild(clearBtn);
       }
     } else { showRecommendationCards(recGrid, getLocalRecommendations(pack, inv), pack); }
  } else { showRecommendationCards(recGrid, getLocalRecommendations(pack, inv), pack); }
  
  const aiBtn = recDiv.querySelector('#callAiBtn'); 
  
  // ★★★ 标准 Click 事件处理 + 自动重试 ★★★
  aiBtn.onclick = async () => {
    if (aiBtn.getAttribute('disabled')) return;
    
    aiBtn.setAttribute('disabled', 'true');
    await new Promise(r => setTimeout(r, 50));
    aiBtn.innerHTML = '<span class="spinner"></span> 思考中...'; aiBtn.style.opacity = '0.7'; 
    
    const maxRetries = 1;
    let attempt = 0;
    let success = false;

    // 超时保护
    const safetyTimer = setTimeout(() => {
       if(!success) {
           aiBtn.innerHTML = '✨ 呼叫 AI'; 
           aiBtn.style.opacity = '1';
           aiBtn.removeAttribute('disabled'); 
           alert("AI 响应超时，已自动切换到本地推荐。");
           showRecommendationCards(recGrid, getLocalRecommendations(pack, inv, true), pack);
       }
    }, 30000); // 30秒

    while(attempt <= maxRetries && !success) {
        try { 
          attempt++;
          const aiResult = await callCloudAI(pack, inv); 
          clearTimeout(safetyTimer);
          success = true;
          
          S.save(S.keys.ai_recs, aiResult);
          const newCards = processAiData(aiResult, pack);
          if(newCards.length > 0) { 
              showRecommendationCards(recGrid, newCards, pack); 
              if (!recDiv.querySelector('#clearAiBtn')) {
                   const clearBtn = document.createElement('button'); 
                   clearBtn.type = 'button';
                   clearBtn.className = 'btn bad small'; 
                   clearBtn.id = 'clearAiBtn';
                   clearBtn.style.marginLeft='10px'; 
                   clearBtn.textContent = '清除推荐';
                   clearBtn.onclick = () => { localStorage.removeItem(S.keys.ai_recs); onRoute(); };
                   recDiv.querySelector('.section-title').appendChild(clearBtn);
              }
          } 
        } catch(e) { 
          console.warn(`AI Recs Attempt ${attempt} failed:`, e);
          if (attempt > maxRetries) {
              clearTimeout(safetyTimer);
              let errorMsg = e.message;
              if (errorMsg.includes("401")) errorMsg = "API Key 无效或过期";
              else if (errorMsg.includes("429")) errorMsg = "请求过多(429)，AI 繁忙";
              else if (errorMsg.includes("404")) errorMsg = "模型不存在(404)";
              
              alert(`AI 调用失败: ${errorMsg}\n\n切换到【本地推荐】。`);
              showRecommendationCards(recGrid, getLocalRecommendations(pack, inv, true), pack);
          } else {
              aiBtn.innerHTML = `<span class="spinner"></span> 正在重试...`;
              await new Promise(r => setTimeout(r, 1000));
          }
        } 
    }
    
    // 恢复按钮
    if (success || attempt > maxRetries) {
        aiBtn.innerHTML = '✨ 呼叫 AI'; 
        aiBtn.style.opacity = '1'; 
        aiBtn.removeAttribute('disabled'); 
        aiBtn.style.display = 'none'; aiBtn.offsetHeight; aiBtn.style.display = '';
    }
  };
  
  return container; 
}

// ★★★ 修复：购物清单 + 常备品检查 (renderShopping) ★★★
function renderShopping(pack){
  const inv=loadInventory(buildCatalog(pack)); const plan=S.load(S.keys.plan,[]); const map=pack.recipe_ingredients||{};
  const need={}; const addNeed=(n,q,u)=>{ const k=n+'|'+(u||'g'); need[k]=(need[k]||0)+(+q||0); };
  for(const p of plan){ for(const it of explodeCombinedItems(map[p.id]||[])){ if(typeof it.qty==='number') addNeed(it.item, it.qty*(p.servings||1), it.unit); }}
  const missing=[]; for(const [k,req] of Object.entries(need)){ const [n,u]=k.split('|'); const stock=(inv.filter(x=>x.name===n&&x.unit===u).reduce((s,x)=>s+(+x.qty||0),0)); const m=Math.max(0, Math.round((req-stock)*100)/100); if(m>0) missing.push({name:n, unit:u, qty:m}); }
  const d=document.createElement('div'); const h=document.createElement('h2'); h.className='section-title'; h.textContent='购物清单'; d.appendChild(h);
  const pd=document.createElement('div'); pd.className='card'; pd.innerHTML='<h3>今日计划</h3>'; const pl=document.createElement('div'); pd.appendChild(pl);
  function drawPlan(){ pl.innerHTML=''; if(plan.length===0){ const p=document.createElement('p'); p.className='small'; p.textContent='暂未添加菜谱。去“菜谱/推荐”点“加入购物计划”。'; pl.appendChild(p); return; }
    for(const p of plan){ const r=(pack.recipes||[]).find(x=>x.id===p.id); if(!r) continue; const row=document.createElement('div'); row.className='controls';
      row.innerHTML=`<span>${r.name}</span><span class="small">份数</span><input type="number" min="1" max="8" step="1" value="${p.servings||1}" style="width:80px"><a class="btn" href="javascript:void(0)">移除</a>`;
      const input=els('input',row)[0]; input.onchange=()=>{ const plans=S.load(S.keys.plan,[]); const it=plans.find(x=>x.id===p.id); if(it){ it.servings=+input.value||1; S.save(S.keys.plan,plans); onRoute(); } };
      els('.btn',row)[0].onclick=()=>{ const plans=S.load(S.keys.plan,[]); const i=plans.findIndex(x=>x.id===p.id); if(i>=0){ plans.splice(i,1); S.save(S.keys.plan,plans); onRoute(); } };
      pl.appendChild(row);
    }} drawPlan(); d.appendChild(pd);
  const tbl=document.createElement('table'); tbl.className='table'; tbl.innerHTML=`<thead><tr><th>食材</th><th>缺少数量</th><th>单位</th><th class="right">操作</th></tr></thead><tbody></tbody>`; const tb=tbl.querySelector('tbody');
  if(missing.length===0){ const tr=document.createElement('tr'); tr.innerHTML='<td colspan="4" class="small">库存已满足，不需要购买。</td>'; tb.appendChild(tr); }
  else { for(const m of missing){ const tr=document.createElement('tr'); tr.innerHTML=`<td>${m.name}</td><td>${m.qty}</td><td>${m.unit}</td><td class="right"><a class="btn" href="javascript:void(0)">标记已购 → 入库</a></td>`; els('.btn',tr)[0].onclick=()=>{ const invv=S.load(S.keys.inventory,[]); addInventoryQty(invv,m.name,m.qty,m.unit,'raw'); tr.remove(); }; tb.appendChild(tr); } }
  d.appendChild(tbl);

  // --- [修改] 分类且美化的常备品面板 ---
  const staplesPanel = document.createElement('div');
  staplesPanel.className = 'card';
  staplesPanel.style.marginTop = '24px';
  // 去除原来的硬边框，改用更有质感的头部设计
  staplesPanel.innerHTML = `
    <h3 style="margin-top:0; color:var(--text-main); display:flex; align-items:center;">
      <span style="margin-right:8px;">🧂</span> 家中常备品检查
    </h3>
    <p class="meta" style="margin-bottom:16px;">点击标记家中缺少的佐料，它们将自动加入“复制清单”。</p>
    <div id="stapleContainer"></div>
  `;
  
  // 重新定义 UI 展示用的精简分类列表 (区别于逻辑用的 SEASONINGS 集合)
  const categories = [
    { name: "生鲜/蛋", items: ["葱", "姜", "蒜", "大葱", "香菜", "小米辣", "鸡蛋"] },
    { name: "基础调味", items: ["盐", "糖", "醋", "生抽", "老抽", "料酒", "米酒", "蚝油", "香油", "味精", "鸡精"] },
    { name: "酱料/腌菜", items: ["豆瓣酱", "甜面酱", "豆豉", "酸菜", "酸豆角", "泡椒"] },
    { name: "香料/干粉", items: ["淀粉", "花椒", "干辣椒", "胡椒粉", "八角", "桂皮", "香叶", "五香粉", "孜然", "茴香"] },
    { name: "食用油", items: ["菜油", "猪油"] }
  ];

  const container = staplesPanel.querySelector('#stapleContainer');

  categories.forEach(cat => {
    const groupDiv = document.createElement('div');
    groupDiv.style.marginBottom = '16px';
    
    const title = document.createElement('div');
    title.textContent = cat.name;
    title.style.fontSize = '12px';
    title.style.fontWeight = '600';
    title.style.color = 'var(--text-secondary)';
    title.style.marginBottom = '8px';
    groupDiv.appendChild(title);

    const pillContainer = document.createElement('div');
    pillContainer.className = 'ing-compact-container';
    
    cat.items.forEach(name => {
      const span = document.createElement('span');
      span.className = 'ing-tag-pill staple-item'; // 增加 staple-item 类方便查找
      span.style.cursor = 'pointer';
      span.style.userSelect = 'none';
      span.style.transition = 'all 0.2s cubic-bezier(0.4, 0, 0.2, 1)';
      span.style.border = '1px solid transparent';
      span.textContent = name;

      span.onclick = () => {
        span.classList.toggle('active');
        if (span.classList.contains('active')) {
          span.style.background = 'var(--warning)';
          span.style.color = '#fff';
          span.style.borderColor = 'var(--warning)';
          span.style.transform = 'translateY(-1px)';
          span.style.boxShadow = '0 2px 5px rgba(255, 149, 0, 0.3)';
        } else {
          span.style.background = '';
          span.style.color = '';
          span.style.borderColor = 'transparent';
          span.style.transform = '';
          span.style.boxShadow = '';
        }
      };
      pillContainer.appendChild(span);
    });
    
    groupDiv.appendChild(pillContainer);
    container.appendChild(groupDiv);
  });
  d.appendChild(staplesPanel);
  // --- [修改结束] ---

  const tools=document.createElement('div'); tools.className='controls'; 
  const copy=document.createElement('a'); copy.className='btn'; copy.textContent='复制清单 (含选中常备品)'; 
  
  copy.onclick=()=>{ 
    const lines=missing.map(m=>`${m.name} ${m.qty}${m.unit}`);
    // 修改选择器，查找所有选中的 .staple-item
    const activeStaples = Array.from(staplesPanel.querySelectorAll('.staple-item.active')).map(el => el.textContent);
    
    if(activeStaples.length > 0) {
      lines.push('--- 常备品 ---');
      lines.push(...activeStaples);
    }
    
    if(lines.length === 0) return alert('清单是空的');
    navigator.clipboard.writeText(lines.join('\n')).then(()=>alert('已复制到剪贴板')); 
  }; 
  tools.appendChild(copy); d.appendChild(tools);
  return d;
}

// [新增] 弹出编辑库存详情的 Modal
function showEditInventoryModal(item, onSave) {
  const overlay = document.createElement('div');
  overlay.style.cssText = "position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.5);z-index:999;display:flex;align-items:center;justify-content:center;backdrop-filter:blur(2px);";
  
  const dialog = document.createElement('div');
  dialog.className = 'card';
  dialog.style.cssText = "width:90%;max-width:320px;background:var(--bg-card);padding:24px;border-radius:16px;box-shadow:0 10px 25px rgba(0,0,0,0.2);animation:fadeIn 0.2s ease-out;";
  
  // 增加简单的出现动画
  const style = document.createElement('style');
  style.innerHTML = `@keyframes fadeIn { from { opacity: 0; transform: scale(0.95); } to { opacity: 1; transform: scale(1); } }`;
  document.head.appendChild(style);

  dialog.innerHTML = `
    <h3 style="margin-top:0;color:var(--text-main);font-size:18px;">📝 编辑库存: ${item.name}</h3>
    <div style="margin-bottom:16px;">
      <label class="small" style="display:block;margin-bottom:4px;color:var(--text-secondary)">购买日期 (补录用)</label>
      <input type="date" id="editDate" value="${item.buyDate || todayISO()}" style="width:100%;padding:10px;border-radius:8px;border:1px solid var(--separator);background:var(--bg-main);color:var(--text-main);font-size:16px;">
    </div>
    <div style="margin-bottom:16px;">
      <label class="small" style="display:block;margin-bottom:4px;color:var(--text-secondary)">保质期 (天)</label>
      <input type="number" id="editShelf" value="${item.shelf || 7}" style="width:100%;padding:10px;border-radius:8px;border:1px solid var(--separator);background:var(--bg-main);color:var(--text-main);font-size:16px;">
    </div>
    <div style="margin-bottom:24px;display:flex;align-items:center;padding:10px;background:var(--bg-main);border-radius:8px;">
      <input type="checkbox" id="editFrozen" ${item.isFrozen ? 'checked' : ''} style="width:20px;height:20px;accent-color:var(--accent);cursor:pointer;">
      <label for="editFrozen" style="margin-left:10px;flex:1;cursor:pointer;font-weight:500;">❄️ 冷冻保存 (延长保质)</label>
    </div>
    <div style="display:flex;gap:12px;justify-content:flex-end;">
      <button class="btn" id="cancelBtn" style="background:transparent;border:1px solid var(--separator);color:var(--text-main);">取消</button>
      <button class="btn ok" id="saveBtn" style="flex:1;">保存修改</button>
    </div>
  `;
  
  overlay.appendChild(dialog);
  document.body.appendChild(overlay);
  
  const close = () => {
    overlay.style.opacity = '0';
    setTimeout(() => document.body.removeChild(overlay), 200);
  };
  
  overlay.querySelector('#cancelBtn').onclick = close;
  overlay.querySelector('#saveBtn').onclick = () => {
    item.buyDate = overlay.querySelector('#editDate').value;
    item.shelf = Number(overlay.querySelector('#editShelf').value) || 7;
    item.isFrozen = overlay.querySelector('#editFrozen').checked;
    onSave();
    close();
  };
  
  overlay.onclick = (e) => { if(e.target === overlay) close(); };
}

// ★★★ 修复：使用 SVG 图标 + 强制隐藏 Input + 冷冻功能 + 防止负数 + [新增]详情编辑 ★★★
function renderInventory(pack){ const catalog=buildCatalog(pack); const inv=loadInventory(catalog); const wrap=document.createElement('div'); 
  const header = document.createElement('div'); header.className = 'section-title'; header.innerHTML = '<span>库存管理</span>'; wrap.appendChild(header);
  const searchDiv = document.createElement('div'); searchDiv.className = 'controls'; searchDiv.style.marginBottom = '8px'; 
  
  // SVG + visually-hidden input (添加 style="display:none!important" 双重保险)
  searchDiv.innerHTML = `
    <div style="display:flex; gap:8px; width:100%; justify-content:flex-end;">
      <label class="btn ai icon-only" style="cursor:pointer;">
        <input type="file" id="camInput" accept="image/*" capture="environment" class="visually-hidden" style="display:none!important">
        <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"></path><circle cx="12" cy="13" r="4"></circle></svg>
      </label>
      <button type="button" class="btn ok icon-only" id="toggleAddBtn">
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"></line><line x1="5" y1="12" x2="19" y2="12"></line></svg>
      </button>
    </div>
    <div id="scanStatus" class="small" style="color:var(--accent); display:none; margin-top:4px;"></div>
  `; 
  wrap.appendChild(searchDiv);
  
  // [修改] 增加冷冻选项 Checkbox
  const formContainer = document.createElement('div'); formContainer.className = 'add-form-container'; 
  formContainer.innerHTML = `
    <div style="display:flex; gap:8px; margin-bottom:8px;">
      <div style="flex:1; min-width:120px;">
        <input id="addName" list="catalogList" placeholder="食材名称" style="width:100%;">
        <datalist id="catalogList">${catalog.map(c=>`<option value="${c.name}">`).join('')}</datalist>
      </div>
      <input id="addQty" type="number" min="0" step="1" placeholder="数量" style="width:70px;">
      <select id="addUnit" style="width:70px;"><option value="g">g</option><option value="ml">ml</option><option value="pcs">pcs</option></select>
    </div>
    <div style="display:flex; gap:8px; align-items:center;">
      <input id="addDate" type="date" value="${todayISO()}" style="width:120px;">
      <label style="display:flex;align-items:center;font-size:14px;cursor:pointer;user-select:none;color:var(--text-main);margin:0 4px;">
        <input type="checkbox" id="addFrozen" style="width:16px;height:16px;margin-right:4px;accent-color:var(--accent);">冷冻
      </label>
      <button id="addBtn" class="btn ok" style="flex:1;">入库</button>
    </div>`; 
  wrap.appendChild(formContainer);
  
  searchDiv.querySelector('#toggleAddBtn').onclick = () => { 
    formContainer.classList.toggle('open'); 
    const btn = searchDiv.querySelector('#toggleAddBtn');
    if (formContainer.classList.contains('open')) {
      btn.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="5" y1="12" x2="19" y2="12"></line></svg>`;
    } else {
      btn.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"></line><line x1="5" y1="12" x2="19" y2="12"></line></svg>`;
    }
  };
  formContainer.querySelector('#addName').addEventListener('input', (e)=>{ const val = e.target.value.trim(); const match = catalog.find(c => c.name === val); if(match && match.unit){ formContainer.querySelector('#addUnit').value = match.unit; } }); 
  
  // [修改] 强制数量非负 + 冷冻逻辑
  formContainer.querySelector('#addBtn').onclick=()=>{ 
    const name=formContainer.querySelector('#addName').value.trim(); 
    if(!name) return alert('请输入食材名称'); 
    
    // 获取数值，如果是负数则强制归0
    let qty = +formContainer.querySelector('#addQty').value || 0; 
    if (qty < 0) qty = 0;

    const unit=formContainer.querySelector('#addUnit').value; 
    const date=formContainer.querySelector('#addDate').value||todayISO(); 
    const isFrozen = formContainer.querySelector('#addFrozen').checked; // 获取冷冻状态

    // 如果冷冻，保质期设为180天，否则自动推算
    const shelfDays = isFrozen ? 180 : guessShelfDays(name, unit);
    
    upsertInventory(inv,{name, qty, unit, buyDate:date, kind:'raw', shelf:shelfDays, isFrozen: isFrozen}); 
    
    formContainer.querySelector('#addName').value = ''; 
    formContainer.querySelector('#addQty').value = ''; 
    formContainer.querySelector('#addFrozen').checked = false; // 重置
    renderTable(); 
  };
  
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
      // [修改] 增加点击名字编辑功能 + 显示购买日期
      tr.innerHTML=`
        <td class="name-cell" style="cursor:pointer;position:relative;">
          <span style="font-weight:600;color:var(--text-main)">${e.name}</span>
          <br><small style="color:var(--text-secondary);font-size:10px;">${e.buyDate||'未知'}</small>
        </td>
        <td><div style="display:flex;align-items:center;gap:4px;"><input class="qty-input" type="number" min="0" step="1" value="${+e.qty||0}" style="width:40px;padding:2px;text-align:center;border:1px solid var(--separator);border-radius:4px;"><small>${e.unit}</small></div></td>
        <td class="status-cell">${badgeFor(e)}</td>
        <td class="right"><button class="btn bad small" style="padding:4px 8px;" type="button">删</button></td>`; 
      
      // 绑定编辑弹窗事件
      tr.querySelector('.name-cell').onclick = () => {
        showEditInventoryModal(e, () => {
          saveInventory(inv);
          renderTable();
        });
      };

      const qtyInput = tr.querySelector('input'); 
      // [修改] 强制列表输入框非负
      qtyInput.onchange = () => { 
        let newQty = +qtyInput.value || 0;
        if(newQty < 0) newQty = 0;
        e.qty = newQty; 
        saveInventory(inv); 
        // 如果用户输入了负数，重置输入框显示为0
        if(+qtyInput.value < 0) qtyInput.value = 0;
      };

      // [新增] 点击状态标签切换冷冻/冷藏
      const statusCell = tr.querySelector('.status-cell');
      if(statusCell) {
        statusCell.onclick = () => {
          e.isFrozen = !e.isFrozen; // 切换状态
          // 重新计算保质期：冷冻=180天，冷藏=按规则计算
          e.shelf = e.isFrozen ? 180 : guessShelfDays(e.name, e.unit);
          saveInventory(inv);
          renderTable(); // 刷新显示
        };
      }
      
      els('.btn',tr)[0].onclick=()=>{ const i=inv.indexOf(e); if(i>=0){ inv.splice(i,1); saveInventory(inv); renderTable(); }}; tb.appendChild(tr); 
    } 
  } 
  renderTable(); return wrap; 
}

function renderRecipes(pack){ 
  const wrap = document.createElement('div'); 
  wrap.innerHTML = `
    <div class="controls" style="margin-bottom:16px;gap:10px;">
      <input id="search" placeholder="搜菜谱..." style="flex:1;padding:12px;border-radius:12px;border:1px solid var(--separator);">
      <a class="btn ok icon-only" id="addBtn" title="新建菜谱">
         <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"></line><line x1="5" y1="12" x2="19" y2="12"></line></svg>
      </a>
      <a class="btn" id="exportBtn">导出</a>
      <label class="btn"><input type="file" id="importFile" hidden>导入</label>
    </div>
    <div class="grid" id="grid"></div>
  `; 
  const grid = wrap.querySelector('#grid'); 
  const map = pack.recipe_ingredients||{}; 
  
  function draw(filter=''){ 
    grid.innerHTML = ''; 
    const f = filter.trim(); 
    (pack.recipes||[]).filter(r => !f || r.name.includes(f)).forEach(r=>{ 
      grid.appendChild(recipeCard(r, map[r.id])); 
    }); 
  } 
  draw(); 
  
  wrap.querySelector('#search').oninput = e => draw(e.target.value); 
  
  // 绑定新建、导出、导入逻辑
  wrap.querySelector('#addBtn').onclick = () => { 
    const id = genId(); 
    const overlay = loadOverlay(); 
    overlay.recipes = overlay.recipes || {}; 
    overlay.recipes[id] = { name: '新菜谱', tags: ['自定义'] }; 
    overlay.recipe_ingredients = overlay.recipe_ingredients || {}; 
    overlay.recipe_ingredients[id] = [{item:'', qty:null, unit:'g'}]; 
    saveOverlay(overlay); 
    location.hash = `#recipe-edit:${id}`; 
  }; 
  
  wrap.querySelector('#exportBtn').onclick = ()=>{ 
    const blob = new Blob([JSON.stringify(loadOverlay(), null, 2)], {type:'application/json'}); 
    const a = document.createElement('a'); 
    a.href = URL.createObjectURL(blob); 
    a.download = 'kitchen-overlay.json'; 
    a.click(); 
  }; 
  
  wrap.querySelector('#importFile').onchange = (e)=>{ 
    const file = e.target.files[0]; 
    if(!file) return; 
    const reader = new FileReader(); 
    reader.onload = ()=>{ 
      try{ 
        const inc = JSON.parse(reader.result); 
        const cur = loadOverlay(); 
        const m = {...cur, recipes:{...cur.recipes,...(inc.recipes||{})}, recipe_ingredients:{...cur.recipe_ingredients,...(inc.recipe_ingredients||{})}, deletes:{...cur.deletes,...(inc.deletes||{})} }; 
        saveOverlay(m); 
        alert('导入成功'); 
        location.reload(); 
      }catch(err){ alert('导入失败'); } 
    }; 
    reader.readAsText(file); 
  }; 
  
  return wrap; 
}

function renderSettings(){
  const s = S.load(S.keys.settings, { apiUrl: '', apiKey: '', model: '' });
  const displayUrl = s.apiUrl || CUSTOM_AI.URL;
  const displayKey = s.apiKey || CUSTOM_AI.KEY;
  const displayModel = s.model || CUSTOM_AI.MODEL;
  
  const div = document.createElement('div');
  div.innerHTML = `
    <h2 class="section-title">AI 设置</h2>
    <div class="card">
      <div class="setting-group">
        <label>快速预设</label>
        <select id="sPreset">
          <option value="">请选择...</option>
          <option value="silicon">SiliconFlow (硅基流动 - 推荐)</option>
          <option value="groq">Groq</option>
          <option value="openai">OpenAI</option>
        </select>
      </div>
      <hr style="border:0;border-top:1px solid var(--separator);margin:16px 0">
      <div class="setting-group"><label>API 地址</label><input id="sUrl" value="${displayUrl}"></div>
      <div class="setting-group"><label>模型名称</label><input id="sModel" value="${displayModel}"></div>
      <div class="setting-group"><label>API Key</label><input id="sKey" type="password" value="${displayKey}"></div>
      <div class="right"><a class="btn ok" id="saveSet">保存</a></div>
    </div>
  `;
  
  const presets = { 
    silicon: { url: 'https://api.siliconflow.cn/v1/chat/completions', model: 'Qwen/Qwen2.5-7B-Instruct' }, 
    groq: { url: 'https://api.groq.com/openai/v1/chat/completions', model: 'llama3-70b-8192' }, 
    openai: { url: 'https://api.openai.com/v1/chat/completions', model: 'gpt-4o' } 
  };
  
  div.querySelector('#sPreset').onchange = (e) => { 
    const val = e.target.value; 
    if(presets[val]) { 
      div.querySelector('#sUrl').value = presets[val].url; 
      div.querySelector('#sModel').value = presets[val].model; 
    } 
  };
  
  div.querySelector('#saveSet').onclick = () => { 
    const newS = { 
      apiUrl: div.querySelector('#sUrl').value.trim(), 
      apiKey: div.querySelector('#sKey').value.trim(), 
      model: div.querySelector('#sModel').value.trim() 
    }; 
    S.save(S.keys.settings, newS); 
    alert('已保存，刷新后生效。'); 
    location.reload();
  };
  return div;
}

function renderRecipeEditor(id, base){
  const overlay = loadOverlay();
  const baseIng = base.recipe_ingredients || {};
  const overIng = overlay.recipe_ingredients || {};
  // merged recipe
  const rBase = (base.recipes||[]).find(x => x.id===id);
  const rOv = (overlay.recipes||{})[id] || {};
  const r = {...(rBase||{id}), ...rOv};
  const items = (overIng[id] ?? baseIng[id] ?? []).map(x => ({...x}));
  const isNew = /^u-/.test(id) && !rBase;

  const wrap = document.createElement('div'); wrap.className = 'card'; wrap.style.padding = '20px';
  wrap.innerHTML = `
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;">
      <h2 style="margin:0">编辑菜谱</h2>
      <a class="btn" onclick="history.back()">返回</a>
    </div>
    <div class="controls" style="flex-direction:column;align-items:stretch;gap:12px;">
      <div><label class="small">菜名</label><input id="rName" value="${r.name||''}" style="width:100%;"></div>
      <div><label class="small">标签 (逗号分隔)</label><input id="rTags" value="${(r.tags||[]).join(',')}" style="width:100%;"></div>
      <div class="small badge">${isNew?'[自定义菜谱]':'[基于系统数据]'}</div>
    </div>
    
    <h3 style="margin-top:20px">用料表</h3>
    <table class="table">
      <thead><tr><th>用料</th><th>数量</th><th>单位</th><th class="right"><a class="btn small" id="addRow">新增</a></th></tr></thead>
      <tbody id="rows"></tbody>
    </table>
    
    <h3 style="margin-top:20px">做法 (Method)</h3>
    <textarea id="rMethod" rows="8" placeholder="请输入烹饪步骤..." style="width:100%;padding:10px;border-radius:8px;border:1px solid var(--separator);">${r.method || ''}</textarea>

    <div class="controls" style="margin-top:30px;border-top:1px solid var(--separator);padding-top:20px;justify-content:space-between;">
       <div>
         <a class="btn bad" id="hideBtn">${(overlay.deletes||{})[id]?'取消隐藏':'删除/隐藏'}</a>
         ${!isNew ? '<a class="btn" id="resetBtn">重置</a>' : ''}
       </div>
       <a class="btn ok" id="saveBtn">保存</a>
    </div>
  `;
  const tbody = wrap.querySelector('#rows');

  function addRow(item='', qty='', unit='g'){
    const tr = document.createElement('tr');
    tr.innerHTML = `
      <td><input placeholder="食材名" value="${item}"></td>
      <td><input type="number" step="1" placeholder="" value="${qty}"></td>
      <td><select><option value="g"${unit==='g'?' selected':''}>g</option><option value="ml"${unit==='ml'?' selected':''}>ml</option><option value="pcs"${unit==='pcs'?' selected':''}>pcs</option></select></td>
      <td class="right"><a class="btn bad small">删</a></td>`;
    els('.btn', tr)[0].onclick = ()=> tr.remove();
    tbody.appendChild(tr);
  }
  items.forEach(it => addRow(it.item || '', (typeof it.qty==='number' && isFinite(it.qty))? it.qty : '', it.unit || 'g'));
  wrap.querySelector('#addRow').onclick = ()=> addRow();

  wrap.querySelector('#saveBtn').onclick = ()=>{
    const name = wrap.querySelector('#rName').value.trim();
    if(!name) return alert('菜名不能为空');
    const tags = wrap.querySelector('#rTags').value.split(/[，,]/).map(s=>s.trim()).filter(Boolean);
    const method = wrap.querySelector('#rMethod').value;
    
    overlay.recipes = overlay.recipes || {};
    overlay.recipes[id] = { name, tags, method };
    
    overlay.recipe_ingredients = overlay.recipe_ingredients || {};
    const arr = [];
    els('tbody#rows tr', wrap).forEach(tr => {
      const [i1,i2] = els('input', tr);
      const sel = els('select', tr)[0];
      const item = i1.value.trim();
      if(!item) return;
      const qty = i2.value === '' ? null : Number(i2.value);
      const unit = sel.value || null;
      arr.push({ item, ...(qty===null?{}:{qty}), ...(unit?{unit}:{}) });
    });
    overlay.recipe_ingredients[id] = arr;
    if(overlay.deletes) delete overlay.deletes[id];
    saveOverlay(overlay);
    alert('已保存');
    history.back();
  };

  wrap.querySelector('#hideBtn').onclick = ()=>{
    if(!confirm('确定隐藏？')) return;
    overlay.deletes = overlay.deletes || {};
    if(overlay.deletes[id]) delete overlay.deletes[id];
    else overlay.deletes[id] = true;
    saveOverlay(overlay);
    history.back();
  };

  const rBtn = wrap.querySelector('#resetBtn');
  if(rBtn) rBtn.onclick = ()=>{
    if(!confirm('确定重置？')) return;
    if(overlay.recipes) delete overlay.recipes[id];
    if(overlay.recipe_ingredients) delete overlay.recipe_ingredients[id];
    if(overlay.deletes) delete overlay.deletes[id];
    saveOverlay(overlay);
    // refresh
    const newView = renderRecipeEditor(id, base);
    app.innerHTML = ''; app.appendChild(newView);
  };

  return wrap;
}

async function onRoute(){ 
  try {
    app.innerHTML=''; 
    const base = await loadBasePack(); 
    const overlay = loadOverlay(); 
    const pack = applyOverlay(base, overlay); 
    let hash = location.hash.replace('#',''); 
    els('nav a').forEach(a=>a.classList.remove('active')); 
    if(hash==='recipes') el('#nav-recipe').classList.add('active'); 
    else if(hash==='shopping') el('#nav-shop').classList.add('active'); 
    else if(hash==='settings') el('#nav-set').classList.add('active'); 
    else if(!hash || hash==='inventory') el('#nav-home').classList.add('active'); 
    
    if(hash.startsWith('recipe-edit:')){ const id = hash.split(':')[1]; app.appendChild(renderRecipeEditor(id, base)); } 
    else if(hash.startsWith('recipe:')){ const id = hash.split(':')[1]; app.appendChild(renderRecipeDetail(id, pack)); } 
    else if(hash==='shopping'){ app.appendChild(renderShopping(pack)); } 
    else if(hash==='recipes'){ app.appendChild(renderRecipes(pack)); } 
    else if(hash==='settings'){ app.appendChild(renderSettings()); } 
    else { app.appendChild(renderHome(pack)); } 
  } catch(e) {
    console.error('Routing Error:', e);
    app.innerHTML = `<div style="padding:20px;text-align:center;color:red;">页面加载出错：${e.message}<br><button class="btn" onclick="location.reload()">重试</button></div>`;
  }
} 
window.addEventListener('hashchange', onRoute); onRoute();
