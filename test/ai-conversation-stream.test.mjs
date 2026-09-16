import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { EventEmitter } from 'node:events';
import path from 'node:path';

const require = createRequire(import.meta.url);
const Module = require('node:module');
const originalLoad = Module._load;
const root = process.cwd();
const serverPath = resolve(root, 'server.js');
const serverModulesDir = resolve(root, 'src/server') + path.sep;
const originalEnv = { ...process.env };

function clearServerRequireCache() {
  delete require.cache[serverPath];
  for (const key of Object.keys(require.cache)) {
    if (key.startsWith(serverModulesDir)) delete require.cache[key];
  }
}

function createExpressMock() {
  function express() {
    const routes = [];
    const app = {
      routes,
      use() {},
      get(routePath, handler) { routes.push({ method: 'GET', path: routePath, handler }); },
      post(routePath, handler) { routes.push({ method: 'POST', path: routePath, handler }); },
      listen() { return { close() {} }; }
    };
    express.latestApp = app;
    return app;
  }
  express.json = () => (_req, _res, next) => { if (typeof next === 'function') next(); };
  express.static = () => (_req, _res, next) => { if (typeof next === 'function') next(); };
  return express;
}

// Loads the real server with express/openai replaced. `streams` is the provider
// seam: one handler per upstream attempt, consumed in order, so no test ever
// reaches Groq or Gemini.
function loadServerWithStreams({ streams = [], env = {} } = {}) {
  const expressMock = createExpressMock();
  const providerCalls = [];
  const pending = [...streams];
  class OpenAIMock {
    constructor(options) {
      this.chat = {
        completions: {
          create: async (payload, requestOptions) => {
            providerCalls.push({ baseURL: options.baseURL, apiKey: options.apiKey, payload, requestOptions });
            const handler = pending.shift();
            if (!handler) throw new Error('unexpected extra provider attempt');
            return handler(payload, requestOptions);
          }
        }
      };
    }
  }
  class APIConnectionTimeoutError extends Error {}
  class APIConnectionError extends Error {}
  OpenAIMock.APIConnectionTimeoutError = APIConnectionTimeoutError;
  OpenAIMock.APIConnectionError = APIConnectionError;

  Module._load = function mockedLoad(request, parent, isMain) {
    if (request === 'express') return expressMock;
    if (request === 'openai') return OpenAIMock;
    return originalLoad.call(this, request, parent, isMain);
  };

  process.env = {
    ...originalEnv,
    NODE_ENV: 'development',
    OPENAI_API_KEY: 'test-groq-key',
    OPENAI_BASE_URL: 'https://api.groq.com/openai/v1',
    OPENAI_MODEL: 'openai/gpt-oss-120b',
    ...env
  };
  clearServerRequireCache();
  require(serverPath);
  return { app: expressMock.latestApp, providerCalls };
}

function createRes() {
  // 带 writableEnded 的 EventEmitter：路由把"响应没写完就 close"当作断开信号，
  // 一个不会发事件、也没有 writableEnded 的裸对象模型不出这个区别。
  return Object.assign(new EventEmitter(), {
    statusCode: 200,
    body: null,
    headers: {},
    chunks: [],
    ended: false,
    writableEnded: false,
    set(name, value) { this.headers[String(name).toLowerCase()] = value; return this; },
    setHeader(name, value) { return this.set(name, value); },
    status(code) { this.statusCode = code; return this; },
    json(payload) { this.body = payload; this.ended = true; this.writableEnded = true; return this; },
    write(chunk) { this.chunks.push(String(chunk)); return true; },
    end(chunk) { if (chunk) this.chunks.push(String(chunk)); this.ended = true; this.writableEnded = true; return this; },
    flushHeaders() { this.flushed = true; }
  });
}

function createReq(body) {
  const req = new EventEmitter();
  req.body = body;
  req.headers = {};
  req.ip = '127.0.0.1';
  req.socket = { remoteAddress: '127.0.0.1' };
  // express.json() 在路由跑起来之前就已经读完了 body，所以处理器看到的请求永远是
  // complete 的。req 'close' 随后就会发出，而那不是断开。
  req.complete = true;
  return req;
}

