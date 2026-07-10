/*
 * src/components/staples-shelf.js —— 常备货架（从清单页迁出，供库存页复用）
 *
 * 「常备货架」= 调料/米面（双态常备品）+ 蛋奶/干货（同样的双态瓦片）的统一管理区。
 * 之前内嵌在清单页的分段控件里；现已挪到独立的「库存」Tab，本组件被 inventory-view 复用。
 *
 * 复用既有逻辑：src/staples.js（常备品状态/增删）+ src/components/pantry-shelf.js（蛋奶/干货柜）。
 * 不重写常备货架逻辑、不改 localStorage key、不改常备品数据结构。
 */
import {
  PANTRY_GROUP_OPTIONS,
  STAPLE_STATUS,
  addCustomPantryEntry,
  getManagedStapleGroups,
  getStapleState,
  removePantryEntry,
  toggleStaple,
  updatePantryEntry
} from '../staples.js?v=236';
import { renderDryGoodsCabinet } from './pantry-shelf.js?v=236';
import { guessKitchenUnit } from '../ingredients.js?v=236';
import { escapeHtml, escapeOptionAttr, setInlineStatus } from './status.js?v=236';

// 「管理货架」模式（增删自定义常备项）：模块级，跨重渲染保持。
let isManagingPantry = false;

const PANTRY_STOCK_GROUPS = new Set(['蛋奶', '干货']);

function getPantryGroupOptions(entry = null) {
  if (!entry) return PANTRY_GROUP_OPTIONS;
  if (entry.type === 'pantry') return PANTRY_GROUP_OPTIONS.filter(group => PANTRY_STOCK_GROUPS.has(group));
  return PANTRY_GROUP_OPTIONS.filter(group => !PANTRY_STOCK_GROUPS.has(group));
}

function closeLiquidModal(overlay, panel) {
  panel.style.transition = 'transform 0.2s ease-in, opacity 0.2s ease-in';
  panel.style.opacity = '0';
  panel.style.transform = 'translate3d(0, 0, 0) scale(0.95)';
  overlay.classList.add('closing');
  window.setTimeout(() => overlay.remove(), 220);
}

function renderPantryGroupSelect(options, selected) {
  const chosen = selected && !options.includes(selected) ? [...options, selected] : options;
  return chosen.map(group => `<option value="${escapeOptionAttr(group)}">${escapeHtml(group)}</option>`).join('');
}

