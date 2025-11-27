// v95 app.js - 修复购物清单白屏 + 终极容错 + UI 修复
const el = (sel, root=document) => root.querySelector(sel);
const els = (sel, root=document) => Array.from(root.querySelectorAll(sel));
const app = el('#app');
const todayISO = () => new Date().toISOString().slice(0,10);

// --- AI 配置 (保持您要求的配置) ---
const CUSTOM_AI = {
  URL: "https://api.groq.com/openai/v1/chat/completions",
  KEY: "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",
  MODEL: "qwen/qwen3-32b", 
  VISION_MODEL: "meta-llama/llama-4-scout-17b-16e-instruct" 
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

// --- 佐料过滤 ---
const SEASONINGS = new Set([
  "姜", "葱", "蒜", "大蒜", "生姜", "老姜", "葱白", "葱花", "姜米", "蒜泥",
  "盐", "糖", "醋", "酱油", "生抽", "老抽", "味精", "鸡精", "料酒", "花椒", "干辣椒", "辣椒面", "胡椒", "胡椒面",
  "油", "猪油", "菜油", "香油", "芝麻油", "豆粉", "淀粉", "水豆粉", "豆瓣", "豆瓣酱", "泡椒", "清汤", "水"
]);
function isSeasoning(name) {
  if (!name) return true;
  const n = String(name).trim();
  if (SEASONINGS.has(n)) return true;
  if (n.length <= 3 && (n.includes("盐") || n.includes("糖") || n.includes("醋") || n.includes("酱") || n.includes("油"))) return true;
  return false;
}

// -------- Storage --------
const S = {
  save(k, v){ localStorage.setItem(k, JSON.stringify(v)); },
  load(k, d){ try{ return JSON.parse(localStorage.getItem(k)) ?? d }catch{ return d } },
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

  if(pack.recipes){
    pack.recipes.forEach(r => {
      if(!r.staticMethod) {
        const method = staticMethods[r.id] || staticMethods[r.name];
        if(method) r.staticMethod = method;
      }
    });
  }
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
      const canon = getCanonicalName(n);
      set.add(canon);
      if(!units[canon]) units[canon] = units[n];
    }
  }
  return Array.from(set).sort().map(n=>({name:n, unit:units[n]||'g', shelf:guessShelfDays(n, units[n]||'g')}));
}

function loadInventory(catalog){ const inv=S.load(S.keys.inventory,[]); for(const i of inv){ if(!i.unit){i.unit=(catalog.find(c=>c.name===i.name)?.unit)||'g'} if(!i.shelf){i.shelf=(catalog.find(c=>c.name===i.name)?.shelf)||7} } return inv; }
function saveInventory(inv){ S.save(S.keys.inventory, inv); }
function daysBetween(a,b){ return Math.floor((new Date(b)-new Date(a))/86400000); }
function remainingDays(e){ const age=daysBetween(e.buyDate||todayISO(), todayISO()); return (+e.shelf||7)-age; }
function badgeFor(e){ const r=remainingDays(e); if(r<=1) return `<span class="kchip bad">即将过期 ${r}天</span>`; if(r<=3) return `<span class="kchip warn">优先消耗 ${r}天</span>`; return `<span class="kchip ok">新鲜 ${r}天</span>`; }
function upsertInventory(inv, e){ const i=inv.findIndex(x=>x.name===e.name && (x.kind||'raw')===(e.kind||'raw')); if(i>=0) inv[i]={...inv[i],...e}; else inv.push(e); saveInventory(inv); }
function addInventoryQty(inv, name, qty, unit, kind='raw'){ const e=inv.find(x=>x.name===name && (x.kind||'raw')===kind); if(e){ e.qty=(+e.qty||0)+qty; e.unit=unit||e.unit; e.buyDate=e.buyDate||todayISO(); } else { inv.push({name, qty, unit:unit||'g', buyDate:todayISO(), kind, shelf:guessShelfDays(name, unit||'g')}); } saveInventory(inv); }