function findRoute(app, routePath) {
  const route = app.routes.find((item) => item.method === 'POST' && item.path === routePath);
  assert.ok(route, `${routePath} route should be registered`);
  return route;
}

function startPost(app, routePath, body) {
  const route = findRoute(app, routePath);
  const req = createReq(body);
  const res = createRes();
  return { req, res, done: Promise.resolve(route.handler(req, res)) };
}

async function runPost(app, routePath, body) {
  const call = startPost(app, routePath, body);
  await call.done;
  return call.res;
}

function events(res) {
  return res.chunks.join('').split('\n').filter((line) => line.trim()).map((line) => JSON.parse(line));
}

function textChunk(text) {
  return { choices: [{ index: 0, delta: { content: text } }] };
}

function finishChunk(reason) {
  return { choices: [{ index: 0, delta: {}, finish_reason: reason }] };
}

function streamOf(chunks) {
  return async function* stream(_payload, requestOptions) {
    for (const chunk of chunks) {
      if (requestOptions?.signal?.aborted) throw Object.assign(new Error('aborted'), { name: 'AbortError' });
      yield chunk;
    }
  };
}

function transientFailure() {
  return async () => { throw Object.assign(new Error('upstream down'), { status: 503 }); };
}

async function waitFor(predicate, label) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolveTick) => setTimeout(resolveTick, 5));
  }
  throw new Error(`timed out waiting for ${label}`);
}

const VALID_BODY = {
  provider: 'groq',
  messages: [{ role: 'user', content: '今晚想吃清淡一点' }],
  enabledTools: ['read_inventory', 'present_recipe_card'],
  requestID: '6F9619FF-8B86-D011-B42D-00CF4FC964FF'
};

afterEach(() => {
  Module._load = originalLoad;
  process.env = { ...originalEnv };
  clearServerRequireCache();
});

test('/api/ai-conversation 缺少或格式错误的 messages 返回安全 400，且不调用 provider', async () => {
  const { app, providerCalls } = loadServerWithStreams();

  const missing = await runPost(app, '/api/ai-conversation', { provider: 'groq' });
  assert.equal(missing.statusCode, 400);
  assert.equal(missing.body.code, 'invalid_messages');
  assert.equal(missing.body.error, '对话内容无效。');

  const malformed = await runPost(app, '/api/ai-conversation', {
    ...VALID_BODY,
    messages: [{ role: 'wizard', content: 'hi' }]
  });
  assert.equal(malformed.statusCode, 400);
  assert.equal(malformed.body.code, 'invalid_messages');

  assert.equal(providerCalls.length, 0);
});

test('/api/ai-conversation 超长输入返回 413，不调用 provider', async () => {
  const { app, providerCalls } = loadServerWithStreams();

  const tooLong = await runPost(app, '/api/ai-conversation', {
    ...VALID_BODY,
    messages: [{ role: 'user', content: 'x'.repeat(12001) }]
  });
  assert.equal(tooLong.statusCode, 413);
  assert.equal(tooLong.body.code, 'messages_too_large');

  const tooMany = await runPost(app, '/api/ai-conversation', {
    ...VALID_BODY,
    messages: Array.from({ length: 200 }, () => ({ role: 'user', content: 'hi' }))
  });
  assert.equal(tooMany.statusCode, 413);
  assert.equal(tooMany.body.code, 'messages_too_large');

  assert.equal(providerCalls.length, 0);
});

test('/api/ai-conversation 未知工具名返回 400，且从不接受客户端 schema', async () => {
  const { app, providerCalls } = loadServerWithStreams({ streams: [streamOf([textChunk('好')])] });

  const unknown = await runPost(app, '/api/ai-conversation', {
    ...VALID_BODY,
    enabledTools: ['read_inventory', 'delete_everything']
  });
  assert.equal(unknown.statusCode, 400);
  assert.equal(unknown.body.code, 'unsupported_tool');
  assert.equal(providerCalls.length, 0);

  const schemaAttempt = await runPost(app, '/api/ai-conversation', {
    ...VALID_BODY,
    enabledTools: [{ name: 'read_inventory', parameters: { type: 'object' } }]
  });
  assert.equal(schemaAttempt.statusCode, 400);
  assert.equal(schemaAttempt.body.code, 'unsupported_tool');
  assert.equal(providerCalls.length, 0);
});

