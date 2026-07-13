import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const service = fs.readFileSync('ios-native/Kitchen Manager/KitchenManager/ImportRecipeService.swift', 'utf8');
const view = fs.readFileSync('ios-native/Kitchen Manager/KitchenManager/AddRecipeViews.swift', 'utf8');
const recipe = fs.readFileSync('ios-native/Kitchen Manager/KitchenManager/Recipe.swift', 'utf8');
const server = fs.readFileSync('server.js', 'utf8');
const media = fs.readFileSync('src/server/services/media-pipeline.js', 'utf8');

test('原生链接导入使用完整媒体降级接口并从分享文案抽取首个 HTTP 链接', () => {
  assert.match(service, /api\/recipe-import-from-url/);
  assert.match(service, /NSDataDetector/);
  assert.match(service, /scheme == "http" \|\| scheme == "https"/);
  assert.doesNotMatch(view, /AI 整理成菜谱/);
});

test('原生导入展示六阶段进度、支持重试并保存来源元数据', () => {
  for (const label of ['正在解析链接', '正在读取页面', '正在提取视频', '正在识别语音', '正在识别字幕', '正在整理菜谱']) {
    assert.match(view, new RegExp(label));
  }
  assert.match(view, /Button\("重试"/);
  assert.match(view, /platform: "xiaohongshu"/);
  assert.match(view, /originalURL: imported\.originalURL/);
  assert.match(view, /canonicalURL: imported\.canonicalURL/);
  assert.match(view, /importedAt: Date\(\)/);
});

test('来源 URL 参与原生持久化去重且旧菜谱仍可解码', () => {
  assert.match(recipe, /var source: RecipeSourceMetadata\? = nil/);
  assert.match(recipe, /containsImportedSource/);
  assert.match(recipe, /sourcesMatch/);
  assert.match(recipe, /sourceAlreadyImported/);
});

test('完整导入不猜测缺失用量并在结束后删除临时媒体', () => {
  assert.match(server, /qty 和 unit 都输出空字符串；不要按常识补克数、份数或勺数/);
  assert.match(server, /if \(!qty[\s\S]*qty = ''/);
  assert.match(media, /cleanupMediaFiles\(temporaryFiles\)/);
});
