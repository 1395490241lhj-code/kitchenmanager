/*
 * src/onboarding.js —— 首次进入的新手引导向导（Onboarding Tour）
 *
 * 纯本地、零依赖：首启检查 localStorage 的 km_onboarded_v1，不存在则挂载向导；
 * 「开启厨房 / 跳过」后写入标记，确保后续不再弹出。
 *
 * 视觉：通透毛玻璃遮罩 + 居中液态玻璃卡片 + 步骤小圆点 + 磨砂主按钮；
 * 每步在目标元素（底部 Dock / 库存入口 / 菜单计划）上绘制一圈脉冲高光环作为「聚焦提示」。
 */

const ONBOARD_KEY = 'km_onboarded_v1';

const STEPS = [
  {
    emoji: '🥚',
    title: '先记几样食材',
    target: '.home-hero.is-onboarding, #nav-inventory',
    body: '不用完整整理冰箱，先写 3 到 5 样常见食材就行。'
  },
  {
    emoji: '🍳',
    title: '看看今天能做什么',
    target: '.wx-panel, .today-quick',
    body: '我会根据现有食材推荐能做的菜，也会提醒还缺什么。'
  },
  {
    emoji: '✅',
    title: '做完顺手更新',
    target: '.record-cooked-btn, .record-cooked-cta, nav',
    body: '吃完后点一下“饭后记一下”，库存和买菜清单会跟着更新。'
  }
];

export function hasOnboarded() {
  try { return !!localStorage.getItem(ONBOARD_KEY); } catch (e) { return true; }
}

function markOnboarded() {
  try { localStorage.setItem(ONBOARD_KEY, '1'); } catch (e) { /* 隐私模式等：忽略 */ }
}

export function startOnboarding() {
  if (document.querySelector('.km-onboard-overlay')) return; // 已在显示

  let step = 0;

  const overlay = document.createElement('div');
  overlay.className = 'km-onboard-overlay';
  overlay.innerHTML = `
    <div class="km-onboard-ring" hidden></div>
    <div class="km-onboard-card" role="dialog" aria-modal="true" aria-label="新手引导">
      <button type="button" class="km-onboard-skip" aria-label="跳过引导">跳过</button>
      <div class="km-onboard-emoji" aria-hidden="true"></div>
      <h3 class="km-onboard-title"></h3>
      <p class="km-onboard-body"></p>
      <div class="km-onboard-dots" aria-hidden="true"></div>
      <button type="button" class="km-onboard-next">下一步</button>
    </div>
  `;
  document.body.appendChild(overlay);

  const ring = overlay.querySelector('.km-onboard-ring');
  const card = overlay.querySelector('.km-onboard-card');
  const emojiEl = overlay.querySelector('.km-onboard-emoji');
  const titleEl = overlay.querySelector('.km-onboard-title');
  const bodyEl = overlay.querySelector('.km-onboard-body');
  const dotsEl = overlay.querySelector('.km-onboard-dots');
  const nextBtn = overlay.querySelector('.km-onboard-next');
  const skipBtn = overlay.querySelector('.km-onboard-skip');

  const positionRing = () => {
    const sel = STEPS[step].target;
    const target = sel ? document.querySelector(sel) : null;
    const r = target ? target.getBoundingClientRect() : null;
    if (!r || (!r.width && !r.height)) { ring.hidden = true; return; }
    const pad = 8;
    ring.hidden = false;
    ring.style.left = `${Math.max(4, r.left - pad)}px`;
    ring.style.top = `${Math.max(4, r.top - pad)}px`;
    ring.style.width = `${r.width + pad * 2}px`;
    ring.style.height = `${r.height + pad * 2}px`;
  };

  const render = () => {
    const s = STEPS[step];
    // 重新触发内容淡入动画
    card.classList.remove('is-anim');
    void card.offsetWidth;
    card.classList.add('is-anim');

    emojiEl.textContent = s.emoji;
    titleEl.textContent = s.title;
    bodyEl.textContent = s.body;
    dotsEl.innerHTML = STEPS
      .map((_, i) => `<span class="km-onboard-dot${i === step ? ' is-active' : ''}"></span>`)
      .join('');
    nextBtn.textContent = step === STEPS.length - 1 ? '开启厨房 ✨' : '下一步';
    positionRing();
  };

  const onResize = () => positionRing();

  const finish = () => {
    markOnboarded();
    window.removeEventListener('resize', onResize);
    overlay.classList.add('is-closing');
    setTimeout(() => overlay.remove(), 300);
  };

  window.addEventListener('resize', onResize);
  nextBtn.onclick = () => {
    if (step < STEPS.length - 1) { step += 1; render(); }
    else finish();
  };
  skipBtn.onclick = finish;
  // 点击遮罩空白不关闭（引导需走完或主动跳过），避免误触；按 Esc 视为跳过。
  overlay.addEventListener('keydown', (e) => { if (e.key === 'Escape') finish(); });

  requestAnimationFrame(() => overlay.classList.add('is-open'));
  render();
  nextBtn.focus?.();
}

/**
 * 入口调用：仅首次（未写入 km_onboarded_v1）时，等首屏渲染稳定后启动向导。
 */
export function maybeStartOnboarding() {
  if (hasOnboarded()) return;
  // 略等首屏视图渲染完成，确保聚焦环能找到 nav / 菜单计划等目标元素。
  setTimeout(() => { if (!hasOnboarded()) startOnboarding(); }, 450);
}