function showPantryEntryModal({ entry = null, onRoute = () => {} } = {}) {
  const isEdit = !!entry;
  const options = getPantryGroupOptions(entry);
  const defaultGroup = entry?.group || options[0] || '基础调味';
  const overlay = document.createElement('div');
  overlay.className = 'km-modal-overlay';
  const panel = document.createElement('div');
  panel.className = 'km-modal-content pantry-manage-modal';
  panel.innerHTML = `
    <div class="km-modal-header">
      <span class="km-modal-title">${isEdit ? `编辑「${escapeHtml(entry.name)}」` : '+ 自定义添加'}</span>
      <button type="button" class="km-modal-close" aria-label="关闭">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
        </svg>
      </button>
    </div>
    <div class="km-modal-body pantry-manage-body">
      <label class="pantry-manage-field">
        <span>食材名称</span>
        <input class="km-modal-input" id="pantryEntryName" value="${escapeOptionAttr(entry?.name || '')}" placeholder="例如：黑木耳">
      </label>
      <label class="pantry-manage-field">
        <span>所属分类</span>
        <select class="km-modal-input" id="pantryEntryGroup">${renderPantryGroupSelect(options, defaultGroup)}</select>
      </label>
      <div id="pantryManageStatus" class="small inline-status" hidden></div>
      <div class="km-modal-actions pantry-manage-actions">
        <button type="button" class="btn" id="cancelPantryManage">取消</button>
        <button type="button" class="btn ok" id="savePantryManage">${isEdit ? '保存修改' : '添加到货架'}</button>
      </div>
    </div>
  `;
  overlay.appendChild(panel);
  document.body.appendChild(overlay);
  requestAnimationFrame(() => overlay.classList.add('open'));

  const nameInput = panel.querySelector('#pantryEntryName');
  const groupSelect = panel.querySelector('#pantryEntryGroup');
  const status = panel.querySelector('#pantryManageStatus');
  groupSelect.value = defaultGroup;

  const close = () => closeLiquidModal(overlay, panel);
  panel.querySelector('.km-modal-close').onclick = close;
  panel.querySelector('#cancelPantryManage').onclick = close;
  overlay.onclick = event => { if (event.target === overlay) close(); };
  nameInput.focus();

  const save = () => {
    const name = nameInput.value.trim();
    const group = groupSelect.value;
    if (!name) {
      setInlineStatus(status, '请先输入常备食材名称。', 'bad');
      return;
    }

    const result = isEdit
      ? updatePantryEntry(entry, { name, group })
      : addCustomPantryEntry({
          name,
          group,
          type: PANTRY_STOCK_GROUPS.has(group) ? 'pantry' : 'staple',
          kind: group === '干货' ? 'dry' : (group === '蛋奶' ? 'raw' : 'staple'),
          unit: PANTRY_STOCK_GROUPS.has(group) ? (guessKitchenUnit(name) || '份') : '',
          source: group === '干货' ? '常备干货' : (group === '蛋奶' ? '日常补给' : '常备品')
        });
    if (!result.ok) {
      setInlineStatus(status, result.message || '保存失败，请稍后再试。', 'bad');
      return;
    }
    isManagingPantry = true;
    close();
    onRoute();
  };

  panel.querySelector('#savePantryManage').onclick = save;
  nameInput.onkeydown = event => {
    if (event.key === 'Enter') save();
  };
}

function showPantryDeleteConfirm(entry, { onRoute = () => {} } = {}) {
  const overlay = document.createElement('div');
  overlay.className = 'km-modal-overlay';
  const panel = document.createElement('div');
  panel.className = 'km-modal-content pantry-manage-modal';
  panel.innerHTML = `
    <div class="km-modal-header">
      <span class="km-modal-title">移除常备项？</span>
      <button type="button" class="km-modal-close" aria-label="关闭">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
        </svg>
      </button>
    </div>
    <div class="km-modal-body pantry-manage-body">
      <p class="pantry-confirm-copy">「${escapeHtml(entry.name)}」会从常备货架里隐藏或删除，食材记录本身不会被清空。</p>
      <div class="km-modal-actions pantry-manage-actions">
        <button type="button" class="btn" id="cancelPantryDelete">取消</button>
        <button type="button" class="btn bad" id="confirmPantryDelete">移除</button>
      </div>
    </div>
  `;
  overlay.appendChild(panel);
  document.body.appendChild(overlay);
  requestAnimationFrame(() => overlay.classList.add('open'));

  const close = () => closeLiquidModal(overlay, panel);
  panel.querySelector('.km-modal-close').onclick = close;
  panel.querySelector('#cancelPantryDelete').onclick = close;
  overlay.onclick = event => { if (event.target === overlay) close(); };
  panel.querySelector('#confirmPantryDelete').onclick = () => {
    removePantryEntry(entry);
    isManagingPantry = true;
    close();
    onRoute();
  };
}