function getAiConfig() {
  const localSettings = S.load(S.keys.settings, {});
  let apiKey = localSettings.apiKey || CUSTOM_AI.KEY;
  let apiUrl = localSettings.apiUrl || CUSTOM_AI.URL;
  const textModel = localSettings.model || CUSTOM_AI.MODEL;
  const visionModel = CUSTOM_AI.VISION_MODEL;

  // 自动修复 URL
  if (apiUrl && apiUrl.includes("api.groq.com") && !apiUrl.includes("/chat/completions")) {
      apiUrl = apiUrl.replace(/\/$/, ''); 
      if (apiUrl.endsWith("/v1")) {
          apiUrl += "/chat/completions";
      } else {
          apiUrl = "https://api.groq.com/openai/v1/chat/completions";
      }
  }
  
  if (!apiKey) return null;
  return { apiKey, apiUrl, textModel, visionModel };
}

// ★★★ 强力 JSON 提取 ★★★
function extractJson(text) {
  let cleaned = text.replace(/<think[\s\S]*?<\/think>/gi, '')
                    .replace(/```json/gi, '')
                    .replace(/```/g, '')
                    .trim();
  const firstOpenBrace = cleaned.indexOf('{');
  const firstOpenBracket = cleaned.indexOf('[');
  let start = -1;
  if (firstOpenBrace !== -1 && firstOpenBracket !== -1) { start = Math.min(firstOpenBrace, firstOpenBracket); } 
  else { start = firstOpenBrace !== -1 ? firstOpenBrace : firstOpenBracket; }
  const lastCloseBrace = cleaned.lastIndexOf('}');
  const lastCloseBracket = cleaned.lastIndexOf(']');
  let end = Math.max(lastCloseBrace, lastCloseBracket);
  if (start !== -1 && end !== -1 && end > start) { return cleaned.substring(start, end + 1); }
  return cleaned; 
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
      img.onerror = reject;
    };
    reader.onerror = reject;
  });
}

async function callAiService(prompt, imageBase64 = null) {
  const conf = getAiConfig();
  if (!conf) throw new Error("未配置 API Key，转为本地模式");

  let messages = [];
  let activeModel = imageBase64 ? conf.visionModel : conf.textModel;
  // 自动适配 Groq
  if (conf.apiUrl.includes("groq.com") && activeModel.toLowerCase().includes("qwen")) {
      console.warn("Groq + Qwen mismatch, using llama3-70b-8192");
      activeModel = "llama3-70b-8192";
  }

  if (imageBase64) {
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
        // ★★★ 终极容错：所有错误均触发降级 ★★★
        if(res.status >= 400) {
            throw new Error("FALLBACK_LOCAL");
        }
        const errData = await res.json().catch(()=>({}));
        throw new Error(`API 错误 (${res.status}): ${errData.error?.message || '未知错误'}`);
    }
    const data = await res.json();
    const rawText = data.choices?.[0]?.message?.content || "";
    return extractJson(rawText); 
  } catch(e) { throw e; }
}

async function recognizeReceipt(file) {
  const base64 = await compressImage(file);
  const prompt = `你是一个中文食材管理助手。请分析图片收据。1. 提取【食品/食材】。2. **重要：请自动忽略所有佐料（如葱、姜、蒜、盐、糖、酱油、醋、味精、花椒、辣椒等），只保留核心肉类、蔬菜、蛋奶等。**3. 提取【名称】、【数量】(默认1)、【单位】。4. 尽可能将英文名或别名转换为通用中文名。返回 JSON 数组: [{"name": "五花肉", "qty": 0.5, "unit": "kg"}]`;
  const jsonStr = await callAiService(prompt, base64);
  return JSON.parse(jsonStr);
}

async function callAiForMethod(recipeName, ingredients) {
  const ingStr = ingredients.map(i => i.item).join('、');
  const prompt = `你是一位精通川菜和中式家常菜的资深大厨。请为菜品【${recipeName}】编写一份做法。已知用料：${ingStr}。要求：1. 拒绝黑暗料理，不合理则修正。2. 正宗或家常做法。3. 格式简洁。`;
  return await callAiService(prompt);
}