test('/api/ai-conversation 正常流先发 text_delta 再发 completed，并使用服务端自有工具 schema', async () => {
  const { app, providerCalls } = loadServerWithStreams({
    streams: [streamOf([textChunk('我先'), textChunk('看看库存。'), finishChunk('stop')])]
  });

  const res = await runPost(app, '/api/ai-conversation', VALID_BODY);

  assert.equal(res.statusCode, 200);
  assert.equal(res.headers['content-type'], 'application/x-ndjson; charset=utf-8');
  assert.equal(res.headers['cache-control'], 'no-store');
  assert.deepEqual(events(res), [
    { type: 'text_delta', text: '我先' },
    { type: 'text_delta', text: '看看库存。' },
    { type: 'completed', finishReason: 'stop' }
  ]);
  assert.ok(res.chunks.join('').endsWith('\n'));

  const sentTools = providerCalls[0].payload.tools;
  assert.equal(sentTools.length, 2);
  assert.deepEqual(sentTools.map((tool) => tool.function.name), ['read_inventory', 'present_recipe_card']);
  assert.equal(typeof sentTools[0].function.parameters, 'object');
  assert.equal(providerCalls[0].payload.stream, true);
});

test('/api/ai-conversation 把分片的工具参数聚合成唯一一个完整 tool_call', async () => {
  const fragments = [
    { choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: 'call_1', type: 'function', function: { name: 'read_planner_week', arguments: '{"weekS' } }] } }] },
    { choices: [{ index: 0, delta: { tool_calls: [{ index: 0, function: { arguments: 'tart":"2026-' } }] } }] },
    { choices: [{ index: 0, delta: { tool_calls: [{ index: 0, function: { arguments: '09-14"}' } }] } }] },
    finishChunk('tool_calls')
  ];
  const { app } = loadServerWithStreams({ streams: [streamOf(fragments)] });

  const res = await runPost(app, '/api/ai-conversation', {
    ...VALID_BODY,
    enabledTools: ['read_planner_week']
  });

  const emitted = events(res);
  const toolCalls = emitted.filter((event) => event.type === 'tool_call');
  assert.equal(toolCalls.length, 1);
  assert.deepEqual(toolCalls[0], {
    type: 'tool_call',
    id: 'call_1',
    name: 'read_planner_week',
    arguments: { weekStart: '2026-09-14' }
  });
  assert.deepEqual(emitted.at(-1), { type: 'completed', finishReason: 'tool_calls' });
});

test('/api/ai-conversation 永不透出 reasoning 等模型内部内容', async () => {
  const chunks = [
    { choices: [{ index: 0, delta: { reasoning: 'SECRET-CHAIN-OF-THOUGHT', content: '好的' } }] },
    { choices: [{ index: 0, delta: { reasoning_content: 'SECRET-CHAIN-OF-THOUGHT' } }] },
    finishChunk('stop')
  ];
  const { app } = loadServerWithStreams({ streams: [streamOf(chunks)] });

  const res = await runPost(app, '/api/ai-conversation', VALID_BODY);

  const raw = res.chunks.join('');
  assert.equal(raw.includes('SECRET-CHAIN-OF-THOUGHT'), false);
  assert.equal(raw.includes('reasoning'), false);
  assert.deepEqual(events(res), [
    { type: 'text_delta', text: '好的' },
    { type: 'completed', finishReason: 'stop' }
  ]);
});

