
# v18 全量包（修复“两个原料被合并为一个”的问题）

**修复点**
- 页面渲染时，如果某条食材名称中出现 `，` / `、` / `,` / `/` / `;` / `；` / `|` 且没有数量，自动**拆成多个食材行**（不会再把两个合成一个）。
- 补丁脚本升级为 v15：即使只有一个分隔符也会拆分（适配老页面的“用料：A，B”情况），并且只在 `.ings` 区域或“用料”后邻近元素内生效，避免误伤其它段落。

**包含文件**
- `index.html`（v18）
- `app.js`（v18，内置拆分逻辑 `explodeCombinedItems`）
- `styles.css`
- `ingredients-list-patch.v15.js` / `ingredients-list-patch.v15.css`
- `sw.v16.js` / `sw-register.v16.js` / `sw-reset.html`
- `404.html`
- `data/sichuan-recipes.json`（示例数据；你可以覆盖为自己的正式数据）

**部署**
1. 把整个压缩包解压后**全部文件上传到仓库根目录**（含 `data/` 目录）。
2. 访问 `https://<用户名>.github.io/kitchenmanager/?v=18`（强制刷新）。
3. 如仍旧显示旧页面，先打开 `…/kitchenmanager/sw-reset.html` 清缓存。

**数据更新**
- 仅需替换 `data/sichuan-recipes.json`。请保持相对路径 `./data/...`。