async function callAiSearchRecipe(query, invNames) {
  const prompt = `我冰箱里有：【${invNames}】。我想找菜谱：【${query}】。请提供一道符合搜索的菜谱。要求：1. "ingredients" 字段中，**请剔除所有姜、葱、蒜、花椒、辣椒、油、盐、酱、醋等佐料**，只列出肉、菜等核心食材。2. "method" 字段包含详细做法。返回 JSON：{ "name": "标准菜名", "ingredients": "核心食材1,核心食材2", "method": "1. 步骤... 2. 步骤..." }`;
  const jsonStr = await callAiService(prompt);
  return JSON.parse(jsonStr);
}

async function callCloudAI(pack, inv) {
  const invNames = inv.map(x => x.name).join('、');
  const recipeNames = (pack.recipes||[]).map(r=>r.name).join(',');
  const prompt = `你是一名资深家庭主厨。冰箱有：【${invNames}】。菜谱库有：【${recipeNames}】。请规划今日推荐：1. **Local**: 选3道适合库存的菜。2. **Creative**: 推荐1道适合库存的家常菜(不要瞎编)。**重要规则：在 ingredients 字段中，请绝对不要包含葱、姜、蒜、花椒、盐、糖、油、酱油等佐料，只列出核心食材（如肉、青菜、豆腐）。** 返回 JSON：{ "local": [ {"name": "准确菜名", "reason": "简短理由"} ], "creative": { "name": "推荐菜名", "reason": "理由", "ingredients": "核心食材1,核心食材2" } }`;
  try {
    const jsonStr = await callAiService(prompt);
    return JSON.parse(jsonStr);
  } catch (e) {
    throw e;
  }
}

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
    const stockItem = invMap.get(needName);
    if (stockItem) { matchCount++; } 
    else { missing.push({ name: ing.item, canon: needName }); }
  });

  if (missing.length === 0) return { status: 'ok', missing: [] };
  if (matchCount > 0) return { status: 'partial', missing };
  return { status: 'none', missing };
}

function getLocalRecommendations(pack, inv) {
  const now = Date.now();
  const lastRecTime = parseInt(S.load(S.keys.rec_time, 0));
  const savedRecs = S.load(S.keys.local_recs, null);
  if (savedRecs && (now - lastRecTime < 3600000)) {
    return savedRecs.map(s => {
       const r = (pack.recipes||[]).find(x => x.id === s.id);
       return r ? { r, matchCount: s.matchCount, reason: s.reason } : null;
    }).filter(Boolean);
  }
  const invCanons = inv.map(x => getCanonicalName(x.name)).filter(Boolean);
  let scores = [];
  if (invCanons.length > 0) {
    scores = (pack.recipes || []).map(r => {
      let ingredients = explodeCombinedItems(pack.recipe_ingredients[r.id] || []);
      ingredients = ingredients.filter(ing => !isSeasoning(ing.item));

      let matchCount = 0;
      ingredients.forEach(ing => { 
        const itemRaw = String(ing.item||'').trim();
        if(!itemRaw) return;
        const itemCanon = getCanonicalName(itemRaw);
        const hit = invCanons.some(invC => invC === itemCanon || itemCanon.includes(invC) || invC.includes(itemCanon));
        if(hit) matchCount++;
      });
      return { r, matchCount };
    });
    scores = scores.filter(s => s.matchCount > 0).sort((a,b) => b.matchCount - a.matchCount).slice(0, 6);
  }
  
  if (scores.length === 0) {
    const all = (pack.recipes||[]);
    const shuffled = [...all].sort(() => 0.5 - Math.random()).slice(0, 6);
    scores = shuffled.map(r => ({ r, matchCount: 0 }));
  }
  const toSave = scores.map(s => ({ id: s.r.id, matchCount: s.matchCount, reason: s.matchCount > 0 ? `本地匹配：含 ${s.matchCount} 种库存` : '随机探索' }));
  S.save(S.keys.local_recs, toSave);
  S.save(S.keys.rec_time, now);
  return scores.map(s => ({ r: s.r, matchCount: s.matchCount, reason: s.matchCount > 0 ? `本地匹配：含 ${s.matchCount} 种库存` : '随机探索' }));
}