// 这个 provider 会把推理写在 content 里（非流式路径在 cleanAiChatContent 剥掉）。
// 流式下标签会被切在 delta 边界上，按片正则是看不见的。
test('/api/ai-conversation 剥掉 content 里的 <think> 推理，即使标签跨 delta 被切开', async () => {
  const chunks = [
    textChunk('好的，'),
    textChunk('<thi'),
    textChunk('nk>SECRET-INLINE-REASONING 第一段'),
    textChunk('SECRET-INLINE-REASONING 第二段</thi'),
    textChunk('nk>今晚吃'),
    textChunk('番茄炒蛋。'),
    finishChunk('stop')
  ];
  const { app } = loadServerWithStreams({ streams: [streamOf(chunks)] });

  const res = await runPost(app, '/api/ai-conversation', VALID_BODY);

  const raw = res_text(res);
  assert.equal(raw.includes('SECRET-INLINE-REASONING'), false);
  assert.equal(raw.includes('think'), false);
  const emitted = events(res);
  assert.equal(emitted.filter((event) => event.type === 'text_delta').map((event) => event.text).join(''), '好的，今晚吃番茄炒蛋。');
  assert.deepEqual(emitted.at(-1), { type: 'completed', finishReason: 'stop' });
});

test('/api/ai-conversation 流在未闭合的 <think> 里结束时丢弃尾巴而不是发出推理', async () => {
  const chunks = [
    textChunk('先说结论。'),
    textChunk('<think>SECRET-INLINE-REASONING 还没说完'),
    finishChunk('stop')
  ];
  const { app } = loadServerWithStreams({ streams: [streamOf(chunks)] });

  const res = await runPost(app, '/api/ai-conversation', VALID_BODY);

  assert.equal(res_text(res).includes('SECRET-INLINE-REASONING'), false);
  assert.deepEqual(events(res), [
    { type: 'text_delta', text: '先说结论。' },
    { type: 'completed', finishReason: 'stop' }
  ]);
});

// 过滤器按下标在原缓冲区上切片，所以"小写副本长度不变"必须真的成立。
// toLowerCase() 会把 U+0130 'İ' 变成两个码元，下标随即错位：正文被吃掉，
// 严重时还会漏出半个标签。标签全是 ASCII，所以只折叠 ASCII 大写字母。
// 错位只在 İ 和标签落进同一个缓冲区时才发生：下标是在小写副本上算的，却用回
// 原缓冲区切片。İ 必须和标签同片，否则正文早就被发出去、缓冲区已经清空了。
test('/api/ai-conversation 正文里的 İ 与 <think> 同片时不会错位吃掉内容', async () => {
  const chunks = [
    textChunk('İa<think>SECRET-INLINE-REASONING</think>可见结尾。'),
    finishChunk('stop')
  ];
  const { app } = loadServerWithStreams({ streams: [streamOf(chunks)] });

  const res = await runPost(app, '/api/ai-conversation', VALID_BODY);

  const raw = res_text(res);
  assert.equal(raw.includes('SECRET-INLINE-REASONING'), false);
  assert.equal(raw.includes('think'), false);
  assert.equal(
    events(res)
      .filter((event) => event.type === 'text_delta')
      .map((event) => event.text)
      .join(''),
    'İa可见结尾。'
  );
});

// 同样的错位，İ 在推理体里：闭合标签的下标会算多，把后面的正文吃掉一个字。
test('/api/ai-conversation 推理体里的 İ 不会吃掉后面的正文', async () => {
  const chunks = [
    textChunk('<think>推İ理</think>可见结尾。'),
    finishChunk('stop')
  ];
  const { app } = loadServerWithStreams({ streams: [streamOf(chunks)] });

  const res = await runPost(app, '/api/ai-conversation', VALID_BODY);

  assert.equal(
    events(res)
      .filter((event) => event.type === 'text_delta')
      .map((event) => event.text)
      .join(''),
    '可见结尾。'
  );
});

// 留住"可能是标签前缀"的尾巴，不能把普通的 < 当成标签吞掉。
test('/api/ai-conversation 不会吞掉以 < 开头的普通正文', async () => {
  const chunks = [
    textChunk('温度 <'),
    textChunk(' 180 度时'),
    textChunk('，用 <thi'),
    textChunk('s 这种写法也没事。'),
    finishChunk('stop')
  ];
  const { app } = loadServerWithStreams({ streams: [streamOf(chunks)] });

  const res = await runPost(app, '/api/ai-conversation', VALID_BODY);

  assert.equal(
    events(res)
      .filter((event) => event.type === 'text_delta')
      .map((event) => event.text)
      .join(''),
    '温度 < 180 度时，用 <this 这种写法也没事。'
  );
});

