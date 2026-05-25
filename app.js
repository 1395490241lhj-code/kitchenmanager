// v146 app.js - 更新API Key(gsk_WgC...) + 标题居中修正
import { CUSTOM_AI } from './src/config.js?v=89';
import { el, els } from './src/dom.js?v=89';
import { S, todayISO } from './src/storage.js?v=89';

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

const app = el('#app');

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
  "蒜苗": ["青蒜"], 
  "蒜苔": ["蒜薹"],
  "韭菜": ["韭黄", "韭菜头", "白头韭菜"],
  "土豆": ["马铃薯", "洋芋", "土豆片", "土豆丝"],
  "红苕": ["红薯", "地瓜", "甘薯", "红心红苕"],
  "莴笋": ["青笋", "莴苣", "莴笋头", "莴笋尖", "凤尾"],
  "番茄": ["西红柿", "洋柿子"],
  "豆腐": ["老豆腐", "嫩豆腐", "北豆腐", "南豆腐", "盒装豆腐"],
  "青椒": ["菜椒", "甜椒", "尖椒", "螺丝椒", "灯笼椒"],
  "洋葱": ["圆葱", "葱头"],
  "胡萝卜": ["红萝卜"],
  "香菜": ["芫荽"],
  "鸡蛋": ["蛋", "鸡子"],
  "牛奶": ["奶", "鲜奶"],
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
function escapeOptionAttr(value) {
  return String(value || '').replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
function escapeHtml(value) {
  return String(value || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function buildIngredientOptions(catalog) {
  const seen = new Set();
  const byValue = new Map();
  const options = [];
  const add = (value, label = '') => {
    const v = String(value || '').trim();
    if(!v) return;
    if(seen.has(v)){
      const existing = byValue.get(v);
      if(existing && label && !existing.label) existing.label = label;
      return;
    }
    seen.add(v);
    const option = { value: v, label };
    options.push(option);
    byValue.set(v, option);
  };
  (catalog || []).forEach(c => add(c.name));
  for (const [canonical, aliases] of Object.entries(INGREDIENT_ALIASES)) {
    add(canonical);
    (aliases || []).forEach(alias => add(alias, canonical));
  }
  return options.sort((a, b) => a.value.localeCompare(b.value, 'zh-Hans-CN'));
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
function loadShoppingItems() {
  return S.load(S.keys.shopping_items, []).filter(item => item && item.name).map(item => ({
    id: item.id || genId(),
    name: String(item.name || '').trim(),
    qty: item.qty || '',
    unit: item.unit || '',
    source: item.source || '手动',
    done: !!item.done
  }));
}
function saveShoppingItems(items) {
  S.save(S.keys.shopping_items, items.filter(item => item && item.name));
}
function addShoppingItem(name, qty = '', unit = '', source = '手动') {
  const cleanName = getCanonicalName(name || '');
  if(!cleanName) return;
  const items = loadShoppingItems();
  const existing = items.find(item => item.name === cleanName && item.unit === unit && item.source === source && !item.done);
  if(existing) existing.qty = existing.qty || qty || 1;
  else items.push({ id: genId(), name: cleanName, qty: qty || '', unit: unit || '', source, done: false });
  saveShoppingItems(items);
}
function downloadJsonFile(payload, filename) {
  const blob = new Blob([JSON.stringify(payload, null, 2)], {type: 'application/json'});
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 0);
}
function buildKitchenBackup() {
  return {
    type: 'kitchen-backup',
    version: 1,
    exportedAt: new Date().toISOString(),
    data: {
      inventory: S.load(S.keys.inventory, []),
      plan: S.load(S.keys.plan, []),
      overlay: loadOverlay(),
      settings: S.load(S.keys.settings, {}),
      favorite_recipes: S.load(S.keys.favorite_recipes, []),
      shopping_items: loadShoppingItems()
    }
  };
}
function restoreKitchenBackup(payload) {
  if(payload && payload.type === 'kitchen-inventory' && Array.isArray(payload.inventory)) {
    S.save(S.keys.inventory, payload.inventory);
    return;
  }
  if(!payload || payload.type !== 'kitchen-backup' || !payload.data) throw new Error('不是有效的厨房备份文件');
  const data = payload.data;
  if(Array.isArray(data.inventory)) S.save(S.keys.inventory, data.inventory);
  if(Array.isArray(data.plan)) S.save(S.keys.plan, data.plan);
  if(data.overlay) saveOverlay(data.overlay);
  if(data.settings) S.save(S.keys.settings, data.settings);
  if(Array.isArray(data.favorite_recipes)) S.save(S.keys.favorite_recipes, data.favorite_recipes);
  if(Array.isArray(data.shopping_items)) saveShoppingItems(data.shopping_items);
}

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
function guessKitchenUnit(name) {
  const n = getCanonicalName(name || '');
  const includesAny = words => words.some(w => n.includes(w));
  if (includesAny(['鸡蛋', '鸭蛋', '番茄', '西红柿', '土豆', '洋葱', '青椒', '茄子', '苹果', '梨'])) return '个';
  if (includesAny(['豆腐', '酸奶', '盒装', '奶油', '蘑菇', '菌菇'])) return '盒';
  if (includesAny(['米', '大米', '面粉', '挂面', '面条', '粉丝', '速冻', '饺子', '馄饨'])) return '袋';
  if (includesAny(['酱油', '生抽', '老抽', '醋', '料酒', '油', '牛奶', '饮料'])) return '瓶';
  if (includesAny(['葱', '香菜', '芹菜', '韭菜', '蒜苗', '菠菜', '青菜'])) return '把';
  if (includesAny(['猪肉', '牛肉', '羊肉', '鸡肉', '鸭肉', '排骨', '鱼', '虾', '肉'])) return '份';
  return '份';
}

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

const INVENTORY_STATES = [
  { value: 'ok', label: '够用', className: 'ok' },
  { value: 'low', label: '快没了', className: 'low' },
  { value: 'unknown', label: '不确定', className: 'unknown' }
];
function inventoryStateInfo(value) {
  return INVENTORY_STATES.find(s => s.value === value) || INVENTORY_STATES[0];
}
function nextInventoryState(value) {
  const index = INVENTORY_STATES.findIndex(s => s.value === value);
  return INVENTORY_STATES[(index + 1) % INVENTORY_STATES.length].value;
}
function loadInventory(catalog){
  const inv=S.load(S.keys.inventory,[]);
  for(const i of inv){
    if(!i.unit){i.unit=(catalog.find(c=>c.name===i.name)?.unit)||'g'}
    if(!i.shelf){i.shelf=(catalog.find(c=>c.name===i.name)?.shelf)||7}
    if(!i.stockStatus){i.stockStatus='ok'}
  }
  return inv;
}
function saveInventory(inv){ S.save(S.keys.inventory, inv); }
function daysBetween(a,b){ return Math.floor((new Date(b)-new Date(a))/86400000); }
function remainingDays(e){ const age=daysBetween(e.buyDate||todayISO(), todayISO()); return (+e.shelf||7)-age; }

// 更新 badgeFor 函数，支持冷冻状态显示
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
function addInventoryQty(inv, name, qty, unit, kind='raw'){ const e=inv.find(x=>x.name===name && (x.kind||'raw')===kind); if(e){ e.qty=(+e.qty||0)+qty; e.unit=unit||e.unit; e.buyDate=e.buyDate||todayISO(); e.stockStatus='ok'; } else { inv.push({name, qty, unit:unit||'g', buyDate:todayISO(), kind, shelf:guessShelfDays(name, unit||'g'), stockStatus:'ok'}); } saveInventory(inv); }

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
  
  // v131: 优化 Prompt - 强制 creative.ingredients 为数组
  const prompt = `你是一位严谨的、拥有30年经验的中式家庭大厨。请根据冰箱库存：【${invNames}】规划今日菜单。

请严格按照以下 JSON 格式返回：
{
  "local": [ 
    {"name": "从菜谱库【${recipeNames}】中挑选3道最匹配库存的菜名", "reason": "基于库存匹配度的推荐理由"} 
  ],
  "creative": { 
    "name": "推荐一道不在菜谱库中，但非常经典、大众熟知的家常菜", 
    "reason": "简短介绍这道菜的口味特点", 
    "ingredients": ["核心食材1", "核心食材2"] 
  }
}

**严格约束（必读）**：
1. **拒绝离谱替代**：绝不允许用葱姜蒜、九层塔、香菜等佐料去替代叶菜、肉类等主材。
2. **拒绝黑暗料理**：禁止奇怪的食材混搭。推荐必须是大众耳熟能详的传统家常菜（如：番茄炒蛋、青椒肉丝）。
3. **ingredients 必须是数组**：只列出肉、菜、蛋、豆制品等核心主材，**严禁**包含葱姜蒜、盐糖油酱醋等佐料。`;
  
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

function hasRecipeMethod(recipe) {
  return !!String(recipe && recipe.method || '').trim();
}

function recipeMethodBadge(recipe) {
  return hasRecipeMethod(recipe)
    ? '<span class="kchip method-ok">有做法</span>'
    : '<span class="kchip method-missing">缺做法</span>';
}

function getLocalRecommendations(pack, inv, forceRefresh = false) {
  const now = Date.now();
  const lastRecTime = parseInt(S.load(S.keys.rec_time, 0));
  const savedRecs = S.load(S.keys.local_recs, null);

  if (!forceRefresh && savedRecs && (now - lastRecTime < 3600000)) {
    return savedRecs.map(s => {
       const r = (pack.recipes||[]).find(x => x.id === s.id);
       return r ? { r, matchCount: s.matchCount, reason: s.reason } : null;
    }).filter(item => item && hasRecipeMethod(item.r));
  }
  
  const invMap = new Map();
  inv.forEach(i => invMap.set(getCanonicalName(i.name), i));

  const methodReadyRecipes = (pack.recipes || []).filter(hasRecipeMethod);
  const recommendationRecipes = methodReadyRecipes.length ? methodReadyRecipes : (pack.recipes || []);

  let scores = recommendationRecipes.map(r => {
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
    const all = methodReadyRecipes.length ? methodReadyRecipes : (pack.recipes||[]);
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
  
  card.innerHTML = `<div style="display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:8px;"><h3 style="margin:0;flex:1;cursor:pointer;text-decoration:underline" class="r-title">${r.name}</h3><div class="recipe-badge-stack">${recipeMethodBadge(r)}${statusBadge}</div></div><p class="meta">${(r.tags||[]).join(' / ')}</p><div class="controls"><button type="button" class="btn small" onclick="location.hash='#recipe:${r.id}'">${hasRecipeMethod(r) ? '查看做法' : '补做法'}</button><button type="button" class="btn small" id="addMissingBtn">🛒 加入清单</button></div>`;
  
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
function loadFavoriteRecipeIds() {
  return S.load(S.keys.favorite_recipes, []);
}
function saveFavoriteRecipeIds(ids) {
  S.save(S.keys.favorite_recipes, Array.from(new Set(ids)));
}
function isFavoriteRecipe(id) {
  return loadFavoriteRecipeIds().includes(id);
}
function toggleFavoriteRecipe(id) {
  const ids = loadFavoriteRecipeIds();
  const index = ids.indexOf(id);
  if(index >= 0) ids.splice(index, 1);
  else ids.push(id);
  saveFavoriteRecipeIds(ids);
}
function getFavoriteRecipeCards(pack) {
  const ids = loadFavoriteRecipeIds();
  return ids.map(id => {
    const r = (pack.recipes || []).find(x => x.id === id);
    return r ? { r, list: (pack.recipe_ingredients || {})[id], reason: '常做菜' } : null;
  }).filter(Boolean);
}

function processAiData(aiResult, pack) {
  const cards = [];
  
  // 处理 Local 推荐 (v131: 增加模糊匹配逻辑)
  if(aiResult.local && Array.isArray(aiResult.local)){ 
    aiResult.local.forEach(l => { 
       let found = (pack.recipes||[]).find(r => r.name === l.name); 
       // 尝试模糊匹配 (如果 AI 返回 "回锅肉" 但只有 "四川回锅肉")
       if (!found) {
           found = (pack.recipes||[]).find(r => r.name.includes(l.name) || l.name.includes(r.name));
       }
       if(found) cards.push({ r: found, reason: l.reason, isAi: true }); 
    }); 
  }
  
  // 处理 Creative 推荐 (v131: 兼容数组或字符串)
  if(aiResult.creative){ 
    let ingList = [];
    if(Array.isArray(aiResult.creative.ingredients)) {
        ingList = aiResult.creative.ingredients.map(s => ({item: s}));
    } else if (typeof aiResult.creative.ingredients === 'string') {
        ingList = [{item: aiResult.creative.ingredients}];
    }

    cards.push({ 
       r: { id: 'creative-ai-temp', name: aiResult.creative.name, tags: ['AI创意菜'] }, 
       list: ingList, 
       reason: aiResult.creative.reason, 
       isAi: true 
    }); 
  }
  return cards;
}

function recipeCard(r, list, extraInfo=null){
  const card=document.createElement('div'); card.className='card';
  // [修改] 移除内联样式，使用 CSS 类
  let topHtml = (extraInfo && extraInfo.isAi) ? `<div class="ai-badge">✨ AI 推荐</div>` : '';
  
  // [修改] 移除 h3 和 div 的内联 style，完全依赖 CSS
  card.innerHTML=`${topHtml}
    <div style="display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:8px;">
      <h3 class="r-title">${r.name}</h3>
      <div class="recipe-badge-stack">
        ${recipeMethodBadge(r)}
        ${!String(r.id).startsWith('creative-') ? `<button type="button" class="kchip bad small btn-edit" data-id="${r.id}" style="cursor:pointer;border:none;">编辑</button>` : ''}
      </div>
    </div>
    <p class="meta">${(r.tags||[]).join(' / ')}</p>
    <div class="ing-compact-container"></div>
    ${extraInfo && extraInfo.reason ? `<div class="ai-reason">${extraInfo.reason}</div>` : ''}
    <div class="controls" style="margin-top:16px;"></div>`;
  
  card.querySelector('.r-title').onclick = () => location.hash = `#recipe:${r.id}`;
  const editBtn = card.querySelector('.btn-edit');
  if(editBtn) editBtn.onclick = (e) => { e.stopPropagation(); location.hash = `#recipe-edit:${r.id}`; };
  
  const tagContainer = card.querySelector('.ing-compact-container');
  let items = explodeCombinedItems(list||[]);
  const coreItems = items.filter(it => !isSeasoning(it.item));
  const displayItems = coreItems.length > 0 ? coreItems : items; 
  const showItems = displayItems.slice(0, 4); 
  for(const it of showItems){ const span = document.createElement('span'); span.className = 'ing-tag-pill'; span.innerHTML = `${it.item}`; tagContainer.appendChild(span); }
  
  if(!String(r.id).startsWith('creative-')){
    const plan = new Set((S.load(S.keys.plan,[])).map(x=>x.id));
    const favoriteBtn = document.createElement('button'); favoriteBtn.type = 'button'; favoriteBtn.className = `btn small favorite-btn${isFavoriteRecipe(r.id) ? ' active' : ''}`;
    favoriteBtn.textContent = isFavoriteRecipe(r.id) ? '常做' : '设为常做';
    favoriteBtn.onclick = () => { toggleFavoriteRecipe(r.id); onRoute(); };

    const btn = document.createElement('button'); btn.type = 'button'; btn.className='btn ok small'; 
    btn.textContent = plan.has(r.id) ? '已加入' : '加入清单';
    btn.onclick = () => { const p=S.load(S.keys.plan,[]); const i=p.findIndex(x=>x.id===r.id); if(i>=0) p.splice(i,1); else p.push({id:r.id, servings:1}); S.save(S.keys.plan,p); onRoute(); };
    
    const detailBtn = document.createElement('button'); detailBtn.type = 'button'; detailBtn.className='btn small'; detailBtn.textContent=hasRecipeMethod(r) ? '查看' : '补做法';
    detailBtn.onclick = () => location.hash = `#recipe:${r.id}`;
    
    card.querySelector('.controls').appendChild(favoriteBtn);
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

function formatRemainingText(days) {
  if (days < 0) return `已过期 ${Math.abs(days)} 天`;
  if (days === 0) return '今天到期';
  return `还剩 ${days} 天`;
}

function formatInventoryAmount(item) {
  const qty = Number(item.qty);
  if (!isFinite(qty) || qty <= 0) return '未填数量';
  return `${qty}${item.unit || ''}`;
}

function getExpiringItems(inv) {
  return [...(inv || [])]
    .filter(item => remainingDays(item) <= 3)
    .sort((a, b) => remainingDays(a) - remainingDays(b))
    .slice(0, 4);
}

function getHomeRecipeGroups(pack, inv) {
  const rows = (pack.recipes || []).filter(hasRecipeMethod).map(r => {
    const list = explodeCombinedItems((pack.recipe_ingredients || {})[r.id] || []);
    const core = list.filter(ing => !isSeasoning(ing.item));
    if (core.length === 0) return null;
    const status = calculateStockStatus(r, pack, inv);
    const missing = status.missing || [];
    const matched = Math.max(0, core.length - missing.length);
    return { r, list, status: status.status, missing, matched, total: core.length };
  }).filter(Boolean);

  const ready = rows
    .filter(row => row.status === 'ok')
    .sort((a, b) => b.total - a.total || a.r.name.localeCompare(b.r.name, 'zh-Hans-CN'))
    .slice(0, 4)
    .map(row => ({ r: row.r, list: row.list, reason: `已有 ${row.total}/${row.total} 项核心食材` }));

  const almost = rows
    .filter(row => row.status === 'partial' && row.missing.length <= 2)
    .sort((a, b) => a.missing.length - b.missing.length || b.matched - a.matched || a.r.name.localeCompare(b.r.name, 'zh-Hans-CN'))
    .slice(0, 4)
    .map(row => ({ r: row.r, list: row.list, reason: `还缺：${row.missing.map(x => x.name).join('、')}` }));

  return { ready, almost };
}

function renderHomeStats(expiring, ready, almost, shoppingItems = []) {
  const div = document.createElement('div');
  const plan = S.load(S.keys.plan, []);
  const activeShopping = shoppingItems.filter(item => !item.done);
  let title = '今天可以轻松安排';
  let body = '库存状态还不错，可以从常做菜或现在能做里挑一道。';
  if (expiring.length) {
    title = `优先用掉 ${expiring[0].name}`;
    body = expiring.slice(0, 3).map(item => `${item.name}${formatRemainingText(remainingDays(item))}`).join('、');
  } else if (ready.length) {
    title = `现在能做 ${ready[0].r.name}`;
    body = ready[0].reason || '这道菜和当前库存匹配度最高。';
  } else if (activeShopping.length) {
    title = `先补 ${activeShopping[0].name}`;
    body = `购物清单还有 ${activeShopping.length} 项未完成。`;
  }
  div.className = 'card home-briefing';
  div.innerHTML = `
    <div class="home-briefing-head">
      <div>
        <div class="home-eyebrow">今日厨房</div>
        <h2>${escapeHtml(title)}</h2>
        <p>${escapeHtml(body)}</p>
      </div>
      <div class="home-briefing-actions">
        <a class="btn ok" href="#shopping">购物清单</a>
        <a class="btn" href="#recipes">菜谱库</a>
      </div>
    </div>
    <div class="home-stats">
      <div class="home-stat"><strong>${expiring.length}</strong><span>快用掉</span></div>
      <div class="home-stat"><strong>${ready.length}</strong><span>现在能做</span></div>
      <div class="home-stat"><strong>${activeShopping.length}</strong><span>待购买</span></div>
      <div class="home-stat"><strong>${plan.length}</strong><span>今天计划</span></div>
    </div>
  `;
  return div;
}

function renderExpiringSection(items, onSearchIngredient) {
  const section = document.createElement('section');
  section.className = 'home-section';
  section.innerHTML = `<div class="section-title home-section-title"><span>快用掉</span></div>`;

  if (!items.length) {
    const empty = document.createElement('div');
    empty.className = 'card home-empty';
    empty.textContent = '目前没有 3 天内到期的库存。';
    section.appendChild(empty);
    return section;
  }

  const list = document.createElement('div');
  list.className = 'quick-list';
  items.forEach(item => {
    const row = document.createElement('div');
    row.className = 'quick-item';

    const info = document.createElement('div');
    const title = document.createElement('div');
    title.className = 'quick-item-title';
    title.textContent = item.name;
    const meta = document.createElement('div');
    meta.className = 'small';
    meta.textContent = `${formatInventoryAmount(item)} · ${formatRemainingText(remainingDays(item))}${item.isFrozen ? ' · 冷冻' : ''}`;
    info.appendChild(title);
    info.appendChild(meta);

    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'btn small';
    btn.textContent = '搜菜谱';
    btn.onclick = () => onSearchIngredient(item.name);

    row.appendChild(info);
    row.appendChild(btn);
    list.appendChild(row);
  });
  section.appendChild(list);
  return section;
}

function renderHomeRecipeShelf(title, items, pack, emptyText) {
  const section = document.createElement('section');
  section.className = 'home-section';
  section.innerHTML = `<div class="section-title home-section-title"><span>${title}</span></div>`;

  if (!items.length) {
    const empty = document.createElement('div');
    empty.className = 'card home-empty';
    empty.textContent = emptyText;
    section.appendChild(empty);
    return section;
  }

  const scroller = document.createElement('div');
  scroller.className = 'horizontal-scroll';
  showRecommendationCards(scroller, items, pack);
  section.appendChild(scroller);
  return section;
}

function renderMoreRecommendations(pack, inv) {
  const recDiv = document.createElement('div');
  recDiv.className = 'home-section';
  recDiv.innerHTML = `<div class="section-title home-section-title"><span>更多推荐</span><button type="button" class="btn ai small" id="callAiBtn" style="padding:6px 12px;">呼叫 AI</button></div><div id="rec-content" class="horizontal-scroll"></div>`;

  const recGrid = recDiv.querySelector('#rec-content');
  const savedAiRecs = S.load(S.keys.ai_recs, null);
  if (savedAiRecs) {
     const savedCards = processAiData(savedAiRecs, pack);
     if (savedCards.length > 0) {
       showRecommendationCards(recGrid, savedCards, pack);
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
  aiBtn.onclick = async () => {
    if (aiBtn.getAttribute('disabled')) return;

    aiBtn.setAttribute('disabled', 'true');
    await new Promise(r => setTimeout(r, 50));
    aiBtn.innerHTML = '<span class="spinner"></span> 思考中...'; aiBtn.style.opacity = '0.7';

    const maxRetries = 1;
    let attempt = 0;
    let success = false;

    const safetyTimer = setTimeout(() => {
       if(!success) {
           aiBtn.innerHTML = '呼叫 AI';
           aiBtn.style.opacity = '1';
           aiBtn.removeAttribute('disabled');
           alert("AI 响应超时，已自动切换到本地推荐。");
           showRecommendationCards(recGrid, getLocalRecommendations(pack, inv, true), pack);
       }
    }, 30000);

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

    if (success || attempt > maxRetries) {
        aiBtn.innerHTML = '呼叫 AI';
        aiBtn.style.opacity = '1';
        aiBtn.removeAttribute('disabled');
        aiBtn.style.display = 'none'; aiBtn.offsetHeight; aiBtn.style.display = '';
    }
  };

  return recDiv;
}

function renderHome(pack){ 
  const container = document.createElement('div'); 
  const catalog = buildCatalog(pack); 
  const inv = loadInventory(catalog); 
  const expiring = getExpiringItems(inv);
  const groups = getHomeRecipeGroups(pack, inv);
  const shoppingItems = loadShoppingItems();

  const searchBar = document.createElement('div');
  searchBar.className = 'home-search';
  searchBar.innerHTML = `<input id="mainSearch" placeholder="搜菜谱，比如回锅肉"><button type="button" class="btn ok" id="doSearch">搜索</button>`;

  const showSearch = (query) => {
      const q = String(query || '').trim();
      if(q) {
          container.innerHTML = ''; container.appendChild(searchBar);
          searchBar.querySelector('#mainSearch').value = q; searchBar.querySelector('#doSearch').onclick = doSearch;
          container.appendChild(renderRecipeSearchResults(q, pack, inv));
      }
  };
  const doSearch = () => showSearch(searchBar.querySelector('#mainSearch').value);

  const title = document.createElement('div');
  title.className = 'main-title-center';
  title.innerHTML = '<span>厨房</span>';
  container.appendChild(title);
  container.appendChild(searchBar);
  searchBar.querySelector('#doSearch').onclick = doSearch;
  container.appendChild(renderHomeStats(expiring, groups.ready, groups.almost, shoppingItems));
  container.appendChild(renderExpiringSection(expiring, showSearch));
  const favoriteCards = getFavoriteRecipeCards(pack);
  if (favoriteCards.length > 0) {
    container.appendChild(renderHomeRecipeShelf('常做菜', favoriteCards, pack, ''));
  }
  container.appendChild(renderHomeRecipeShelf('现在能做', groups.ready, pack, '还没有完全匹配库存的菜。先补一点库存，推荐会更准。'));
  container.appendChild(renderHomeRecipeShelf('差一点就能做', groups.almost, pack, '暂时没有只差一两样食材的菜。'));
  container.appendChild(renderMoreRecommendations(pack, inv));

  const invTitle = document.createElement('div');
  invTitle.className = 'section-title home-section-title';
  invTitle.innerHTML = '<span>我的库存</span>';
  container.appendChild(invTitle);
  container.appendChild(renderInventory(pack, { showTitle: false }));
  return container; 
}

// ★★★ 修复：购物清单 + 常备品检查 (renderShopping) + [新]支持无数量食材 ★★★
function renderShopping(pack){
  const catalog = buildCatalog(pack);
  const inv=loadInventory(catalog); const plan=S.load(S.keys.plan,[]); const map=pack.recipe_ingredients||{};
  const ingredientOptions = buildIngredientOptions(catalog);
  const shoppingItems = loadShoppingItems();
  const need={};
  const addNeed=(n,q,u,source='菜谱')=>{
    const k=n+'|'+(u||'g');
    if(!need[k]) need[k]={qty:0, sources:[]};
    need[k].qty += (+q||0);
    if(source && !need[k].sources.includes(source)) need[k].sources.push(source);
  };
  
  for(const p of plan){ 
    const recipe = (pack.recipes || []).find(r => r.id === p.id);
    const ingList = explodeCombinedItems(map[p.id]||[]);
    
    // [修复] 如果菜谱没有食材列表(比如AI生成的空壳)，则将菜谱名作为待办加入
    if (!ingList || ingList.length === 0) {
       if (recipe) {
          addNeed(recipe.name + " (原料)", p.servings||1, "份", recipe.name);
       }
    } else {
        for(const it of ingList){ 
           // [修复] 即使qty不是数字(null/undefined)，也默认按1处理，防止漏买
           let qty = 1;
           if(typeof it.qty === 'number' && isFinite(it.qty)) {
             qty = it.qty;
           }
           addNeed(it.item, qty*(p.servings||1), it.unit, recipe ? recipe.name : '菜谱');
        }
    }
  }
  
  const missing=[]; for(const [k,req] of Object.entries(need)){ const [n,u]=k.split('|'); const stock=(inv.filter(x=>x.name===n&&x.unit===u).reduce((s,x)=>s+(+x.qty||0),0)); const m=Math.max(0, Math.round((req.qty-stock)*100)/100); if(m>0) missing.push({name:n, unit:u, qty:m, source:req.sources.join('、')}); }
  const d=document.createElement('div'); d.className='shopping-page'; const h=document.createElement('h2'); h.className='section-title'; h.textContent='购物清单'; d.appendChild(h);
  const manualCard=document.createElement('div'); manualCard.className='card shopping-manual-card';
  manualCard.innerHTML=`
    <h3>手动添加</h3>
    <div class="shopping-add-row">
      <input id="shoppingAddName" list="shoppingCatalogList" placeholder="想买什么">
      <datalist id="shoppingCatalogList">${ingredientOptions.map(o=>`<option value="${escapeOptionAttr(o.value)}"${o.label ? ` label="${escapeOptionAttr(o.label)}"` : ''}></option>`).join('')}</datalist>
      <input id="shoppingAddQty" type="number" min="0" step="1" placeholder="数量">
      <select id="shoppingAddUnit"><option value="">无单位</option><option value="个">个</option><option value="盒">盒</option><option value="袋">袋</option><option value="瓶">瓶</option><option value="把">把</option><option value="份">份</option><option value="g">g</option><option value="ml">ml</option></select>
      <button type="button" class="btn ok" id="shoppingAddBtn">加入</button>
    </div>
  `;
  manualCard.querySelector('#shoppingAddName').addEventListener('input', e => {
    const val = e.target.value.trim();
    if(val) manualCard.querySelector('#shoppingAddUnit').value = guessKitchenUnit(getCanonicalName(val));
  });
  manualCard.querySelector('#shoppingAddBtn').onclick = () => {
    const name = manualCard.querySelector('#shoppingAddName').value.trim();
    if(!name) return alert('请输入要买的东西');
    addShoppingItem(name, manualCard.querySelector('#shoppingAddQty').value || '', manualCard.querySelector('#shoppingAddUnit').value || '', '手动');
    onRoute();
  };
  d.appendChild(manualCard);
  const pd=document.createElement('div'); pd.className='card shopping-plan-card'; pd.innerHTML='<h3>今日计划</h3>'; const pl=document.createElement('div'); pl.className='shopping-plan-list'; pd.appendChild(pl);
  function drawPlan(){ pl.innerHTML=''; if(plan.length===0){ const p=document.createElement('p'); p.className='small'; p.textContent='暂未添加菜谱。去“菜谱/推荐”点“加入购物计划”。'; pl.appendChild(p); return; }
    for(const p of plan){ const r=(pack.recipes||[]).find(x=>x.id===p.id); if(!r) continue; const row=document.createElement('div'); row.className='shopping-plan-row';
      row.innerHTML=`<span class="shopping-plan-name">${r.name}</span><label class="shopping-servings"><span>份数</span><input type="number" min="1" max="8" step="1" value="${p.servings||1}"></label><a class="btn small" href="javascript:void(0)">移除</a>`;
      const input=els('input',row)[0]; input.onchange=()=>{ const plans=S.load(S.keys.plan,[]); const it=plans.find(x=>x.id===p.id); if(it){ it.servings=+input.value||1; S.save(S.keys.plan,plans); onRoute(); } };
      els('.btn',row)[0].onclick=()=>{ const plans=S.load(S.keys.plan,[]); const i=plans.findIndex(x=>x.id===p.id); if(i>=0){ plans.splice(i,1); S.save(S.keys.plan,plans); onRoute(); } };
      pl.appendChild(row);
    }} drawPlan(); d.appendChild(pd);
  const needCard=document.createElement('div'); needCard.className='card shopping-missing-card'; needCard.innerHTML='<h3>菜谱缺货</h3>';
  const tbl=document.createElement('table'); tbl.className='table shopping-table'; tbl.innerHTML=`<thead><tr><th>食材</th><th>缺少数量</th><th>来源</th><th class="right">操作</th></tr></thead><tbody></tbody>`; const tb=tbl.querySelector('tbody');
  if(missing.length===0){ const tr=document.createElement('tr'); tr.innerHTML='<td colspan="4" class="small">库存已满足，不需要购买。</td>'; tb.appendChild(tr); }
  else { for(const m of missing){ const tr=document.createElement('tr'); tr.innerHTML=`<td>${escapeHtml(m.name)}</td><td>${m.qty}${escapeHtml(m.unit || '')}</td><td class="small">${escapeHtml(m.source || '菜谱')}</td><td class="right"><a class="btn" href="javascript:void(0)">标记已购 → 入库</a></td>`; els('.btn',tr)[0].onclick=()=>{ const invv=S.load(S.keys.inventory,[]); addInventoryQty(invv,m.name,m.qty,m.unit,'raw'); tr.remove(); }; tb.appendChild(tr); } }
  needCard.appendChild(tbl); d.appendChild(needCard);

  const itemCard=document.createElement('div'); itemCard.className='card shopping-items-card'; itemCard.innerHTML='<h3>我的购物项</h3>';
  const itemList=document.createElement('div'); itemList.className='shopping-item-list';
  if(shoppingItems.length===0) {
    const empty=document.createElement('p'); empty.className='small'; empty.textContent='还没有手动添加的购物项。'; itemList.appendChild(empty);
  } else {
    shoppingItems.forEach(item => {
      const row=document.createElement('div'); row.className=`shopping-item-row${item.done ? ' done' : ''}`;
      const amount = [item.qty, item.unit].filter(Boolean).join('');
      row.innerHTML=`
        <label class="shopping-check"><input type="checkbox" ${item.done ? 'checked' : ''}><span>${escapeHtml(item.name)}</span></label>
        <span class="shopping-item-amount">${escapeHtml(amount || '按需')}</span>
        <span class="shopping-source">${escapeHtml(item.source || '手动')}</span>
        <button type="button" class="btn small bad">删</button>
      `;
      row.querySelector('input').onchange = e => {
        const items = loadShoppingItems();
        const target = items.find(x => x.id === item.id);
        if(target) target.done = e.target.checked;
        saveShoppingItems(items);
        onRoute();
      };
      row.querySelector('button').onclick = () => {
        saveShoppingItems(loadShoppingItems().filter(x => x.id !== item.id));
        onRoute();
      };
      itemList.appendChild(row);
    });
  }
  itemCard.appendChild(itemList); d.appendChild(itemCard);

  // --- [修改] 分类且美化的常备品面板 ---
  const staplesPanel = document.createElement('div');
  staplesPanel.className = 'card staples-card';
  // 去除原来的硬边框，改用更有质感的头部设计
  staplesPanel.innerHTML = `
    <h3 style="margin-top:0; color:var(--text-main); display:flex; align-items:center;">
      <span style="margin-right:8px;">🧂</span> 家中常备品检查
    </h3>
    <p class="meta" style="margin-bottom:16px;">点击缺少的常备品，它们会加入“我的购物项”。</p>
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
      const alreadyAdded = shoppingItems.some(item => item.name === getCanonicalName(name) && item.source === '常备品' && !item.done);
      if(alreadyAdded) span.classList.add('active');

      span.onclick = () => {
        const items = loadShoppingItems();
        const canonical = getCanonicalName(name);
        const existing = items.find(item => item.name === canonical && item.source === '常备品' && !item.done);
        if(existing) {
          saveShoppingItems(items.filter(item => item.id !== existing.id));
        } else {
          items.push({ id: genId(), name: canonical, qty: '', unit: '', source: '常备品', done: false });
          saveShoppingItems(items);
        }
        onRoute();
      };
      pillContainer.appendChild(span);
    });
    
    groupDiv.appendChild(pillContainer);
    container.appendChild(groupDiv);
  });
  d.appendChild(staplesPanel);
  // --- [修改结束] ---

  const tools=document.createElement('div'); tools.className='controls shopping-tools';
  const copy=document.createElement('a'); copy.className='btn'; copy.textContent='复制清单';
  
  copy.onclick=()=>{ 
    const lines=missing.map(m=>`${m.name} ${m.qty}${m.unit}（${m.source || '菜谱'}）`);
    const activeItems = loadShoppingItems().filter(item => !item.done);
    if(activeItems.length > 0) {
      lines.push('--- 我的购物项 ---');
      lines.push(...activeItems.map(item => `${item.name}${item.qty ? ' ' + item.qty : ''}${item.unit || ''}（${item.source || '手动'}）`));
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

// ★★★ 修复：使用 SVG 图标 + 强制隐藏 Input + 冷冻功能 + 防止负数 + [新增]详情编辑 + [修复]按钮重叠(使用Grid) ★★★
function renderInventory(pack, options = {}){ const catalog=buildCatalog(pack); const inv=loadInventory(catalog); const wrap=document.createElement('div'); 
  const ingredientOptions = buildIngredientOptions(catalog);
  // [修改] 使用新的 main-title-center 样式, 且明确使用 span
  const header = document.createElement('div'); 
  header.className = 'main-title-center'; 
  header.innerHTML = '<span>厨房</span>'; 
  if (options.showTitle !== false) wrap.appendChild(header);
  
  const searchDiv = document.createElement('div'); searchDiv.className = 'controls'; searchDiv.style.marginBottom = '8px'; 
  
  // SVG + visually-hidden input (添加 style="display:none!important" 双重保险)
  searchDiv.innerHTML = `
    <div style="display:flex; gap:8px; width:100%; justify-content:flex-end;">
      <button type="button" class="btn small" id="exportInventoryBtn" title="导出库存" style="gap:6px;">
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path><polyline points="7 10 12 15 17 10"></polyline><line x1="12" y1="15" x2="12" y2="3"></line></svg>
        <span>导出库存</span>
      </button>
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

  searchDiv.querySelector('#exportInventoryBtn').onclick = () => {
    const payload = {
      type: 'kitchen-inventory',
      version: 1,
      exportedAt: new Date().toISOString(),
      inventory: inv.map(item => ({...item}))
    };
    const blob = new Blob([JSON.stringify(payload, null, 2)], {type: 'application/json'});
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `kitchen-inventory-${todayISO()}.json`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 0);
  };
  
  // [修改] 彻底使用 Grid 布局修复对齐问题
  const formContainer = document.createElement('div'); formContainer.className = 'add-form-container'; 
  formContainer.innerHTML = `
    <div class="form-grid">
      <div class="full-width">
        <input id="addName" list="catalogList" placeholder="食材名称 (必填)" style="width:100%;">
        <datalist id="catalogList">${ingredientOptions.map(o=>`<option value="${escapeOptionAttr(o.value)}"${o.label ? ` label="${escapeOptionAttr(o.label)}"` : ''}></option>`).join('')}</datalist>
      </div>
      <div class="full-width add-state-row">
        <span class="add-state-label">状态</span>
        <div class="add-state-options" id="addStockStatus">
          <button type="button" class="add-state-option active" data-status="ok">够用</button>
          <button type="button" class="add-state-option" data-status="low">快没了</button>
          <button type="button" class="add-state-option" data-status="unknown">不确定</button>
        </div>
      </div>
      <div class="qty-group">
        <input id="addQty" type="number" min="0" step="1" placeholder="数量（可选）" style="width:60%;">
        <select id="addUnit" style="width:40%;"><option value="个">个</option><option value="盒">盒</option><option value="袋">袋</option><option value="瓶">瓶</option><option value="把">把</option><option value="份" selected>份</option><option value="g">g</option><option value="ml">ml</option></select>
      </div>
      <input id="addDate" type="date" value="${todayISO()}" style="width:100%;">
      <div class="full-width" style="margin-top:4px;">
         <label style="display:flex;align-items:center;font-size:14px;cursor:pointer;margin-right:auto;">
           <input type="checkbox" id="addFrozen" style="width:18px;height:18px;margin-right:6px;accent-color:var(--accent);">冷冻
         </label>
         <button id="addBtn" class="btn ok" style="min-width:100px;">入库</button>
      </div>
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
  formContainer.querySelector('#addName').addEventListener('input', (e)=>{
    const val = e.target.value.trim();
    if(val){ formContainer.querySelector('#addUnit').value = guessKitchenUnit(getCanonicalName(val)); }
  }); 
  let selectedStockStatus = 'ok';
  els('.add-state-option', formContainer).forEach(btn => {
    btn.onclick = () => {
      selectedStockStatus = btn.dataset.status || 'ok';
      els('.add-state-option', formContainer).forEach(x => x.classList.toggle('active', x === btn));
    };
  });
  
  // [修改] 强制数量非负 + 冷冻逻辑
  formContainer.querySelector('#addBtn').onclick=()=>{ 
    const rawName=formContainer.querySelector('#addName').value.trim(); 
    if(!rawName) return alert('请输入食材名称'); 
    const name=getCanonicalName(rawName);
    
    // 获取数值，如果是负数则强制归0
    let qty = +formContainer.querySelector('#addQty').value || 1; 
    if (qty < 0) qty = 0;

    const unit=formContainer.querySelector('#addUnit').value; 
    const date=formContainer.querySelector('#addDate').value||todayISO(); 
    const isFrozen = formContainer.querySelector('#addFrozen').checked; // 获取冷冻状态

    // 如果冷冻，保质期设为180天，否则自动推算
    const shelfDays = isFrozen ? 180 : guessShelfDays(name, unit);
    
    upsertInventory(inv,{name, qty, unit, buyDate:date, kind:'raw', shelf:shelfDays, isFrozen: isFrozen, stockStatus:selectedStockStatus}); 
    
    formContainer.querySelector('#addName').value = ''; 
    formContainer.querySelector('#addQty').value = ''; 
    formContainer.querySelector('#addFrozen').checked = false; // 重置
    selectedStockStatus = 'ok';
    els('.add-state-option', formContainer).forEach(x => x.classList.toggle('active', x.dataset.status === 'ok'));
    renderTable(); 
  };
  
  const tbl=document.createElement('table'); tbl.className='table inventory-table'; tbl.innerHTML=`<thead><tr><th style="width:35%">食材</th><th style="width:25%">厨房状态</th><th style="width:25%">保质</th><th class="right">操作</th></tr></thead><tbody></tbody>`; wrap.appendChild(tbl);
  const scanStatus = searchDiv.querySelector('#scanStatus');
  searchDiv.querySelector('#camInput').onchange = async (e) => {
    const file = e.target.files[0]; if(!file) return;
    scanStatus.style.display = 'block'; scanStatus.innerHTML = '<span class="spinner"></span> 识别中...';
    try {
      const items = await recognizeReceipt(file);
      scanStatus.innerHTML = `✅ 成功！入库 ${items.length} 项`;
      for(const it of items) { if(!it.name) continue; const name = getCanonicalName(it.name); const unit = it.unit || guessKitchenUnit(name); upsertInventory(inv, { name: name, qty: Number(it.qty) || 1, unit: unit, buyDate: todayISO(), kind: 'raw', shelf: guessShelfDays(name, unit), stockStatus:'ok' }); }
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
      const stockInfo = inventoryStateInfo(e.stockStatus);
      // [修改] 增加点击名字编辑功能 + 显示购买日期
      tr.innerHTML=`
        <td class="name-cell" style="cursor:pointer;position:relative;">
          <span style="font-weight:600;color:var(--text-main)">${e.name}</span>
          <br><small style="color:var(--text-secondary);font-size:10px;">${e.buyDate||'未知'}</small>
        </td>
        <td class="kitchen-status-cell"><button type="button" class="inventory-status-chip ${stockInfo.className}" title="点击切换厨房状态">${stockInfo.label}</button><div class="inventory-amount-control"><span>存量</span><input class="qty-input" type="number" min="0" step="1" value="${+e.qty||0}"><small>${e.unit}</small></div></td>
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
      const stockBtn = tr.querySelector('.inventory-status-chip');
      stockBtn.onclick = () => {
        e.stockStatus = nextInventoryState(e.stockStatus);
        saveInventory(inv);
        renderTable();
      };

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
  const methodReadyCount = (pack.recipes || []).filter(hasRecipeMethod).length;
  const missingMethodCount = Math.max(0, (pack.recipes || []).length - methodReadyCount);
  wrap.innerHTML = `
    <div class="recipe-toolbar">
      <input id="search" placeholder="搜菜谱..." style="flex:1;min-width:150px;padding:12px;border-radius:12px;border:1px solid var(--separator);">
      <label class="recipe-filter-toggle"><input type="checkbox" id="methodOnly" checked>只看有做法</label>
      <span class="recipe-count" id="recipeCount"></span>
      <div class="recipe-actions">
        <a class="btn ok icon-only" id="addBtn" title="新建菜谱">
           <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"></line><line x1="5" y1="12" x2="19" y2="12"></line></svg>
        </a>
        <a class="btn" id="exportBtn">导出</a>
        <label class="btn"><input type="file" id="importFile" hidden>导入</label>
      </div>
    </div>
    <div class="grid" id="grid"></div>
  `; 
  const grid = wrap.querySelector('#grid'); 
  const map = pack.recipe_ingredients||{}; 
  const recipeCount = wrap.querySelector('#recipeCount');
  
  function draw(filter=''){ 
    grid.innerHTML = ''; 
    const f = filter.trim(); 
    const methodOnly = wrap.querySelector('#methodOnly').checked;
    const rows = (pack.recipes||[]).filter(r => (!f || r.name.includes(f)) && (!methodOnly || hasRecipeMethod(r)));
    recipeCount.textContent = `显示 ${rows.length} 道 · 有做法 ${methodReadyCount} · 缺做法 ${missingMethodCount}`;
    if(rows.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'card small';
      empty.textContent = methodOnly ? '没有符合条件的菜。可以关闭“只看有做法”查看缺做法菜谱。' : '没有符合条件的菜。';
      grid.appendChild(empty);
      return;
    }
    rows.forEach(r=>{
      grid.appendChild(recipeCard(r, map[r.id])); 
    }); 
  } 
  draw(); 
  
  wrap.querySelector('#search').oninput = e => draw(e.target.value); 
  wrap.querySelector('#methodOnly').onchange = () => draw(wrap.querySelector('#search').value);
  
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
    <h2 class="section-title">厨房备份</h2>
    <div class="card backup-card">
      <p class="meta">导出会包含库存、今日计划、购物项、常做菜、菜谱补丁和 AI 设置。</p>
      <div class="backup-actions">
        <button type="button" class="btn ok" id="exportKitchenBackup">导出整个厨房</button>
        <label class="btn"><input type="file" id="importKitchenBackup" accept="application/json,.json" hidden>导入整个厨房</label>
      </div>
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
  div.querySelector('#exportKitchenBackup').onclick = () => {
    downloadJsonFile(buildKitchenBackup(), `kitchen-backup-${todayISO()}.json`);
  };
  div.querySelector('#importKitchenBackup').onchange = e => {
    const file = e.target.files[0];
    if(!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      try {
        restoreKitchenBackup(JSON.parse(reader.result));
        alert('厨房备份已导入，页面将刷新。');
        location.reload();
      } catch(err) {
        alert('导入失败：' + err.message);
      }
    };
    reader.readAsText(file);
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
