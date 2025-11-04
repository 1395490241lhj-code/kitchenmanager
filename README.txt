补丁包 v6：解决两件事：
1) iPhone 上的脚本报错弹窗（修复 fmt() 里的变量引用）；
2) 菜谱/食材重复（一次性迁移 migration.js + loader 单次合并）。

把 index.html、sw.js、sichuan-loader.js、migration.js、app.patch.v6.js 上传到仓库根目录覆盖即可；不用动 data/ 或 icons/。
部署后访问 ?v=6 并强制刷新一次。
