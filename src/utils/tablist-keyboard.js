// 水平 tablist 的键盘模型（WAI-ARIA APG "Tabs with Automatic Activation"）。
//
// 抽成纯函数是为了让方向键 / Home / End 的行为可以脱离 DOM 单测：调用方只负责
// 把「按了什么键、当前第几个、一共几个」交进来，拿到「应该激活第几个」。
// 返回 -1 表示这个键不归 tablist 管，调用方必须原样放行（不要 preventDefault），
// 否则会吃掉 Tab / Enter / Space 等标准按键。
export const TABLIST_KEYS = ['ArrowLeft', 'ArrowRight', 'Home', 'End'];

export function nextTabIndex(key, currentIndex, count) {
  if (!Number.isInteger(count) || count <= 0) return -1;
  if (!Number.isInteger(currentIndex) || currentIndex < 0 || currentIndex >= count) return -1;
  switch (key) {
    // 左右在首尾环绕：APG 对水平 tablist 的推荐行为。
    case 'ArrowLeft': return (currentIndex - 1 + count) % count;
    case 'ArrowRight': return (currentIndex + 1) % count;
    case 'Home': return 0;
    case 'End': return count - 1;
    default: return -1;
  }
}