// 【常备货架】统一管理：调料/米面（双态常备品）+ 蛋奶/干货（同样的双态瓦片）。
// 返回平铺内容卡片（.staples-shelf-content）。
export function renderStaplesShelf(inv, { onRoute = () => {} } = {}) {
  const panel = document.createElement('div');
  panel.className = 'staples-shelf-content';
  panel.innerHTML = `
    <div class="card staples-card">
      <div class="staples-card-head">
        <p class="meta shopping-staple-meta">标记为<strong>不足</strong>会自动加入买菜清单；买好后在买菜页勾选「已买」，常备调料会自动恢复为<strong>充足</strong>。</p>
        <button type="button" class="pantry-manage-btn" id="togglePantryManage">${isManagingPantry ? '✓ 完成' : '⚙️ 管理货架'}</button>
      </div>
      <div id="stapleShelf"></div>
    </div>
  `;
  panel.querySelector('#togglePantryManage').onclick = () => {
    isManagingPantry = !isManagingPantry;
    onRoute();
  };
  const shelf = panel.querySelector('#stapleShelf');
  let addTileRendered = false;
  const managedStapleGroups = getManagedStapleGroups();
  if (isManagingPantry && managedStapleGroups.length === 0) managedStapleGroups.push({ group: '自定义', items: [] });
  managedStapleGroups.forEach(group => {
    const groupDiv = document.createElement('div');
    groupDiv.className = 'shopping-staple-group';
    groupDiv.innerHTML = `<div class="shopping-staple-title">${escapeHtml(group.group)}</div>`;
    const grid = document.createElement('div');
    grid.className = 'staple-tile-grid';
    const sortedItems = [...group.items].sort((a, b) => {
      const aLow = getStapleState(a.name).status === STAPLE_STATUS.INSUFFICIENT;
      const bLow = getStapleState(b.name).status === STAPLE_STATUS.INSUFFICIENT;
      if (aLow !== bLow) return aLow ? -1 : 1;
      return a.name.localeCompare(b.name, 'zh-Hans-CN');
    });
    if (isManagingPantry && !addTileRendered) {
      addTileRendered = true;
      const addTile = document.createElement('button');
      addTile.type = 'button';
      addTile.className = 'staple-tile staple-add-tile';
      addTile.innerHTML = '<span class="staple-tile-name">+ 自定义添加</span>';
      addTile.onclick = () => showPantryEntryModal({ onRoute });
      grid.appendChild(addTile);
    }
    sortedItems.forEach(entry => {
      const state = getStapleState(entry.name);
      const low = state.status === STAPLE_STATUS.INSUFFICIENT;
      const tile = document.createElement(isManagingPantry ? 'div' : 'button');
      if (!isManagingPantry) tile.type = 'button';
      tile.className = `staple-tile ${low ? 'is-low' : 'is-ok'}${isManagingPantry ? ' is-managing' : ''}`;
      tile.setAttribute('aria-pressed', low ? 'true' : 'false');
      tile.setAttribute('aria-label', `${entry.name}：${low ? '不足，点击标记为充足' : '充足，点击标记为不足'}`);
      if (isManagingPantry) {
        tile.setAttribute('role', 'button');
        tile.tabIndex = 0;
      }
      tile.innerHTML = `
        <span class="staple-tile-name">${escapeHtml(entry.name)}</span>
        <span class="staple-status-dot" aria-hidden="true"></span>
        ${isManagingPantry ? '<button type="button" class="staple-delete-btn" aria-label="移除">×</button>' : ''}
      `;
      if (isManagingPantry) {
        tile.onclick = () => showPantryEntryModal({ entry, onRoute });
        tile.onkeydown = event => {
          if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            showPantryEntryModal({ entry, onRoute });
          }
        };
        tile.querySelector('.staple-delete-btn').onclick = event => {
          event.stopPropagation();
          showPantryDeleteConfirm(entry, { onRoute });
        };
      } else {
        tile.onclick = () => { toggleStaple(entry.name); onRoute(); };
      }
      grid.appendChild(tile);
    });
    groupDiv.appendChild(grid);
    shelf.appendChild(groupDiv);
  });

  // 蛋奶 / 干货：同样的双态瓦片，直接并入同一组网格，视觉与调料一致。
  shelf.appendChild(renderDryGoodsCabinet(inv, {
    onRoute,
    isManagingPantry,
    onEditPantryItem: entry => showPantryEntryModal({ entry, onRoute }),
    onDeletePantryItem: entry => showPantryDeleteConfirm(entry, { onRoute })
  }));

  return panel;
}
