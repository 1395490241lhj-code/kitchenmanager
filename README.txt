
# kitchenmanager v16 全量包（GitHub Pages 版）

## 包含内容
- index.html（已接好 ./styles.css、./app.js、补丁与 Service Worker 注册）
- 404.html（与 index 相同，用于 SPA 刷新不 404）
- styles.css（简洁样式）
- app.js（最小可用的前端：菜谱列表与简单推荐）
- ingredients-list-patch.v14.css / ingredients-list-patch.v14.js（把用料渲染成逐行列表）
- sw.v16.js / sw-register.v16.js / sw-reset.html（解决旧缓存导致的空白页）
- data/sichuan-recipes.json（从你的 Excel 解析；若 Excel 缺失则为演示数据）

## 部署步骤
1. 把整个压缩包解压后**全部文件上传到仓库根目录**（含 data/ 目录）。
2. 访问 `https://<你的用户名>.github.io/kitchenmanager/?v=16` 强制刷新（Ctrl+F5 / 下拉刷新）。
3. 若某设备仍不更新，访问 `…/kitchenmanager/sw-reset.html` 清理缓存后再回主页。

## 数据更新
- 之后你要换数据，只需覆盖 `data/sichuan-recipes.json` 即可（确保路径是 `./data/...`）。