test('/api/ai-conversation 模型调用本次未开启的工具时按 unsupported_tool 结束', async () => {
  const chunks = [
    { choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: 'call_9', type: 'function', function: { name: 'read_special_plan', arguments: '{"planID":"p1"}' } }] } }] },
    finishChunk('tool_calls')
  ];
  const { app } = loadServerWithStreams({ streams: [streamOf(chunks)] });

  // read_special_plan 是合法工具名，但这次请求没有开启它。
  const res = await runPost(app, '/api/ai-conversation', { ...VALID_BODY, enabledTools: ['read_inventory'] });

  assert.deepEqual(events(res), [
    { type: 'error', code: 'unsupported_tool', message: '不支持的 AI 工具。' }
  ]);
});

test('/api/ai-conversation 工具参数解析不出对象时只发 invalid_tool_arguments，不发 completed', async () => {
  const truncated = [
    { choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: 'call_1', type: 'function', function: { name: 'read_planner_week', arguments: '{"weekStart":' } }] } }] },
    finishChunk('tool_calls')
  ];
  const { app } = loadServerWithStreams({ streams: [streamOf(truncated)] });

  const res = await runPost(app, '/api/ai-conversation', { ...VALID_BODY, enabledTools: ['read_planner_week'] });

  assert.deepEqual(events(res), [
    { type: 'error', code: 'invalid_tool_arguments', message: 'AI 返回的操作参数无法解析。' }
  ]);
});

test('/api/ai-conversation 超长工具参数按 invalid_tool_arguments 截断处理', async () => {
  const huge = `{"query":"${'x'.repeat(20100)}"}`;
  const chunks = [
    { choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: 'call_1', type: 'function', function: { name: 'resolve_recipe', arguments: huge } }] } }] },
    finishChunk('tool_calls')
  ];
  const { app } = loadServerWithStreams({ streams: [streamOf(chunks)] });

  const res = await runPost(app, '/api/ai-conversation', { ...VALID_BODY, enabledTools: ['resolve_recipe'] });

  assert.deepEqual(events(res), [
    { type: 'error', code: 'invalid_tool_arguments', message: 'AI 返回的操作参数无法解析。' }
  ]);
});

test('/api/ai-conversation 接受回声的 tool_calls：对象或字符串参数都规范化成字符串下发', async () => {
  const { app, providerCalls } = loadServerWithStreams({
    streams: [streamOf([textChunk('本周计划如下。'), finishChunk('stop')])]
  });

  const res = await runPost(app, '/api/ai-conversation', {
    ...VALID_BODY,
    enabledTools: ['read_planner_week'],
    messages: [
      { role: 'user', content: '这周怎么安排' },
      {
        role: 'assistant',
        tool_calls: [
          { id: 'call_1', type: 'function', function: { name: 'read_planner_week', arguments: { weekStart: '2026-09-14' } } },
          { id: 'call_2', type: 'function', function: { name: 'read_inventory', arguments: '{"expiringOnly":true}' } }
        ]
      },
      { role: 'tool', tool_call_id: 'call_1', content: '{"meals":[]}' },
      { role: 'tool', tool_call_id: 'call_2', content: '{"items":[]}' }
    ]
  });

  assert.equal(res.statusCode, 200);
  const sentMessages = providerCalls[0].payload.messages;
  assert.equal(sentMessages.length, 4);
  assert.deepEqual(sentMessages[1].tool_calls, [
    { id: 'call_1', type: 'function', function: { name: 'read_planner_week', arguments: '{"weekStart":"2026-09-14"}' } },
    { id: 'call_2', type: 'function', function: { name: 'read_inventory', arguments: '{"expiringOnly":true}' } }
  ]);
  assert.deepEqual(sentMessages[2], { role: 'tool', content: '{"meals":[]}', tool_call_id: 'call_1' });
});