function searchResultCard(r, statusData) {
  const card = document.createElement('div'); card.className = 'card';
  let statusBadge = '', actionArea = '';
  if (statusData.status === 'ok') { statusBadge = `<span class="kchip ok">✅ 库存充足</span>`; } 
  else if (statusData.status === 'partial') {
    const missingStr = statusData.missing.map(m => m.name).join('、');
    statusBadge = `<span class="kchip warn">⚠️ 缺：${missingStr}</span>`;
    actionArea = `<a class="btn small" id="addMissingBtn" style="margin-top:8px;">🛒 缺货加入清单</a>`;
  } else {
    statusBadge = `<span class="kchip bad">❌ 暂无食材</span>`;
    actionArea = `<a class="btn small" id="addMissingBtn" style="margin-top:8px;">🛒 全部加入清单</a>`;
  }
  card.innerHTML = `<div style="display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:8px;"><h3 style="margin:0;flex:1;cursor:pointer;text-decoration:underline" class="r-title">${r.name}</h3>${statusBadge}</div><p class="meta">${(r.tags||[]).join(' / ')}</p><div class="controls"><a class="btn small" onclick="location.hash='#recipe:${r.id}'">查看做法</a>${actionArea}</div>`;
  card.querySelector('.r-title').onclick = () => location.hash = `#recipe:${r.id}`;
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
    const c = aiResult.creative; 
    cards.push({ 
       r: { id: 'creative-ai-temp', name: c.name, tags: ['AI创意菜'] }, 
       list: [{item: c.ingredients}], 
       reason: c.reason, 
       isAi: true 
    }); 
  }
  return cards;
}

