 (cd "$(git rev-parse --show-toplevel)" && git apply --3way <<'EOF' 
diff --git a/scripts/build-sichuan-pack.js b/scripts/build-sichuan-pack.js
new file mode 100644
index 0000000000000000000000000000000000000000..3224c4fabc2360c0bc07070ed7c92b4d3daabe65
--- /dev/null
+++ b/scripts/build-sichuan-pack.js
@@ -0,0 +1,43 @@
+const fs = require('fs');
+const path = require('path');
+
+const root = path.resolve(__dirname, '..');
+const sourcePath = path.join(root, 'sichuan-recipes.json');
+const targetPath = path.join(root, 'data', 'sichuan-recipes.json');
+
+function main(){
+  const rawText = fs.readFileSync(sourcePath, 'utf8');
+  const items = JSON.parse(rawText);
+  if(!Array.isArray(items)){
+    throw new Error('源文件应为数组结构: ' + sourcePath);
+  }
+
+  const recipes = items.map(rec => {
+    const { ingredients, steps, ...rest } = rec;
+    return rest;
+  });
+
+  const recipeIngredients = Object.fromEntries(items.map(rec => {
+    const list = Array.isArray(rec.ingredients) ? rec.ingredients : [];
+    return [rec.id, list.map(({ item, qty = 0, unit = 'g' }) => ({ item, qty, unit }))];
+  }));
+
+  const recipeSteps = Object.fromEntries(items.map(rec => {
+    const list = Array.isArray(rec.steps) ? rec.steps : [];
+    return [rec.id, list];
+  }));
+
+  const pack = {
+    generated_at: new Date().toISOString(),
+    source: path.relative(root, sourcePath),
+    recipes,
+    recipe_ingredients: recipeIngredients,
+    recipe_steps: recipeSteps,
+  };
+
+  const text = JSON.stringify(pack, null, 2);
+  fs.writeFileSync(targetPath, text + '\n');
+  console.log(`已生成四川菜谱包，共包含 ${recipes.length} 道菜：${targetPath}`);
+}
+
+main();
 
EOF
)