test('/api/ai-conversation 回声的 tool_calls 任何一处不合法都是 400，绝不静默清空参数', async () => {
  const { app, providerCalls } = loadServerWithStreams();
  const assistant = (toolCalls) => ({
    ...VALID_BODY,
    messages: [{ role: 'user', content: '这周怎么安排' }, { role: 'assistant', tool_calls: toolCalls }]
  });
  const call = (overrides) => ({
    id: 'call_1',
    type: 'function',
    function: { name: 'read_planner_week', arguments: '{"weekStart":"2026-09-14"}', ...overrides }
  });

  const rejected = [
    ['数字参数', assistant([call({ arguments: 42 })])],
    ['null 参数', assistant([call({ arguments: null })])],
    ['缺少参数字段', assistant([{ id: 'call_1', type: 'function', function: { name: 'read_planner_week' } }])],
    ['数组参数', assistant([call({ arguments: ['weekStart'] })])],
    ['解析不出对象的字符串参数', assistant([call({ arguments: '{"weekStart":' })])],
    ['解析成数组的字符串参数', assistant([call({ arguments: '[1,2]' })])],
    ['白名单外的工具名', assistant([call({ name: 'drop_database' })])],
    ['缺少 id', assistant([{ type: 'function', function: { name: 'read_planner_week', arguments: '{}' } }])],
    ['空 tool_calls', assistant([])],
    ['tool_calls 不是数组', assistant({ id: 'call_1' })],
    ['tool 消息缺少 tool_call_id', {
      ...VALID_BODY,
      messages: [{ role: 'user', content: 'hi' }, { role: 'tool', content: '{}' }]
    }]
  ];

  for (const [label, body] of rejected) {
    const res = await runPost(app, '/api/ai-conversation', body);
    assert.equal(res.statusCode, 400, label);
    assert.equal(res.body.code, 'invalid_messages', label);
  }
  assert.equal(providerCalls.length, 0);

  // 空字符串参数是上游对无参工具的写法，按 {} 接受。
  const { app: emptyApp, providerCalls: emptyCalls } = loadServerWithStreams({
    streams: [streamOf([textChunk('好'), finishChunk('stop')])]
  });
  const accepted = await runPost(emptyApp, '/api/ai-conversation', assistant([call({ name: 'read_tonight_plan', arguments: '' })]));
  assert.equal(accepted.statusCode, 200);
  assert.equal(emptyCalls[0].payload.messages[1].tool_calls[0].function.arguments, '{}');
});

test('/api/ai-conversation 限流在任何 provider 工作之前生效', async () => {
  const { app, providerCalls } = loadServerWithStreams();

  let last = null;
  for (let attempt = 0; attempt < 31; attempt += 1) {
    last = await runPost(app, '/api/ai-conversation', { provider: 'groq' });
  }

  assert.equal(last.statusCode, 429);
  assert.equal(last.body.code, 'rate_limited');
  assert.ok(Number.isInteger(last.body.retryAfterSeconds) && last.body.retryAfterSeconds > 0);
  assert.equal(providerCalls.length, 0);

  const blockedValid = await runPost(app, '/api/ai-conversation', VALID_BODY);
  assert.equal(blockedValid.statusCode, 429);
  assert.equal(providerCalls.length, 0);
});

test('/api/ai-conversation 客户端断开会中止上游生成', async () => {
  let observedSignal = null;
  let releaseGate;
  const gate = new Promise((resolveGate) => { releaseGate = resolveGate; });
  const stream = async function* handler(_payload, requestOptions) {
    observedSignal = requestOptions.signal;
    yield textChunk('第一段');
    await gate;
    if (requestOptions.signal?.aborted) throw Object.assign(new Error('aborted'), { name: 'AbortError' });
    yield textChunk('不应出现');
    yield finishChunk('stop');
  };
  const { app } = loadServerWithStreams({ streams: [stream] });

  const call = startPost(app, '/api/ai-conversation', VALID_BODY);
  await waitFor(() => call.res.chunks.length >= 1, 'first delta');
  // 断开信号是"响应还没写完就 close"，不是请求体读完。
  call.res.emit('close');
  releaseGate();
  await call.done;

  assert.ok(observedSignal, 'provider call should receive an abort signal');
  assert.equal(observedSignal.aborted, true);
  assert.equal(res_text(call.res).includes('不应出现'), false);
});

function res_text(res) {
  return res.chunks.join('');
}

