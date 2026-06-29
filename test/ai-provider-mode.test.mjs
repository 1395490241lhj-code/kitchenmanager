import test, { afterEach, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import {
  callAiSearchRecipe,
  checkImportedRecipeStepCoverage,
  formatAiErrorMessage,
  getAiErrorDetails,
  getAiConfig,
  getReceiptAiFailureCopy,
  importRecipeFromSource,
  recognizeReceipt
} from '../src/ai.js';
import { S } from '../src/storage.js';

const root = process.cwd();
const oldLocalStorage = global.localStorage;
const oldFetch = global.fetch;
const oldFileReader = global.FileReader;
const oldImage = global.Image;
const oldDocument = global.document;

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

function createStorage() {
  const data = new Map();
  return {
    getItem(key) {
      return data.has(key) ? data.get(key) : null;
    },
    setItem(key, value) {
      data.set(key, String(value));
    },
    removeItem(key) {
      data.delete(key);
    },
    clear() {
      data.clear();
    }
  };
}

function recipeContent(name = '番茄炒蛋') {
  return JSON.stringify({
    name,
    ingredients: [{ item: '鸡蛋', qty: '', unit: '' }],
    method: '1. 鸡蛋打散\n2. 下锅炒熟'
  });
}

beforeEach(() => {
  global.localStorage = createStorage();
});

afterEach(() => {
  global.fetch = oldFetch;
  global.localStorage = oldLocalStorage;
  global.FileReader = oldFileReader;
  global.Image = oldImage;
  global.document = oldDocument;
});

test('默认 AI 配置使用 cloud 模式，不需要本地 API Key', () => {
  const conf = getAiConfig();
  assert.equal(conf.mode, 'cloud');
  assert.equal(conf.apiUrl, '/api/ai-chat');
  assert.equal(conf.apiKey, undefined);
});

test('cloud 模式调用同源 /api/ai-chat，并带 taskType', async () => {
  let request = null;
  global.fetch = async (url, options) => {
    request = { url, options, body: JSON.parse(options.body) };
    return {
      ok: true,
      json: async () => ({ content: recipeContent() })
    };
  };

  const out = await callAiSearchRecipe('番茄炒蛋', '鸡蛋、番茄');
  assert.equal(out.name, '番茄炒蛋');
  assert.equal(request.url, '/api/ai-chat');
  assert.equal(request.options.headers.Authorization, undefined);
  assert.equal(request.body.taskType, 'recipe-search');
  assert.match(request.body.prompt, /番茄炒蛋/);
});

test('cloud 模式错误保留后端 status/code，便于定位上游失败', async () => {
  global.fetch = async () => ({
    ok: false,
    status: 404,
    json: async () => ({
      error: 'AI 服务暂时不可用。',
      status: 404,
      code: 'model_not_found',
      upstreamStatus: 404,
      upstreamCode: 'model_not_found'
    })
  });

  await assert.rejects(
    () => callAiSearchRecipe('番茄炒蛋', '鸡蛋、番茄'),
    /404\/model_not_found/
  );
});

test('AI 错误格式保留 status/code，且 413 小票失败提示可操作', () => {
  const err = new Error('云端服务请求失败 (413/image_too_large)：图片过大。');
  err.status = 413;
  err.code = 'image_too_large';

  const details = getAiErrorDetails(err);
  const copy = getReceiptAiFailureCopy(err);

  assert.equal(details.status, 413);
  assert.equal(details.code, 'image_too_large');
  assert.match(formatAiErrorMessage(err), /413\/image_too_large/);
  assert.match(copy.message, /图片太大/);
  assert.match(copy.message, /文本批量记/);
});

test('小票识别失败区提供重新选择图片和改用文本批量记入口', () => {
  const home = read('src/views/home-view.js');
  const inventory = read('src/views/inventory-view.js');

  assert.match(home, /primaryText: '改用文本批量记'/);
  assert.match(home, /secondaryText: '重新选择图片'/);
  assert.match(home, /setTab\('text'\)/);
  assert.match(inventory, /primaryText: '改用文本批量记'/);
  assert.match(inventory, /secondaryText: '重新选择图片'/);
  assert.match(inventory, /setTab\('manual'\)/);
});

test('AI 菜谱导入失败提供粘贴文本和稍后再试兜底', () => {
  const modal = read('src/components/recipe-import-modal.js');
  const ai = read('src/ai.js');

  assert.match(modal, /id="aiImportTextField" hidden/);
  assert.match(modal, /primaryText: textModeVisible \? '' : '改用粘贴文本'/);
  assert.match(modal, /secondaryText: '稍后再试'/);
  assert.match(modal, /textField\.hidden = false/);
  assert.match(modal, /textInput\.focus\(\)/);
  assert.match(ai, /importRecipeFromSource\(\{ url = '', file = null, text = '' \}/);
  assert.match(ai, /pastedText/);
});

test('菜谱导入完整性检查会提示水没有进入做法步骤', () => {
  const method = '鸡腿煎至两面金黄，加入生抽老抽调味。';
  const result = checkImportedRecipeStepCoverage({
    seasonings: [{ item: '水', qty: '1', unit: '杯' }],
    method
  });

  assert.deepEqual(result.missingInSteps, ['水']);
  assert.equal(method, '鸡腿煎至两面金黄，加入生抽老抽调味。');
  assert.match(result.warnings[0], /水/);
  assert.match(result.warnings[0], /用途/);
  assert.doesNotMatch(result.warnings[0], /加水焖煮|焖熟|收汁/);
});

test('菜谱导入完整性检查会提示藤椒粉没有进入做法步骤', () => {
  const result = checkImportedRecipeStepCoverage({
    seasonings: [{ item: '藤椒粉', qty: '1', unit: '勺' }],
    method: '鸡腿煎至两面金黄，加入生抽老抽调味。'
  });

  assert.deepEqual(result.missingInSteps, ['藤椒粉']);
  assert.match(result.warnings[0], /藤椒粉/);
});

test('菜谱导入完整性检查接受明确的加水焖煮收汁步骤', () => {
  const result = checkImportedRecipeStepCoverage({
    seasonings: [{ item: '水', qty: '1', unit: '杯' }],
    method: '加入适量水焖煮至鸡腿熟透，再大火收汁。'
  });

  assert.deepEqual(result.missingInSteps, []);
  assert.deepEqual(result.warnings, []);
});

test('菜谱导入完整性检查接受明确的藤椒粉使用步骤', () => {
  const result = checkImportedRecipeStepCoverage({
    seasonings: [{ item: '藤椒粉', qty: '1', unit: '勺' }],
    method: '加入藤椒粉腌制鸡腿，再下锅煎熟。'
  });

  assert.deepEqual(result.missingInSteps, []);
  assert.deepEqual(result.warnings, []);
});

test('菜谱导入完整性检查接受鲜藤椒的真实加入动作', () => {
  const result = checkImportedRecipeStepCoverage({
    seasonings: [{ item: '鲜藤椒', qty: '1', unit: '把' }],
    method: '加入鲜藤椒和生抽等调味料，翻炒均匀后出锅。'
  });

  assert.deepEqual(result.missingInSteps, []);
  assert.deepEqual(result.warnings, []);
});

test('菜谱导入完整性检查不会把藤椒粉当成鲜藤椒', () => {
  const result = checkImportedRecipeStepCoverage({
    seasonings: [{ item: '鲜藤椒', qty: '1', unit: '把' }],
    method: '加入藤椒粉腌制鸡腿，再下锅煎熟。'
  });

  assert.deepEqual(result.missingInSteps, ['鲜藤椒']);
  assert.match(result.warnings[0], /鲜藤椒/);
  assert.match(result.warnings[0], /加入时机/);
});

test('菜谱导入完整性 warning 不阻止生成可编辑草稿', async () => {
  global.fetch = async (url, options) => {
    assert.equal(url, '/api/ai-parse');
    assert.match(JSON.parse(options.body).text, /藤椒鸡腿/);
    return {
      ok: true,
      json: async () => ({
        content: JSON.stringify({
          name: '藤椒鸡腿',
          tags: ['家常菜'],
          ingredients: [{ item: '鸡腿', qty: '2', unit: '个' }],
          seasonings: [
            { item: '水', qty: '1', unit: '杯' },
            { item: '藤椒粉', qty: '1', unit: '勺' }
          ],
          method: ['鸡腿煎至两面金黄', '加入生抽老抽料酒调味']
        })
      })
    };
  };

  const draft = await importRecipeFromSource({ text: '藤椒鸡腿做法' });
  assert.equal(draft.name, '藤椒鸡腿');
  assert.equal(draft.isAiDraft, true);
  assert.equal(draft.needsReview, true);
  assert.match(draft.method, /需要确认/);
  assert.match(draft.method, /水/);
  assert.match(draft.method, /藤椒粉/);
});

test('菜谱导入保留鲜藤椒步骤，不自动补成加水焖熟', async () => {
  const sourceMethod = '鸡腿煎至两面金黄，加入鲜藤椒、生抽、老抽、料酒、盐、糖调味，翻炒均匀后出锅。';
  global.fetch = async (url, options) => {
    assert.equal(url, '/api/ai-parse');
    assert.match(JSON.parse(options.body).text, /鲜藤椒鸡腿/);
    return {
      ok: true,
      json: async () => ({
        content: JSON.stringify({
          name: '鲜藤椒鸡腿',
          tags: ['家常菜'],
          ingredients: [{ item: '鸡腿', qty: '2', unit: '个' }],
          seasonings: [
            { item: '鲜藤椒', qty: '1', unit: '把' },
            { item: '生抽', qty: '2', unit: '勺' },
            { item: '老抽', qty: '1', unit: '勺' },
            { item: '料酒', qty: '1', unit: '勺' },
            { item: '盐', qty: '1', unit: '适量' },
            { item: '糖', qty: '1', unit: '适量' },
            { item: '水', qty: '1', unit: '杯' }
          ],
          method: sourceMethod
        })
      })
    };
  };

  const draft = await importRecipeFromSource({ text: '鲜藤椒鸡腿做法' });
  assert.match(draft.method, /加入鲜藤椒、生抽、老抽、料酒、盐、糖调味/);
  assert.doesNotMatch(draft.method, /加水焖熟|加水焖煮|加水炖煮|加水收汁/);
  assert.match(draft.method, /原内容列出了水，但做法未明确说明水的用途，请确认。/);
  assert.doesNotMatch(draft.method, /鲜藤椒未在做法中明确出现/);
  assert.deepEqual(draft.warnings, ['原内容列出了水，但做法未明确说明水的用途，请确认。']);
});

test('小票识别走同源 /api/ai-chat，不在前端携带 Authorization', async () => {
  const canvasAttempts = [];
  global.FileReader = class MockFileReader {
    readAsDataURL() {
      queueMicrotask(() => {
        this.onload({ target: { result: 'data:image/png;base64,source-image' } });
      });
    }
  };
  global.Image = class MockImage {
    set src(value) {
      this._src = value;
      this.width = 1600;
      this.height = 900;
      queueMicrotask(() => this.onload());
    }
  };
  global.document = {
    createElement(tag) {
      assert.equal(tag, 'canvas');
      return {
        width: 0,
        height: 0,
        getContext(type) {
          assert.equal(type, '2d');
          return {
            clearRect() {},
            drawImage() {}
          };
        },
        toDataURL(type, quality) {
          canvasAttempts.push({ width: this.width, height: this.height, type, quality });
          return `data:image/jpeg;base64,${'a'.repeat(120)}`;
        }
      };
    }
  };

  let request = null;
  global.fetch = async (url, options) => {
    request = { url, options, body: JSON.parse(options.body) };
    return {
      ok: true,
      json: async () => ({
        content: JSON.stringify({
          inventory: [{ rawText: '鸡蛋 Eggs', name: '鸡蛋', qty: 1, unit: '盒' }],
          pantry: [],
          review: [],
          ignored: []
        })
      })
    };
  };

  const out = await recognizeReceipt({ type: 'image/png' });
  assert.equal(request.url, '/api/ai-chat');
  assert.equal(request.options.headers.Authorization, undefined);
  assert.equal(request.body.taskType, 'receipt');
  assert.match(request.body.prompt, /小票/);
  assert.match(request.body.imageBase64, /^data:image\/jpeg;base64,/);
  assert.deepEqual(canvasAttempts[0], { width: 896, height: 504, type: 'image/jpeg', quality: 0.68 });
  assert.equal(out.inventory[0].name, '鸡蛋');
});

test('BYOK 模式继续使用用户配置的 apiUrl / apiKey / model', async () => {
  S.save(S.keys.settings, {
    aiProviderMode: 'byok',
    apiUrl: 'https://example.test/v1/chat/completions',
    apiKey: 'user-test-key',
    model: 'user-model'
  });
  let request = null;
  global.fetch = async (url, options) => {
    request = { url, options, body: JSON.parse(options.body) };
    return {
      ok: true,
      json: async () => ({ choices: [{ message: { content: recipeContent('咖喱鸡') } }] })
    };
  };

  const out = await callAiSearchRecipe('咖喱鸡', '鸡肉、土豆');
  assert.equal(out.name, '咖喱鸡');
  assert.equal(request.url, 'https://example.test/v1/chat/completions');
  assert.equal(request.options.headers.Authorization, 'Bearer user-test-key');
  assert.equal(request.body.model, 'user-model');
});

test('BYOK 缺少 API Key 时给出原有友好错误', async () => {
  S.save(S.keys.settings, { aiProviderMode: 'byok', apiKey: '' });

  await assert.rejects(
    () => callAiSearchRecipe('番茄炒蛋', '鸡蛋、番茄'),
    /还没有配置 API Key/
  );
  assert.equal(
    formatAiErrorMessage(new Error('AI 暂不可用：还没有配置 API Key。本地功能仍可正常使用。')),
    'AI 暂不可用：还没有配置 API Key。本地功能仍可正常使用。'
  );
});

test('设置页默认展示内置 AI 服务，并只在 BYOK 区域展示高级字段', () => {
  const settings = read('src/views/settings-view.js');

  assert.match(settings, /使用内置 AI 服务（推荐）/);
  assert.match(settings, /使用自己的 API Key（高级）/);
  assert.match(settings, /const aiProviderMode = s\.aiProviderMode === 'byok' \? 'byok' : 'cloud';/);
  assert.match(settings, /id="cloudAiBox"/);
  assert.match(settings, /id="byokAiBox"/);
  assert.match(settings, /id="cloudAiStatusCard"/);
  assert.match(settings, /id="testCloudAiBtn"/);
  assert.match(settings, /fetch\('\/api\/ai-status', \{ cache: 'no-store' \}\)/);
  assert.match(settings, /textModelConfigured/);
  assert.match(settings, /visionModelConfigured/);
  assert.match(settings, /byokAiBox\.hidden = !isByok;/);
  assert.match(settings, /aiProviderMode: 'byok'/);
});

test('设置页 AI 模式 radio 不继承通用输入框宽度', () => {
  const styles = read('styles.css');

  assert.match(styles, /\.settings-ai-option\s*\{[\s\S]*?grid-template-columns: 22px minmax\(0, 1fr\);/);
  assert.match(styles, /\.settings-ai-option input\[type="radio"\]\s*\{[\s\S]*?width: 18px;/);
  assert.match(styles, /\.settings-ai-option input\[type="radio"\]\s*\{[\s\S]*?max-width: 18px;/);
  assert.match(styles, /\.settings-ai-option input\[type="radio"\]\s*\{[\s\S]*?padding: 0;/);
  assert.match(styles, /\.settings-ai-option input\[type="radio"\]\s*\{[\s\S]*?box-shadow: none;/);
});

test('后端 AI 代理不暴露密钥，并包含长度限制与限流', () => {
  const server = read('server.js');
  const aiChatRoute = server.slice(
    server.indexOf("app.post('/api/ai-chat'"),
    server.indexOf('// AI 解析路由')
  );

  assert.match(server, /app\.post\('\/api\/ai-chat'/);
  assert.match(server, /OPENAI_API_KEY/);
  assert.match(server, /OPENAI_VISION_MODEL/);
  assert.match(server, /DEFAULT_OPENAI_VISION_MODEL = 'meta-llama\/llama-4-scout-17b-16e-instruct'/);
  assert.match(server, /OPENAI_VISION_MODEL = process\.env\.OPENAI_VISION_MODEL \|\| DEFAULT_OPENAI_VISION_MODEL/);
  assert.match(server, /AI_PROMPT_MAX_CHARS = 12000/);
  assert.match(server, /AI_IMAGE_MAX_BASE64_BYTES = 4 \* 1024 \* 1024/);
  assert.match(server, /AI_RATE_LIMIT_MAX = 30/);
  assert.match(server, /x-forwarded-for/);
  assert.match(server, /res\.json\(\{ content \}\)/);
  assert.match(server, /status: safeStatus/);
  assert.match(server, /code,/);
  assert.match(server, /request_too_large/);
  assert.match(server, /bad_json/);
  assert.match(aiChatRoute, /const model = imageBase64 \? OPENAI_VISION_MODEL : OPENAI_MODEL;/);
  assert.match(aiChatRoute, /estimateBase64EncodedBytes\(imageBase64\)/);
  assert.match(aiChatRoute, /sendAiUpstreamError\(res, err\)/);
  assert.doesNotMatch(aiChatRoute, /OPENAI_API_KEY[^\n]*res\.json|res\.json\([^)]*OPENAI_API_KEY/);
  assert.doesNotMatch(aiChatRoute, /err\.response\.data/);
});

test('/api/ai-parse 图片路径同样使用视觉模型', () => {
  const server = read('server.js');
  const aiParseRoute = server.slice(
    server.indexOf("app.post('/api/ai-parse'"),
    server.indexOf('// 静态托管前端')
  );

  assert.match(aiParseRoute, /model: imageBase64 \? OPENAI_VISION_MODEL : OPENAI_MODEL/);
  assert.match(aiParseRoute, /estimateBase64EncodedBytes\(imageBase64\)/);
  assert.match(aiParseRoute, /sendAiUpstreamError\(res, err, 'AI 解析请求失败，请稍后重试。'\)/);
});

test('小票图片会压到 Groq base64 图片限制以内的目标尺寸', () => {
  const ai = read('src/ai.js');

  assert.match(ai, /CLOUD_IMAGE_TARGET_BASE64_BYTES = Math\.floor\(3\.6 \* 1024 \* 1024\)/);
  assert.match(ai, /RECEIPT_IMAGE_COMPRESSION_ATTEMPTS = \[/);
  assert.match(ai, /\{ maxSide: 512, quality: 0\.5 \}/);
  assert.match(ai, /getDataUrlPayloadLength\(dataUrl\) <= CLOUD_IMAGE_TARGET_BASE64_BYTES/);
});
