/*
 * src/components/pantry-shelf.js
 *
 * 蛋奶 / 干货「常备品瓦片」——与基础调味料一致的极简状态色块（充足 / 不足）。
 * 嵌入「常备货架」折叠块内；返回一个 DocumentFragment（若干 .shopping-staple-group）。
 *
 * 双态：充足 = 有货；不足 = 缺货（点一下切换）。
 *   - 切为「不足」→ 自动加入购物清单（与调味料常备品行为一致）。
 *   - 切回「充足」→ 移除该项仍未购买的清单项。
 * 状态存在 inventory（stockStatus / qty），保留保质期等语义。
 */
import { DRY_GOODS, EGG_STOCK, DAILY_STOCKS, guessShelfDays } from '../ingredients.js?v=230';
import { ensureStockItem, findStockItem, saveInventory, syncOutOfStockTimestamp } from '../inventory.js?v=230';
import { addShoppingItem, loadShoppingItems, saveShoppingItems } from '../shopping.js?v=230';
import { applyPantryCustomConfig } from '../staples.js?v=230';
import { escapeHtml } from './status.js?v=230';

const PANTRY_GROUPS = [
  {
    group: '蛋奶',
    items: [
      { name: EGG_STOCK.name, kind: 'raw', unit: EGG_STOCK.unit, source: '日常补给' },
      ...DAILY_STOCKS.map(c => ({ name: c.name, kind: 'raw', unit: c.unit, source: '日常补给' }))
    ]
  },
  {
    group: '干货',
    items: DRY_GOODS.map(c => ({ name: c.name, kind: 'dry', unit: c.unit, source: '常备干货', prep: c.prep }))
  }
];

// 缺省（无记录）视为「充足」，只有明确清空才算「不足」，避免初始一片缺货。
function isPantryLow(item) {
  return !!item && (item.stockStatus === 'empty' || (+item.qty || 0) <= 0);
}

function removeOpenShoppingItem(name) {
  const items = loadShoppingItems();
  const kept = items.filter(it => !(it.name === name && !it.done));
  if (kept.length !== items.length) saveShoppingItems(kept);
}

function togglePantryItem(inv, cfg, currentlyLow) {
  const target = findStockItem(inv, cfg.name, cfg.kind) || ensureStockItem(inv, cfg, cfg.kind, 'ok');
  target.unit = target.unit || cfg.unit;
  target.kind = cfg.kind;
  if (currentlyLow) {
    // → 充足
    target.stockStatus = 'ok';
    target.qty = Math.max(1, +target.qty || 1);
    target.shelf = cfg.kind === 'dry' ? 365 : guessShelfDays(target.name, target.unit);
    if (cfg.kind === 'dry') { target.dryPrep = cfg.prep; target.isFrozen = false; }
    removeOpenShoppingItem(cfg.name);
  } else {
    // → 不足
    target.stockStatus = 'empty';
    target.qty = 0;
    addShoppingItem(cfg.name, '', cfg.unit, cfg.source);
  }
  syncOutOfStockTimestamp(target); // 常备品充足/不足切换 → 同步断货时间戳
  saveInventory(inv);
}

// 返回 DocumentFragment：蛋奶 / 干货两组，缺货项优先，微型胶囊样式与基础调味料一致。
export function renderDryGoodsCabinet(inv, options = {}) {
  const onRoute = typeof options.onRoute === 'function' ? options.onRoute : () => {};
  const isManagingPantry = !!options.isManagingPantry;
  const onEditPantryItem = typeof options.onEditPantryItem === 'function' ? options.onEditPantryItem : () => {};
  const onDeletePantryItem = typeof options.onDeletePantryItem === 'function' ? options.onDeletePantryItem : () => {};
  const frag = document.createDocumentFragment();
  applyPantryCustomConfig(PANTRY_GROUPS, 'pantry').forEach(group => {
    const groupDiv = document.createElement('div');
    groupDiv.className = 'shopping-staple-group';
    groupDiv.innerHTML = `<div class="shopping-staple-title">${escapeHtml(group.group)}</div>`;
    const grid = document.createElement('div');
    grid.className = 'staple-tile-grid';
    const sortedItems = [...group.items].sort((a, b) => {
      const aLow = isPantryLow(findStockItem(inv, a.name, a.kind));
      const bLow = isPantryLow(findStockItem(inv, b.name, b.kind));
      if (aLow !== bLow) return aLow ? -1 : 1;
      return a.name.localeCompare(b.name, 'zh-Hans-CN');
    });
    sortedItems.forEach(cfg => {
      const item = findStockItem(inv, cfg.name, cfg.kind);
      const low = isPantryLow(item);
      const tile = document.createElement(isManagingPantry ? 'div' : 'button');
      if (!isManagingPantry) tile.type = 'button';
      tile.className = `staple-tile ${low ? 'is-low' : 'is-ok'}${isManagingPantry ? ' is-managing' : ''}`;
      tile.setAttribute('aria-pressed', low ? 'true' : 'false');
      tile.setAttribute('aria-label', `${cfg.name}：${low ? '不足，点击标记为充足' : '充足，点击标记为不足'}`);
      if (isManagingPantry) {
        tile.setAttribute('role', 'button');
        tile.tabIndex = 0;
      }
      tile.innerHTML = `
        <span class="staple-tile-name">${escapeHtml(cfg.name)}</span>
        <span class="staple-status-dot" aria-hidden="true"></span>
        ${isManagingPantry ? '<button type="button" class="staple-delete-btn" aria-label="移除">×</button>' : ''}
      `;
      if (isManagingPantry) {
        tile.onclick = () => onEditPantryItem(cfg);
        tile.onkeydown = event => {
          if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            onEditPantryItem(cfg);
          }
        };
        tile.querySelector('.staple-delete-btn').onclick = event => {
          event.stopPropagation();
          onDeletePantryItem(cfg);
        };
      } else {
        tile.onclick = () => { togglePantryItem(inv, cfg, low); onRoute(); };
      }
      grid.appendChild(tile);
    });
    groupDiv.appendChild(grid);
    frag.appendChild(groupDiv);
  });
  return frag;
}
