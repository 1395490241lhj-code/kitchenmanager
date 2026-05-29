/*
 * src/components/pantry-shelf.js
 *
 * 「常备货架」(蛋奶 / 泡发干货) 组件——按数量 / 状态管理鸡蛋、牛奶、木耳等。
 * 从首页迁出，现挂在「清单（采购与库存管理）」页。逻辑保持不变。
 */
import {
  DRY_GOODS, EGG_STOCK, DAILY_STOCKS,
  countStockStatus, dryStatusInfo, guessShelfDays, nextDryStatus
} from '../ingredients.js?v=164';
import {
  ensureStockItem, findStockItem, formatStockLine, saveInventory
} from '../inventory.js?v=164';
import { addShoppingItem } from '../shopping.js?v=164';
import { escapeHtml, brieflyConfirmButton } from './status.js?v=164';

export function renderDryGoodsCabinet(inv, options = {}) {
  const onInventoryChanged = typeof options.onInventoryChanged === 'function' ? options.onInventoryChanged : () => {};
  let debounceTimer = null;
  const notifyChange = () => {
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => {
      onInventoryChanged();
    }, 800);
  };
  const section = document.createElement('section'); section.className = 'dry-goods-section';
  section.innerHTML = `
    <div class="section-title home-section-title"><span>常备货架</span></div>
    <div class="dry-goods-card card">
      <div class="dry-goods-head">
        <div>
          <h3>少记数量，多看状态</h3>
          <p class="meta">先看蛋奶，再看干货；牛奶按瓶/盒和状态管，干货看存货和泡发提醒。</p>
        </div>
      </div>
      <div class="pantry-shelf-group daily-shelf">
        <div class="pantry-shelf-title">蛋奶</div>
        <div class="daily-goods-list"></div>
      </div>
      <div class="pantry-shelf-divider"></div>
      <div class="pantry-shelf-group dry-shelf">
        <div class="pantry-shelf-title">干货</div>
        <div class="dry-goods-list"></div>
      </div>
    </div>
  `;
  const setRowStatusClass = (row, className) => { row.classList.remove('is-ok', 'is-low', 'is-empty', 'is-unknown'); row.classList.add(`is-${className}`); };
  const updateStatusRow = (row, item, config, type = 'dry') => {
    const status = item ? (item.stockStatus || 'ok') : 'empty'; const info = dryStatusInfo(status);
    setRowStatusClass(row, info.className);
    const stockLine = row.querySelector('.dry-good-main em'); if (stockLine) stockLine.textContent = formatStockLine(item, config.unit);
    const statusButton = row.querySelector('.inventory-status-chip');
    if (statusButton) { statusButton.className = `inventory-status-chip ${info.className}`; statusButton.textContent = info.label; }
    const buyButton = row.querySelector('.dry-good-buy');
    if (buyButton && type === 'dry') buyButton.textContent = status === 'ok' ? '补一包' : '加入清单';
  };
  const list = section.querySelector('.dry-goods-list');
  DRY_GOODS.forEach(config => {
    const item = findStockItem(inv, config.name, 'dry');
    const status = item ? (item.stockStatus || 'ok') : 'empty'; const info = dryStatusInfo(status);
    const row = document.createElement('div'); row.className = `dry-good-row is-${info.className}`;
    row.innerHTML = `<div class="dry-good-main"><strong>${escapeHtml(config.name)}</strong><span>${escapeHtml(config.prep)}</span><em>${escapeHtml(formatStockLine(item, config.unit))}</em></div><button type="button" class="inventory-status-chip ${info.className}">${escapeHtml(info.label)}</button><button type="button" class="btn small dry-good-buy">${status === 'ok' ? '补一包' : '加入清单'}</button>`;
    row.querySelector('.inventory-status-chip').onclick = () => {
      let target = item || ensureStockItem(inv, config, 'dry', 'empty');
      target.stockStatus = nextDryStatus(target.stockStatus);
      target.qty = target.stockStatus === 'empty' ? 0 : Math.max(1, +target.qty || 1);
      target.unit = target.unit || config.unit; target.kind = 'dry'; target.shelf = 365; target.dryPrep = config.prep; target.isFrozen = false;
      saveInventory(inv); updateStatusRow(row, target, config, 'dry');
      notifyChange();
    };
    const buyButton = row.querySelector('.dry-good-buy');
    buyButton.onclick = () => { addShoppingItem(config.name, '', config.unit, '常备干货'); brieflyConfirmButton(buyButton); };
    list.appendChild(row);
  });

  const dailyList = section.querySelector('.daily-goods-list');
  const eggItem = findStockItem(inv, EGG_STOCK.name, 'raw');
  const eggQty = Math.max(0, Math.round(+eggItem?.qty || 0));
  const eggStatus = countStockStatus(eggQty); const eggInfo = dryStatusInfo(eggStatus);
  const eggRow = document.createElement('div'); eggRow.className = `dry-good-row daily-good-row egg-good-row is-${eggInfo.className}`;
  eggRow.innerHTML = `<div class="dry-good-main"><strong>${escapeHtml(EGG_STOCK.name)}</strong><span>${escapeHtml(EGG_STOCK.note)}</span><em>${eggQty > 0 ? `库存：${eggQty} 个` : '库存：没有'}</em></div><div class="egg-count-control" aria-label="鸡蛋个数"><button type="button" class="egg-step" data-egg-step="-1" aria-label="减少鸡蛋">-</button><span>${eggQty}</span><button type="button" class="egg-step" data-egg-step="1" aria-label="增加鸡蛋">+</button></div><button type="button" class="btn small dry-good-buy">${eggQty <= 3 ? '补一打' : '加入清单'}</button>`;
  const updateEggRow = (item) => {
    const qty = Math.max(0, Math.round(+item?.qty || 0)); const info = dryStatusInfo(countStockStatus(qty));
    setRowStatusClass(eggRow, info.className);
    const stockLine = eggRow.querySelector('.dry-good-main em'); if (stockLine) stockLine.textContent = qty > 0 ? `库存：${qty} 个` : '库存：没有';
    const countLabel = eggRow.querySelector('.egg-count-control span'); if (countLabel) countLabel.textContent = qty;
    const buyButton = eggRow.querySelector('.dry-good-buy'); if (buyButton) buyButton.textContent = qty <= 3 ? '补一打' : '加入清单';
  };
  eggRow.querySelectorAll('[data-egg-step]').forEach(btn => {
    btn.onclick = () => {
      const step = Number(btn.dataset.eggStep || 0);
      const target = ensureStockItem(inv, EGG_STOCK, 'raw', 'empty');
      const nextQty = Math.max(0, Math.round(+target.qty || 0) + step);
      target.qty = nextQty; target.unit = EGG_STOCK.unit; target.kind = 'raw';
      target.shelf = guessShelfDays(target.name, target.unit);
      target.stockStatus = countStockStatus(nextQty);
      saveInventory(inv); updateEggRow(target);
      notifyChange();
    };
  });
  const eggBuyButton = eggRow.querySelector('.dry-good-buy');
  eggBuyButton.onclick = () => {
    const currentEgg = findStockItem(inv, EGG_STOCK.name, 'raw');
    const currentQty = Math.max(0, Math.round(+currentEgg?.qty || 0));
    addShoppingItem(EGG_STOCK.name, currentQty <= 3 ? 12 : '', EGG_STOCK.unit, '日常补给');
    brieflyConfirmButton(eggBuyButton);
  };
  dailyList.appendChild(eggRow);

  DAILY_STOCKS.forEach(config => {
    const item = findStockItem(inv, config.name, 'raw');
    const status = item ? (item.stockStatus || 'ok') : 'empty'; const info = dryStatusInfo(status);
    const row = document.createElement('div'); row.className = `dry-good-row daily-good-row is-${info.className}`;
    row.innerHTML = `<div class="dry-good-main"><strong>${escapeHtml(config.name)}</strong><span>${escapeHtml(config.note)}</span><em>${escapeHtml(formatStockLine(item, config.unit))}</em></div><button type="button" class="inventory-status-chip ${info.className}">${escapeHtml(info.label)}</button><button type="button" class="btn small dry-good-buy">${config.name === '牛奶' ? '补一瓶' : '补一点'}</button>`;
    row.querySelector('.inventory-status-chip').onclick = () => {
      let target = item || ensureStockItem(inv, config, 'raw', 'empty');
      target.stockStatus = nextDryStatus(target.stockStatus);
      target.qty = target.stockStatus === 'empty' ? 0 : Math.max(1, +target.qty || 1);
      target.unit = target.unit || config.unit; target.kind = 'raw'; target.shelf = guessShelfDays(target.name, target.unit);
      saveInventory(inv); updateStatusRow(row, target, config, 'daily');
      notifyChange();
    };
    const buyButton = row.querySelector('.dry-good-buy');
    buyButton.onclick = () => { addShoppingItem(config.name, '', config.unit, '日常补给'); brieflyConfirmButton(buyButton); };
    dailyList.appendChild(row);
  });
  return section;
}