test('/api/ai-conversation 请求体读完引发的 req close 不会中止仍在进行的生成', async () => {
  let observedSignal = null;
  let releaseGate;
  const gate = new Promise((resolveGate) => { releaseGate = resolveGate; });
  const stream = async function* handler(_payload, requestOptions) {
    observedSignal = requestOptions.signal;
    yield textChunk('第一段');
    await gate;
    if (requestOptions.signal?.aborted) throw Object.assign(new Error('aborted'), { name: 'AbortError' });
    yield textChunk('后半段');
    yield finishChunk('stop');
  };
  const { app } = loadServerWithStreams({ streams: [stream] });

  const call = startPost(app, '/api/ai-conversation', VALID_BODY);
  await waitFor(() => call.res.chunks.length >= 1, 'first delta');
  // 正常 POST 的 body 一读完 req 就 close（complete === true），响应还开着。
  call.req.emit('close');
  releaseGate();
  await call.done;

  assert.equal(observedSignal.aborted, false);
  assert.ok(res_text(call.res).includes('后半段'));
  assert.deepEqual(events(call.res).at(-1), { type: 'completed', finishReason: 'stop' });
});

test('/api/ai-conversation 自然结束后的 close 不会中止已完成的响应', async () => {
  let observedSignal = null;
  const stream = async function* handler(_payload, requestOptions) {
    observedSignal = requestOptions.signal;
    yield textChunk('完成');
    yield finishChunk('stop');
  };
  const { app } = loadServerWithStreams({ streams: [stream] });

  const call = startPost(app, '/api/ai-conversation', VALID_BODY);
  await call.done;
  call.req.emit('close');

  assert.equal(observedSignal.aborted, false);
  assert.deepEqual(events(call.res).at(-1), { type: 'completed', finishReason: 'stop' });
});

test('/api/ai-conversation 首个可见事件之前的瞬时失败可以切换 provider', async () => {
  const { app, providerCalls } = loadServerWithStreams({
    env: { AI_CHAT_PROVIDER: 'gemini', GEMINI_API_KEY: 'test-gemini-key' },
    streams: [transientFailure(), streamOf([textChunk('备用回答'), finishChunk('stop')])]
  });

  const res = await runPost(app, '/api/ai-conversation', { ...VALID_BODY, provider: 'gemini' });

  assert.equal(providerCalls.length, 2);
  assert.deepEqual(events(res), [
    { type: 'text_delta', text: '备用回答' },
    { type: 'completed', finishReason: 'stop' }
  ]);
});

test('/api/ai-conversation 首个 delta 之后的失败只发 error，不再启动第二个 provider', async () => {
  const stream = async function* handler() {
    yield textChunk('已经可见');
    throw Object.assign(new Error('upstream down'), { status: 503 });
  };
  const { app, providerCalls } = loadServerWithStreams({
    env: { AI_CHAT_PROVIDER: 'gemini', GEMINI_API_KEY: 'test-gemini-key' },
    streams: [stream, streamOf([textChunk('绝不应被调用'), finishChunk('stop')])]
  });

  const res = await runPost(app, '/api/ai-conversation', { ...VALID_BODY, provider: 'gemini' });

  assert.equal(providerCalls.length, 1);
  assert.deepEqual(events(res), [
    { type: 'text_delta', text: '已经可见' },
    { type: 'error', code: 'provider_unavailable', message: 'AI 服务暂时不可用。' }
  ]);
  assert.equal(res_text(res).includes('upstream down'), false);
});

test('/api/ai-conversation 未配置 provider 密钥时返回安全 503', async () => {
  const { app, providerCalls } = loadServerWithStreams({ env: { OPENAI_API_KEY: '' } });

  const res = await runPost(app, '/api/ai-conversation', VALID_BODY);

  assert.equal(res.statusCode, 503);
  assert.equal(res.body.code, 'missing_api_key');
  assert.equal(res.body.error, 'AI 服务暂时不可用。');
  assert.equal(providerCalls.length, 0);
});

// provider 契约：缺省用配置的云端默认，显式只接受 gemini/groq，其他显式取值 400。
// 用 apiKey 区分实际被调用的 provider——它就是这次调用真正用出去的凭据。
function loadForProviderContract() {
  return loadServerWithStreams({
    env: { AI_CHAT_PROVIDER: 'gemini', GEMINI_API_KEY: 'test-gemini-key' },
    streams: [streamOf([textChunk('好'), finishChunk('stop')])]
  });
}

