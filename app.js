// v59 app.js - 修正 AI 推荐逻辑，拒绝黑暗料理 (Prompt 优化)
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

// --- 食材归一化字典 (保持不变) ---
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
  "蒜苗": ["青蒜", "蒜薹", "蒜苔"],
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
  let n = name.trim();
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

async function loadBasePack(){
  const url = new URL('./data/sichuan-recipes.json', location).href + '?v=23';
  let pack = {recipes:[], recipe_ingredients:{}};
  try{ const res = await fetch(url, { cache:'no-store' }); if(res.ok) pack = await res.json(); }
  catch(e){ console.error('Base pack error', e); }
  
  const staticMethods = window.RECIPE_METHODS || {};
  const existingNames = new Set(pack.recipes.map(r => r.name));
  
  Object.keys(staticMethods).forEach(name => {
    if(!existingNames.has(name)){
      const newId = 'static-' + Math.abs(name.split('').reduce((a,b)=>{a=((a<<5)-a)+b.charCodeAt(0);return a&a},0));
      pack.recipes.push({
        id: newId,
        name: name,
        tags: ["家常菜", "新增"]
      });
    }
  });

  if(pack.recipes){
    pack.recipes.forEach(r => {
      const method = staticMethods[r.id] || staticMethods[r.name];
      if(method) r.staticMethod = method;
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
    const name = (it.item||'').trim();
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
  const apiKey = CUSTOM_AI.KEY || localSettings.apiKey;
  const apiUrl = CUSTOM_AI.KEY ? CUSTOM_AI.URL : (localSettings.apiUrl || CUSTOM_AI.URL);
  const textModel = localSettings.model || CUSTOM_AI.MODEL;
  const visionModel = CUSTOM_AI.VISION_MODEL;
  if (!apiKey) throw new Error("未配置 API Key。请在设置页面配置。");
  return { apiKey, apiUrl, textModel, visionModel };
}

function cleanAiResponse(text) {
  let cleaned = text.replace(/<think>[\s\S]*?<\/think>/gi, '').trim();
  cleaned = cleaned.replace(/```json/gi, '').replace(/```/g, '').trim();
  return cleaned;
}
function extractJson(text) {
  const cleaned = cleanAiResponse(text);
  const match = cleaned.match(/\{[\s\S]*\}|\[[\s\S]*\]/);
  if (match) return match[0];
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
  let messages = [];
  let activeModel = imageBase64 ? conf.visionModel : conf.textModel;

  if (imageBase64) {
    messages = [{
      role: "user",
      content: [
        { type: "text", text: prompt },
        { type: "image_url", image_url: { url: imageBase64 } }
      ]
    }];
  } else {
    messages = [{ role: "user", content: prompt }];
  }

  try {
    // 调低 temperature 以减少幻觉
    const res = await fetch(conf.apiUrl, {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${conf.apiKey}` },
      body: JSON.stringify({ model: activeModel, messages: messages, temperature: 0.2 }) 
    });
    if(!res.ok) {
        const err = await res.json();
        throw new Error(`API 错误 (${res.status}): ${err.error?.message || 'Unknown error'}`);
    }
    const data = await res.json();
    const rawText = data.choices?.[0]?.message?.content || "";
    return extractJson(rawText);
  } catch(e) { throw e; }
}

async function recognizeReceipt(file) {
  const base64 = await compressImage(file);
  const prompt = `
  你是一个中文食材管理助手。请分析图片收据。
  1. 提取【食品/食材】（忽略非食品）。
  2. 提取【名称】、【数量】(默认1)、【单位】。
  3. 尽可能将英文名或别名转换为通用中文名（如 Pork Belly->五花肉, Potato->土豆）。
  返回 JSON 数组: [{"name": "五花肉", "qty": 0.5, "unit": "kg"}]
  `;
  const jsonStr = await callAiService(prompt, base64);
  return JSON.parse(jsonStr);
}

// ★★★ 生成做法 Prompt 优化：强调正宗和简洁 ★★★
async function callAiForMethod(recipeName, ingredients) {
  const ingStr = ingredients.map(i => i.item).join('、');
  const prompt = `
  你是一位精通川菜和中式家常菜的资深大厨。
  请为菜品【${recipeName}】编写一份做法。
  已知用料：${ingStr}。

  要求：
  1. **拒绝黑暗料理**：如果这道菜名看起来很不合理（如“西瓜炒肉”），请礼貌指出并提供一个修正后的做法（如推荐“西瓜皮炒肉”或忽略西瓜）。
  2. **正宗做法**：如果它是经典菜（如回锅肉、麻婆豆腐），严格遵循传统工序。
  3. **家常做法**：如果是家常炒菜，注重实用性和口味。
  4. **格式**：直接输出步骤 1. 2. 3.，语言简洁明了。不要输出任何“思考过程”或“好的”之类的废话。
  `;
  return await callAiService(prompt);
}

// ★★★ 首页推荐 Prompt 优化：严禁瞎编，优先本地匹配 ★★★
async function callCloudAI(pack, inv) {
  const invNames = inv.map(x => x.name).join('、');
  const recipeNames = (pack.recipes||[]).map(r=>r.name).join(',');
  
  const prompt = `
  你是一名资深家庭主厨。
  我冰箱里有：【${invNames}】。
  我的菜谱数据库里有：【${recipeNames}】。

  请帮我规划今日推荐：
  1. **Local (本地匹配)**：从我的【菜谱数据库】中，挑选 3 道最适合当前库存的菜。优先选择库存食材匹配度高的。
  2. **Extension (扩展推荐)**：推荐 1 道【菜谱数据库】里没有，但非常适合当前库存的**经典川菜或家常菜**。
     - **严禁胡编乱造**：绝对不要推荐不存在的怪菜（如“猪肉炖香蕉”）。
     - **合理性**：必须是中餐里常见的、符合常理的搭配。
     - **用料**：列出扩展菜需要的主要食材。
  
  请严格只返回 JSON，格式如下，不要包含任何其他文字：
  { 
    "local": [ 
      {"name": "数据库里的准确菜名", "reason": "简短理由"} 
    ], 
    "creative": { 
      "name": "扩展推荐的经典菜名", 
      "reason": "理由", 
      "ingredients": "主要用料" 
    } 
  }`;
  
  const jsonStr = await callAiService(prompt);
  return JSON.parse(jsonStr);
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
      const ingredients = explodeCombinedItems(pack.recipe_ingredients[r.id] || []);
      let matchCount = 0;
      ingredients.forEach(ing => { 
        const itemRaw = (ing.item||'').trim();
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

  const toSave = scores.map(s => ({ 
      id: s.r.id, 
      matchCount: s.matchCount, 
      reason: s.matchCount > 0 ? `本地匹配：含 ${s.matchCount} 种库存` : '随机探索' 
  }));
  S.save(S.keys.local_recs, toSave);
  S.save(S.keys.rec_time, now);

  return scores.map(s => ({
      r: s.r,
      matchCount: s.matchCount, 
      reason: s.matchCount > 0 ? `本地匹配：含 ${s.matchCount} 种库存` : '随机探索'
  }));
}

function recipeCard(r, list, extraInfo=null){
  const card=document.createElement('div'); card.className='card';
  let topHtml = ''; if(extraInfo && extraInfo.isAi) { topHtml = `<div class="ai-badge">✨ AI 推荐</div>`; }
  card.innerHTML=`${topHtml}
    <div style="display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:8px;">
      <h3 style="margin:0;flex:1;cursor:pointer;text-decoration:underline" class="r-title">${r.name}</h3>
      <a class="kchip bad small btn-edit" data-id="${r.id}" style="cursor:pointer;margin-left:8px;">编辑</a>
    </div>
    <p class="meta">${(r.tags||[]).join(' / ')}</p>
    <div class="ings"></div>
    ${extraInfo && extraInfo.reason ? `<div class="ai-reason">${extraInfo.reason}</div>` : ''}
    <div class="controls"></div>`;
  card.querySelector('.r-title').onclick = () => location.hash = `#recipe:${r.id}`;
  if(!r.id.startsWith('creative-')) { card.querySelector('.btn-edit').onclick = (e) => { e.stopPropagation(); location.hash = `#recipe-edit:${r.id}`; }; } else { card.querySelector('.btn-edit').remove(); }
  const ul=document.createElement('ul'); ul.className='ing-list';
  const items = explodeCombinedItems(list||[]);
  const showItems = items.slice(0, 4); // Compact: show fewer items
  for(const it of showItems){ const q=(typeof it.qty==='number'&&isFinite(it.qty))?(it.qty+(it.unit||'')):''; const li=document.createElement('li'); li.textContent=q?`${it.item}  ${q}`:it.item; ul.appendChild(li); }
  if(items.length > 4) { const li=document.createElement('li'); li.textContent='...'; li.style.color='var(--text-secondary)'; ul.appendChild(li); }
  card.querySelector('.ings').appendChild(ul);
  if(!r.id.startsWith('creative-')){
    const plan = new Set((S.load(S.keys.plan,[])).map(x=>x.id));
    const btn=document.createElement('a'); btn.href='javascript:void(0)'; btn.className='btn'; btn.textContent=plan.has(r.id)?'已加入':'加入清单';
    btn.onclick=()=>{ const p=S.load(S.keys.plan,[]); const i=p.findIndex(x=>x.id===r.id); if(i>=0) p.splice(i,1); else p.push({id:r.id, servings:1}); S.save(S.keys.plan,p); onRoute(); };
    card.querySelector('.controls').appendChild(btn);
    const detailBtn = document.createElement('a'); detailBtn.className='btn'; detailBtn.textContent='查看做法';
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
  if(!r) return document.createTextNode('未找到菜谱或缓存已过期');
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
  div.innerHTML = `<div style="margin-bottom:20px;display:flex;justify-content:space-between;"><a class="btn" onclick="history.back()">← 返回</a><a class="btn" href="#recipe-edit:${r.id}">✎ 编辑 / 录入</a></div><h2 style="color:var(--text-main);font-size:24px;">${r.name}</h2><div class="tags meta" style="margin-bottom:24px;border-bottom:1px solid var(--separator);padding-bottom:10px;">${(r.tags||[]).join(' / ')}</div><div class="block"><h4>用料 Ingredients</h4>
  <!-- ★★★ 紧凑标签视图 ★★★ -->
  <div class="ing-compact-container">${items.map(it => `
      <div class="ing-tag-pill">
        ${it.item} ${it.qty ? `<span class="qty">${it.qty}${it.unit||''}</span>` : ''}
      </div>`).join('')}
  </div></div><div class="block"><h4>制作方法 Method</h4><div id="methodArea">${methodContent}</div></div>`;
  const genBtn = div.querySelector('#genMethodBtn');
  if(genBtn) {
    genBtn.onclick = async () => {
      genBtn.innerHTML = '<span class="spinner"></span> 正在生成...';
      try {
        const text = await callAiForMethod(r.name, items);
        const currentOverlay = loadOverlay();
        currentOverlay.recipes = currentOverlay.recipes || {};
        currentOverlay.recipes[id] = { ...(currentOverlay.recipes[id]||{}), method: text };
        saveOverlay(currentOverlay);
        div.querySelector('#methodArea').innerHTML = `<div class="method-text">${text}</div><div class="small ok" style="margin-top:10px">已保存到补丁</div>`;
      } catch(e) { alert('生成失败：' + e.message); genBtn.innerHTML = '✨ 让 AI 生成做法'; }
    };
  }
  return div;
}

function renderHome(pack){ 
  const container = document.createElement('div'); 
  
  // 1. 库存管理 (置顶)
  container.appendChild(renderInventory(pack));

  // 2. 推荐模块 (改为横向滚动)
  const recDiv = document.createElement('div'); 
  recDiv.style.marginTop = '32px'; // 增加间距
  recDiv.innerHTML = `<div style="display:flex;justify-content:space-between;align-items:center;margin:0 4px 12px;"><h2 class="section-title" style="margin:0;font-size:18px;">今日推荐</h2><a class="btn ai small" id="callAiBtn" style="padding:6px 12px;font-size:12px;">✨ 呼叫 AI 厨师</a></div><div id="rec-content" class="horizontal-scroll"></div>`; 
  const recGrid = recDiv.querySelector('#rec-content'); 
  container.appendChild(recDiv); 

  const catalog = buildCatalog(pack); 
  const inv = loadInventory(catalog); 

  function processAiData(aiResult) {
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
           list: [{item: c.ingredients || '请根据描述自由发挥'}],
           reason: c.reason,
           isAi: true
        });
      }
      return cards;
  }

  function showCards(list) { 
    recGrid.innerHTML = ''; 
    if(list.length===0) { 
      recGrid.innerHTML = '<div class="card small" style="min-width:100%;text-align:center;">冰箱空空如也，快去上方添加食材，或点击右上角“呼叫 AI”获取灵感！</div>'; 
      return; 
    } 
    const map = pack.recipe_ingredients || {}; 
    list.forEach(item => { 
      recGrid.appendChild(recipeCard(item.r, item.list || map[item.r.id], item.matchCount!==undefined ? {reason: item.reason} : {reason: item.reason, isAi: item.isAi})); 
    }); 
  } 
  
  const savedAiRecs = S.load(S.keys.ai_recs, null);
  if (savedAiRecs) {
     const savedCards = processAiData(savedAiRecs);
     if (savedCards.length > 0) {
       showCards(savedCards);
       const clearBtn = document.createElement('a');
       clearBtn.className = 'btn bad small';
       clearBtn.style.cssText = 'margin-left:10px;padding:4px 8px;font-size:11px;';
       clearBtn.textContent = '清除';
       clearBtn.onclick = () => { localStorage.removeItem(S.keys.ai_recs); onRoute(); };
       recDiv.querySelector('.section-title').appendChild(clearBtn);
     } else { showCards(getLocalRecommendations(pack, inv)); }
  } else { showCards(getLocalRecommendations(pack, inv)); }

  const aiBtn = recDiv.querySelector('#callAiBtn'); 
  aiBtn.onclick = async () => { 
    aiBtn.innerHTML = '<span class="spinner"></span> 思考中...'; aiBtn.style.opacity = '0.7'; 
    try { 
      const aiResult = await callCloudAI(pack, inv); 
      S.save(S.keys.ai_recs, aiResult);
      const newCards = processAiData(aiResult);
      if(newCards.length > 0) { showCards(newCards); setTimeout(() => onRoute(), 500); } 
      else { alert('AI 虽然响应了，但没有给出有效推荐。'); }
    } catch(e) { alert(e.message); } 
    finally { aiBtn.innerHTML = '✨ 呼叫 AI 厨师'; aiBtn.style.opacity = '1'; } 
  }; 
  
  return container; 
}

function renderSettings(){ const s = S.load(S.keys.settings, { apiUrl: '', apiKey: '', model: '' }); 
  const displayUrl = s.apiUrl || CUSTOM_AI.URL; const displayKey = s.apiKey || CUSTOM_AI.KEY; const displayModel = s.model || CUSTOM_AI.MODEL;
  const div = document.createElement('div'); div.innerHTML = `<h2 class="section-title">AI 设置</h2><div class="card"><div class="setting-group"><label>快速预设</label><select id="sPreset"><option value="">请选择...</option><option value="silicon">SiliconFlow (硅基流动)</option><option value="groq">Groq (Llama/Mixtral)</option><option value="groq-v">Groq (Llama-Vision)</option><option value="deepseek">DeepSeek</option><option value="openai">OpenAI</option></select></div><hr style="border:0;border-top:1px solid rgba(255,255,255,0.1);margin:16px 0"><div class="setting-group"><label>API 地址</label><input id="sUrl" value="${displayUrl}" placeholder="https://..."></div><div class="setting-group"><label>模型名称 (Model)</label><input id="sModel" value="${displayModel}"></div><div class="setting-group"><label>API Key</label><input id="sKey" type="password" value="${displayKey}" placeholder="sk-..."></div><div class="right"><a class="btn ok" id="saveSet">保存</a></div><p class="small" style="margin-top:20px;color:var(--muted)">* 当前配置：<br>文本模型: ${CUSTOM_AI.MODEL}<br>视觉模型: ${CUSTOM_AI.VISION_MODEL} (固定)</p></div>`; 
  const presets = { silicon: { url: 'https://api.siliconflow.cn/v1/chat/completions', model: 'Qwen/Qwen2.5-7B-Instruct' }, groq: { url: 'https://api.groq.com/openai/v1/chat/completions', model: 'llama3-70b-8192' }, "groq-v": { url: 'https://api.groq.com/openai/v1/chat/completions', model: 'llama-3.2-11b-vision-preview' }, deepseek: { url: 'https://api.deepseek.com/v1/chat/completions', model: 'deepseek-chat' }, openai: { url: 'https://api.openai.com/v1/chat/completions', model: 'gpt-4o' } }; 
  div.querySelector('#sPreset').onchange = (e) => { const val = e.target.value; if(presets[val]) { div.querySelector('#sUrl').value = presets[val].url; div.querySelector('#sModel').value = presets[val].model; } }; 
  div.querySelector('#saveSet').onclick = () => { const newS = { apiUrl: div.querySelector('#sUrl').value.trim(), apiKey: div.querySelector('#sKey').value.trim(), model: div.querySelector('#sModel').value.trim() }; S.save(S.keys.settings, newS); alert('设置已保存，下次刷新将优先使用此设置。'); }; return div; }

function renderInventory(pack){ const catalog=buildCatalog(pack); const inv=loadInventory(catalog); const wrap=document.createElement('div'); 
  const header = document.createElement('div'); header.className = 'section-title'; header.innerHTML = '<span>库存管理</span>'; wrap.appendChild(header);
  const searchDiv = document.createElement('div'); searchDiv.className = 'controls'; searchDiv.style.marginBottom = '8px'; 
  searchDiv.innerHTML = `<div style="display:flex; gap:8px; width:100%;"><input id="invSearch" placeholder="🔍 搜索库存..." style="flex:1; background:var(--bg-card); border:1px solid var(--separator);"><label class="btn ai" style="padding:0 12px; display:flex; align-items:center; justify-content:center; height:42px; cursor:pointer;"><input type="file" id="camInput" accept="image/*" capture="environment" hidden>📷</label><a class="btn ok icon-only" id="toggleAddBtn" style="width:42px; height:42px; padding:0; display:flex; align-items:center; justify-content:center; font-size:20px;">＋</a></div><div id="scanStatus" class="small" style="color:var(--accent); display:none; margin-top:4px;"></div>`; wrap.appendChild(searchDiv);
  const formContainer = document.createElement('div'); formContainer.className = 'add-form-container'; formContainer.innerHTML = `<div style="display:flex; gap:8px; margin-bottom:8px;"><div style="flex:1; min-width:120px;"><input id="addName" list="catalogList" placeholder="食材名称" style="width:100%;"><datalist id="catalogList">${catalog.map(c=>`<option value="${c.name}">`).join('')}</datalist></div><input id="addQty" type="number" step="1" placeholder="数量" style="width:80px;"><select id="addUnit" style="width:80px;"><option value="g">g</option><option value="ml">ml</option><option value="pcs">pcs</option></select></div><div style="display:flex; gap:8px;"><input id="addDate" type="date" value="${todayISO()}" style="flex:1;"><button id="addBtn" class="btn ok" style="flex:1;">确认入库</button></div>`; wrap.appendChild(formContainer);
  searchDiv.querySelector('#toggleAddBtn').onclick = () => { formContainer.classList.toggle('open'); searchDiv.querySelector('#toggleAddBtn').textContent = formContainer.classList.contains('open') ? '－' : '＋'; };
  formContainer.querySelector('#addName').addEventListener('input', (e)=>{ const val = e.target.value.trim(); const match = catalog.find(c => c.name === val); if(match && match.unit){ formContainer.querySelector('#addUnit').value = match.unit; } }); formContainer.querySelector('#addBtn').onclick=()=>{ const name=formContainer.querySelector('#addName').value.trim(); if(!name) return alert('请输入食材名称'); const qty=+formContainer.querySelector('#addQty').value||0; const unit=formContainer.querySelector('#addUnit').value; const date=formContainer.querySelector('#addDate').value||todayISO(); upsertInventory(inv,{name, qty, unit, buyDate:date, kind:'raw', shelf:guessShelfDays(name, unit)}); formContainer.querySelector('#addName').value = ''; formContainer.querySelector('#addQty').value = ''; renderTable(); };
  const tbl=document.createElement('table'); tbl.className='table'; tbl.innerHTML=`<thead><tr><th style="width:35%">食材</th><th style="width:20%">数量</th><th style="width:25%">保质</th><th class="right">操作</th></tr></thead><tbody></tbody>`; wrap.appendChild(tbl);
  const scanStatus = searchDiv.querySelector('#scanStatus');
  searchDiv.querySelector('#camInput').onchange = async (e) => {
    const file = e.target.files[0]; if(!file) return;
    scanStatus.style.display = 'block'; scanStatus.innerHTML = '<span class="spinner"></span> 正在识别...';
    try {
      const items = await recognizeReceipt(file);
      scanStatus.innerHTML = `✅ 识别成功！入库 ${items.length} 项...`;
      let count = 0; for(const it of items) { if(!it.name) continue; let unit = it.unit || 'g'; 
        const name = getCanonicalName(it.name);
        const match = catalog.find(c => c.name === name); 
        if(match && match.unit) unit = match.unit; 
        upsertInventory(inv, { name: name, qty: Number(it.qty) || 1, unit: unit, buyDate: todayISO(), kind: 'raw', shelf: guessShelfDays(name, unit) }); count++; }
      setTimeout(() => { scanStatus.style.display = 'none'; alert(`成功入库 ${count} 项！`); renderTable(); }, 1000);
    } catch(err) { scanStatus.innerHTML = `<span style="color:var(--danger)">❌ ${err.message}</span>`; }
  };
  function renderTable(){ 
    const tb=tbl.querySelector('tbody'); tb.innerHTML=''; 
    const filterText = (searchDiv.querySelector('#invSearch').value || '').trim().toLowerCase(); 
    const filteredInv = inv.filter(e => e.name.toLowerCase().includes(filterText)); 
    filteredInv.sort((a,b)=>remainingDays(a)-remainingDays(b)); 
    if(filteredInv.length === 0) { tb.innerHTML = `<tr><td colspan="4" class="small" style="text-align:center;padding:20px;">${inv.length===0 ? '库存空空如也，快去进货！' : '未找到相关食材'}</td></tr>`; return; } 
    for(const e of filteredInv){ 
      const tr=document.createElement('tr'); 
      tr.innerHTML=`<td><span style="font-weight:600;color:var(--text-main)">${e.name}</span></td><td><div style="display:flex;align-items:center;gap:4px;"><input class="qty-input" type="number" step="1" value="${+e.qty||0}" style="width:50px;padding:4px;text-align:center;"><small>${e.unit}</small></div></td><td>${badgeFor(e)}</td><td class="right"><a class="btn bad small" style="padding:4px 8px;font-size:12px;">删除</a></td>`; 
      const qtyInput = tr.querySelector('input'); qtyInput.onchange = () => { e.qty = +qtyInput.value||0; saveInventory(inv); };
      els('.btn',tr)[0].onclick=()=>{ const i=inv.indexOf(e); if(i>=0){ inv.splice(i,1); saveInventory(inv); renderTable(); }}; tb.appendChild(tr); 
    } 
  } 
  searchDiv.querySelector('#invSearch').oninput = () => renderTable(); renderTable(); return wrap; 
}

function renderRecipes(pack){ const wrap = document.createElement('div'); wrap.innerHTML = `<div class="controls" style="margin-bottom:16px;gap:10px;"><input id="search" placeholder="搜菜谱..." style="flex:1;padding:10px;"><a class="btn ok" id="addBtn" style="padding:10px;">+ 新建</a><a class="btn" id="exportBtn">导出</a><label class="btn"><input type="file" id="importFile" hidden>导入</label></div><div class="grid" id="grid"></div>`; const grid = wrap.querySelector('#grid'); const map = pack.recipe_ingredients||{}; function draw(filter=''){ grid.innerHTML = ''; const f = filter.trim(); (pack.recipes||[]).filter(r => !f || r.name.includes(f)).forEach(r=>{ grid.appendChild(recipeCard(r, map[r.id])); }); } draw(); wrap.querySelector('#search').oninput = e => draw(e.target.value); wrap.querySelector('#addBtn').onclick = () => { const id = genId(); const overlay = loadOverlay(); overlay.recipes = overlay.recipes || {}; overlay.recipes[id] = { name: '新菜谱', tags: ['自定义'] }; overlay.recipe_ingredients = overlay.recipe_ingredients || {}; overlay.recipe_ingredients[id] = [{item:'', qty:null, unit:'g'}]; saveOverlay(overlay); location.hash = `#recipe-edit:${id}`; }; wrap.querySelector('#exportBtn').onclick = ()=>{ const blob = new Blob([JSON.stringify(loadOverlay(), null, 2)], {type:'application/json'}); const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'kitchen-overlay.json'; a.click(); }; wrap.querySelector('#importFile').onchange = (e)=>{ const file = e.target.files[0]; if(!file) return; const reader = new FileReader(); reader.onload = ()=>{ try{ const inc = JSON.parse(reader.result); const cur = loadOverlay(); const m = {...cur, recipes:{...cur.recipes,...(inc.recipes||{})}, recipe_ingredients:{...cur.recipe_ingredients,...(inc.recipe_ingredients||{})}, deletes:{...cur.deletes,...(inc.deletes||{})} }; saveOverlay(m); alert('导入成功'); location.reload(); }catch(err){ alert('导入失败'); } }; reader.readAsText(file); }; return wrap; }

async function onRoute(){ app.innerHTML=''; const base = await loadBasePack(); const overlay = loadOverlay(); const pack = applyOverlay(base, overlay); let hash = location.hash.replace('#',''); els('nav a').forEach(a=>a.classList.remove('active')); if(hash==='recipes') el('#nav-recipe').classList.add('active'); else if(hash==='shopping') el('#nav-shop').classList.add('active'); else if(hash==='settings') el('#nav-set').classList.add('active'); else if(!hash || hash==='inventory') el('#nav-home').classList.add('active'); if(hash.startsWith('recipe-edit:')){ const id = hash.split(':')[1]; app.appendChild(renderRecipeEditor(id, base)); } else if(hash.startsWith('recipe:')){ const id = hash.split(':')[1]; app.appendChild(renderRecipeDetail(id, pack)); } else if(hash==='shopping'){ app.appendChild(renderShopping(pack)); } else if(hash==='recipes'){ app.appendChild(renderRecipes(pack)); } else if(hash==='settings'){ app.appendChild(renderSettings()); } else { app.appendChild(renderHome(pack)); } } window.addEventListener('hashchange', onRoute); onRoute();