function recipeCard(r, list, extraInfo=null){
  const card=document.createElement('div'); card.className='card';
  let topHtml = ''; if(extraInfo && extraInfo.isAi) { topHtml = `<div class="ai-badge">✨ AI 推荐</div>`; }
  card.innerHTML=`${topHtml}<div style="display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:8px;"><h3 style="margin:0;flex:1;cursor:pointer;text-decoration:underline" class="r-title">${r.name}</h3><a class="kchip bad small btn-edit" data-id="${r.id}" style="cursor:pointer;margin-left:8px;">编辑</a></div><p class="meta">${(r.tags||[]).join(' / ')}</p><div class="ing-compact-container"></div>${extraInfo && extraInfo.reason ? `<div class="ai-reason" style="margin-top:8px;padding:8px;font-size:12px;">${extraInfo.reason}</div>` : ''}<div class="controls"></div>`;
  card.querySelector('.r-title').onclick = () => location.hash = `#recipe:${r.id}`;
  if(!r.id.startsWith('creative-')) { card.querySelector('.btn-edit').onclick = (e) => { e.stopPropagation(); location.hash = `#recipe-edit:${r.id}`; }; } else { card.querySelector('.btn-edit').remove(); }
  const tagContainer = card.querySelector('.ing-compact-container');
  let items = explodeCombinedItems(list||[]);
  const coreItems = items.filter(it => !isSeasoning(it.item));
  const displayItems = coreItems.length > 0 ? coreItems : items; 
  const showItems = displayItems.slice(0, 4); 
  for(const it of showItems){ const span = document.createElement('span'); span.className = 'ing-tag-pill'; span.innerHTML = `${it.item}`; tagContainer.appendChild(span); }
  if(displayItems.length > 4) { const more = document.createElement('span'); more.className = 'ing-tag-pill'; more.style.background = 'transparent'; more.textContent = '...'; tagContainer.appendChild(more); }
  if(!r.id.startsWith('creative-')){
    const plan = new Set((S.load(S.keys.plan,[])).map(x=>x.id));
    const btn=document.createElement('a'); btn.href='javascript:void(0)'; btn.className='btn ok small'; btn.textContent=plan.has(r.id)?'已加入':'加入清单';
    btn.onclick=()=>{ const p=S.load(S.keys.plan,[]); const i=p.findIndex(x=>x.id===r.id); if(i>=0) p.splice(i,1); else p.push({id:r.id, servings:1}); S.save(S.keys.plan,p); onRoute(); };
    card.querySelector('.controls').appendChild(btn);
    const detailBtn = document.createElement('a'); detailBtn.className='btn small'; detailBtn.textContent='查看';
    detailBtn.onclick = () => location.hash = `#recipe:${r.id}`;
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
      div.innerHTML = `<div style="padding:20px;text-align:center;">菜谱不存在，请返回。<br><a class="btn ok" onclick="history.back()">返回</a></div>`;
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
  const methodContent = r.method ? `<div class="method-text">${r.method}</div>` : `<div class="small" style="margin-bottom:10px;padding:10px;border:1px dashed #ccc;border-radius:8px;">暂无详细做法。点击按钮让 AI 生成。</div><a class="btn ai" id="genMethodBtn">✨ 让 AI 生成做法</a>`;
  div.innerHTML = `<div style="margin-bottom:20px;display:flex;justify-content:space-between;"><a class="btn" onclick="history.back()">← 返回</a><a class="btn" href="#recipe-edit:${r.id}">✎ 编辑 / 录入</a></div><h2 style="color:var(--text-main);font-size:24px;">${r.name}</h2><div class="tags meta" style="margin-bottom:24px;border-bottom:1px solid var(--separator);padding-bottom:10px;">${(r.tags||[]).join(' / ')}</div><div class="block"><h4>用料 Ingredients</h4><div class="ing-compact-container">${items.map(it => `<div class="ing-tag-pill">${it.item} ${it.qty ? `<span class="qty">${it.qty}${it.unit||''}</span>` : ''}</div>`).join('')}</div></div><div class="block"><h4>制作方法 Method</h4><div id="methodArea">${methodContent}</div></div>`;
  
  const genBtn = div.querySelector('#genMethodBtn');
  if(genBtn) {
    genBtn.onclick = async () => {
      genBtn.innerHTML = '<span class="spinner"></span> 生成中...';
      try {
        const text = await callAiForMethod(r.name, items);
        const currentOverlay = loadOverlay();
        currentOverlay.recipes = currentOverlay.recipes || {};
        currentOverlay.recipes[id] = { ...(currentOverlay.recipes[id]||{}), method: text };
        saveOverlay(currentOverlay);
        div.querySelector('#methodArea').innerHTML = `<div class="method-text">${text}</div><div class="small ok" style="margin-top:10px">已保存到补丁</div>`;
      } catch(e) { alert('生成失败：' + e.message); genBtn.innerHTML = '✨ AI 生成'; }
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
    container.innerHTML += `<div style="text-align:center; padding:40px;"><p style="color:var(--text-secondary)">未找到相关菜谱。</p><a class="btn ai" id="aiSearchBtn">🤖 呼叫 AI 搜索并生成【${query}】</a></div>`;
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
  searchBar.innerHTML = `<div style="display:flex; gap:10px;"><input id="mainSearch" placeholder="🔍 搜菜谱 (如：回锅肉)" style="flex:1; padding:12px; border-radius:12px; border:1px solid var(--separator); box-shadow:var(--shadow);"><button class="btn ok" id="doSearch">搜索</button></div>`;
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
  recDiv.innerHTML = `<div style="display:flex;justify-content:space-between;align-items:center;margin:0 4px 12px;"><h2 class="section-title" style="margin:0;font-size:18px;">今日推荐</h2><a class="btn ai small" id="callAiBtn" style="padding:6px 12px;">✨ 呼叫 AI</a></div><div id="rec-content" class="horizontal-scroll"></div>`; 
  const recGrid = recDiv.querySelector('#rec-content'); 
  container.appendChild(recDiv); 
  
  const savedAiRecs = S.load(S.keys.ai_recs, null);
  if (savedAiRecs) {
     const savedCards = processAiData(savedAiRecs, pack);
     if (savedCards.length > 0) {
       showRecommendationCards(recGrid, savedCards, pack);
       const clearBtn = document.createElement('a'); clearBtn.className = 'btn bad small'; clearBtn.style.marginLeft='10px'; clearBtn.textContent = '清除';
       clearBtn.onclick = () => { localStorage.removeItem(S.keys.ai_recs); onRoute(); };
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
      // ★★★ 终极容错：所有错误都降级到本地推荐 ★★★
      if (e.message === "FALLBACK_LOCAL" || e.message.includes("401") || e.message.includes("429") || e.message.includes("400") || e.message.includes("404")) {
         console.warn("AI 调用失败，已静默切换到本地推荐:", e);
         showRecommendationCards(recGrid, getLocalRecommendations(pack, inv), pack);
      } else {
         alert(e.message); 
      }
    } 
    finally { aiBtn.innerHTML = '✨ 呼叫 AI'; aiBtn.style.opacity = '1'; } 
  }; 
  return container; 
}

// ★★★ 补回：购物清单 (renderShopping) ★★★
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
  const tools=document.createElement('div'); tools.className='controls'; const copy=document.createElement('a'); copy.className='btn'; copy.textContent='复制清单'; copy.onclick=()=>{ const lines=missing.map(m=>`${m.name} ${m.qty}${m.unit}`); navigator.clipboard.writeText(lines.join('\\n')).then(()=>alert('已复制到剪贴板')); }; tools.appendChild(copy); d.appendChild(tools);
  return d;
}

// ★★★ 修复：使用 SVG 图标 + 强制隐藏 Input (使用 class 配合 CSS) ★★★
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
      <a class="btn ok icon-only" id="toggleAddBtn">
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"></line><line x1="5" y1="12" x2="19" y2="12"></line></svg>
      </a>
    </div>
    <div id="scanStatus" class="small" style="color:var(--accent); display:none; margin-top:4px;"></div>
  `; 
  wrap.appendChild(searchDiv);
  
  const formContainer = document.createElement('div'); formContainer.className = 'add-form-container'; 
  formContainer.innerHTML = `<div style="display:flex; gap:8px; margin-bottom:8px;"><div style="flex:1; min-width:120px;"><input id="addName" list="catalogList" placeholder="食材名称" style="width:100%;"><datalist id="catalogList">${catalog.map(c=>`<option value="${c.name}">`).join('')}</datalist></div><input id="addQty" type="number" step="1" placeholder="数量" style="width:70px;"><select id="addUnit" style="width:70px;"><option value="g">g</option><option value="ml">ml</option><option value="pcs">pcs</option></select></div><div style="display:flex; gap:8px;"><input id="addDate" type="date" value="${todayISO()}" style="flex:1;"><button id="addBtn" class="btn ok" style="flex:1;">入库</button></div>`; wrap.appendChild(formContainer);
  searchDiv.querySelector('#toggleAddBtn').onclick = () => { 
    formContainer.classList.toggle('open'); 
    // Toggle icon (Plus vs Minus)
    const btn = searchDiv.querySelector('#toggleAddBtn');
    if (formContainer.classList.contains('open')) {
      btn.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="5" y1="12" x2="19" y2="12"></line></svg>`;
    } else {
      btn.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"></line><line x1="5" y1="12" x2="19" y2="12"></line></svg>`;
    }
  };
  formContainer.querySelector('#addName').addEventListener('input', (e)=>{ const val = e.target.value.trim(); const match = catalog.find(c => c.name === val); if(match && match.unit){ formContainer.querySelector('#addUnit').value = match.unit; } }); 
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