test('/api/ai-conversation 省略或留空 provider 时用配置的云端默认', async () => {
  const omitted = loadForProviderContract();
  const body = { ...VALID_BODY };
  delete body.provider;
  const res = await runPost(omitted.app, '/api/ai-conversation', body);
  assert.equal(res.statusCode, 200);
  assert.equal(omitted.providerCalls.length, 1);
  assert.equal(omitted.providerCalls[0].apiKey, 'test-gemini-key');

  const blank = loadForProviderContract();
  const blankRes = await runPost(blank.app, '/api/ai-conversation', { ...VALID_BODY, provider: '  ' });
  assert.equal(blankRes.statusCode, 200);
  assert.equal(blank.providerCalls[0].apiKey, 'test-gemini-key');
});

test('/api/ai-conversation 显式 gemini 与 groq 都按所选 provider 调用', async () => {
  const gemini = loadForProviderContract();
  const geminiRes = await runPost(gemini.app, '/api/ai-conversation', { ...VALID_BODY, provider: 'gemini' });
  assert.equal(geminiRes.statusCode, 200);
  assert.equal(gemini.providerCalls[0].apiKey, 'test-gemini-key');

  const groq = loadForProviderContract();
  const groqRes = await runPost(groq.app, '/api/ai-conversation', { ...VALID_BODY, provider: 'GROQ' });
  assert.equal(groqRes.statusCode, 200);
  assert.equal(groq.providerCalls[0].apiKey, 'test-groq-key');
});

test('/api/ai-conversation 显式 apple 或任意未知 provider 是 400，绝不静默改道云端', async () => {
  for (const provider of ['apple', 'apple-local', 'openai', '本地']) {
    const { app, providerCalls } = loadForProviderContract();
    const res = await runPost(app, '/api/ai-conversation', { ...VALID_BODY, provider });
    assert.equal(res.statusCode, 400, `provider=${provider} 必须被拒绝`);
    assert.equal(res.body.code, 'unsupported_provider');
    assert.equal(res.body.error, '不支持的 AI 服务商。');
    // 被拒绝的 provider 不允许产生任何上游工作。
    assert.equal(providerCalls.length, 0, `provider=${provider} 不应调用上游`);
  }
});

// 信任边界上不能靠 String() 强转：String(['gemini']) === 'gemini'，一个数组就能
// 冒充成合法取值混过白名单。
test('/api/ai-conversation 非字符串 provider 是 400，不会被强转成合法取值', async () => {
  for (const provider of [['gemini'], { name: 'gemini' }, 7, true]) {
    const { app, providerCalls } = loadForProviderContract();
    const res = await runPost(app, '/api/ai-conversation', { ...VALID_BODY, provider });
    assert.equal(res.statusCode, 400, `provider=${JSON.stringify(provider)} 必须被拒绝`);
    assert.equal(res.body.code, 'unsupported_provider');
    assert.equal(providerCalls.length, 0);
  }
});

test('ai-conversation 服务只承认计划中的十二个工具名', async () => {
  loadServerWithStreams();
  const { CONVERSATION_TOOL_NAMES, selectConversationTools } = require(resolve(root, 'src/server/services/ai-conversation.js'));

  assert.deepEqual(CONVERSATION_TOOL_NAMES, [
    'read_inventory',
    'read_tonight_plan',
    'read_planner_week',
    'read_special_plan',
    'resolve_recipe',
    'present_recipe_card',
    'present_context_result',
    'propose_add_recipe_to_tonight',
    'propose_replace_planned_meal',
    'propose_apply_planner_changes',
    'propose_special_plan_changes',
    'propose_add_shopping_items'
  ]);

  const selected = selectConversationTools(['read_inventory']);
  assert.equal(selected.length, 1);
  assert.equal(selected[0].type, 'function');
  assert.equal(selected[0].function.name, 'read_inventory');
  assert.throws(() => selectConversationTools(['read_inventory', 'rm_rf']), (err) => err.publicStatus === 400 && err.publicCode === 'unsupported_tool');
});
