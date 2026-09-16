// /api/ai-conversation 的断开语义只能在真实 HTTP + 真实 Express 生命周期上验证。
// EventEmitter mock 不模拟 IncomingMessage：它不知道 express.json() 读完 body 之后
// req 就会 close（req.complete === true，响应还开着），所以一条"请求体读完就 abort"
// 的实现能在 mock 下全绿。这里起一个临时端口的真服务器，发真请求。
// provider 仍然走模块 seam，不打真上游。
import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import path from 'node:path';
import http from 'node:http';

const require = createRequire(import.meta.url);
const Module = require('node:module');
const realExpress = require('express');
const originalLoad = Module._load;
const originalWrite = http.ServerResponse.prototype.write;
const root = process.cwd();
const serverPath = path.resolve(root, 'server.js');
const serverModulesDir = path.resolve(root, 'src/server') + path.sep;
const originalEnv = { ...process.env };

let runningServer = null;
let responseWrites = [];
// 断言失败会跳过测试体后面的 releaseGate()，把 provider 生成器永远挂在门上，
// 整个文件就从"失败"变成"卡死"。所有闸门在这里统一放掉。
const pendingGates = [];

function gate() {
  let release;
  const waiter = new Promise((resolveGate) => { release = resolveGate; });
  pendingGates.push(release);
  return { waiter, release };
}

function clearServerRequireCache() {
  delete require.cache[serverPath];
  for (const key of Object.keys(require.cache)) {
    if (key.startsWith(serverModulesDir)) delete require.cache[key];
  }
}

// 记录服务端真正写出去的每一个 chunk。客户端断开之后"有没有写"在客户端是观察不到的，
// 只能在这一层看。
function spyOnResponseWrites() {
  responseWrites = [];
  http.ServerResponse.prototype.write = function write(chunk, ...rest) {
    if (chunk) responseWrites.push(String(chunk));
    return originalWrite.call(this, chunk, ...rest);
  };
}

// 真 express，只在 listen 上挂一个钩子拿到 http.Server（server.js 不导出它），
// 端口用 0 由内核分配。
async function startRealServer({ streams = [], env = {} } = {}) {
  let captured = null;
  function expressWrapper(...args) {
    const app = realExpress(...args);
    const realListen = app.listen.bind(app);
    app.listen = (...listenArgs) => { captured = realListen(...listenArgs); return captured; };
    return app;
  }
  expressWrapper.json = realExpress.json;
  expressWrapper.static = realExpress.static;

  const providerCalls = [];
  const pending = [...streams];
  class OpenAIMock {
    constructor(options) {
      this.chat = {
        completions: {
          create: async (payload, requestOptions) => {
            providerCalls.push({ apiKey: options.apiKey, payload, requestOptions });
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
    if (request === 'express') return expressWrapper;
    if (request === 'openai') return OpenAIMock;
    return originalLoad.call(this, request, parent, isMain);
  };

  process.env = {
    ...originalEnv,
    NODE_ENV: 'development',
    PORT: '0',
    OPENAI_API_KEY: 'test-groq-key',
    OPENAI_BASE_URL: 'https://api.groq.com/openai/v1',
    OPENAI_MODEL: 'openai/gpt-oss-120b',
    ...env
  };
  spyOnResponseWrites();
  clearServerRequireCache();
  require(serverPath);

  assert.ok(captured, 'server.js should have called app.listen');
  runningServer = captured;
  if (!captured.listening) {
    await new Promise((resolveListening, rejectListening) => {
      captured.once('listening', resolveListening);
      captured.once('error', rejectListening);
    });
  }
  return { port: captured.address().port, providerCalls };
}

afterEach(async () => {
  while (pendingGates.length) pendingGates.pop()();
  await new Promise((r) => setTimeout(r, 10));
  http.ServerResponse.prototype.write = originalWrite;
  if (runningServer) {
    runningServer.closeAllConnections?.();
    await new Promise((resolveClose) => runningServer.close(resolveClose));
    runningServer = null;
  }
  Module._load = originalLoad;
  process.env = { ...originalEnv };
  clearServerRequireCache();
});

function textChunk(text) {
  return { choices: [{ index: 0, delta: { content: text } }] };
}

function finishChunk(reason) {
  return { choices: [{ index: 0, delta: {}, finish_reason: reason }] };
}

const VALID_BODY = {
  provider: 'groq',
  messages: [{ role: 'user', content: '今晚想吃清淡一点' }],
  enabledTools: ['read_inventory']
};

// 发一个真请求，body 一次写完（和 express.json() 的正常情况一致）。
function postConversation(port, body) {
  const payload = Buffer.from(JSON.stringify(body));
  const request = http.request({
    port,
    host: '127.0.0.1',
    method: 'POST',
    path: '/api/ai-conversation',
    headers: { 'Content-Type': 'application/json', 'Content-Length': payload.length }
  });
  const state = { request, received: '', firstChunk: null, ended: false };
  state.firstChunk = new Promise((resolveFirst) => {
    state.response = new Promise((resolveResponse, rejectResponse) => {
      request.on('error', (err) => { if (err?.code !== 'ECONNRESET') rejectResponse(err); });
      request.on('response', (res) => {
        state.statusCode = res.statusCode;
        res.setEncoding('utf8');
        res.on('data', (chunk) => { state.received += chunk; resolveFirst(chunk); });
        res.on('end', () => { state.ended = true; resolveResponse(state.received); });
        res.on('error', () => { resolveResponse(state.received); });
      });
    });
  });
  request.end(payload);
  return state;
}

function events(raw) {
  return raw.split('\n').filter((line) => line.trim()).map((line) => JSON.parse(line));
}

async function ticks(count = 5) {
  for (let index = 0; index < count; index += 1) await new Promise((r) => setTimeout(r, 4));
}

async function waitFor(predicate, label) {
  for (let attempt = 0; attempt < 250; attempt += 1) {
    if (predicate()) return;
    await new Promise((r) => setTimeout(r, 5));
  }
  throw new Error(`timed out waiting for ${label}`);
}

// 超时是断言的一部分：一个把"请求体读完"当断开的实现会在第一个事件之前就掐掉流，
// 客户端永远收不到数据——那是卡死，不是失败。给 node:test 一个上限，卡死照样报错。
test('真实 HTTP：请求体读完、生成仍在进行时不会中止上游，流正常走完', { timeout: 15000 }, async () => {
  let observedSignal = null;
  let abortedAtResume = null;
  const generationGate = gate();
  const stream = async function* handler(_payload, requestOptions) {
    observedSignal = requestOptions.signal;
    yield textChunk('第一段');
    await generationGate.waiter;
    abortedAtResume = requestOptions.signal.aborted;
    yield textChunk('后半段');
    yield finishChunk('stop');
  };

  const { port } = await startRealServer({ streams: [stream] });
  const call = postConversation(port, VALID_BODY);
  await call.firstChunk;
  // body 早就读完了（express.json() 在路由之前读完），req 'close' 已经发生过；
  // 再给几轮事件循环，让任何"读完就 abort"的实现暴露出来。
  await ticks();

  assert.equal(observedSignal.aborted, false, '正常请求不应中止上游');
  generationGate.release();
  const raw = await call.response;

  assert.equal(call.statusCode, 200);
  assert.equal(abortedAtResume, false);
  assert.equal(observedSignal.aborted, false);
  assert.deepEqual(events(raw), [
    { type: 'text_delta', text: '第一段' },
    { type: 'text_delta', text: '后半段' },
    { type: 'completed', finishReason: 'stop' }
  ]);
});

test('真实 HTTP：流式响应进行中客户端断开会中止上游，之后的内容一个字都不写出', { timeout: 15000 }, async () => {
  let observedSignal = null;
  let resolveGeneratorDone;
  const generationGate = gate();
  const generatorDone = new Promise((resolveDone) => { resolveGeneratorDone = resolveDone; });
  const stream = async function* handler(_payload, requestOptions) {
    try {
      observedSignal = requestOptions.signal;
      yield textChunk('第一段');
      await generationGate.waiter;
      // 故意不看 signal：要证明的是路由自己不再写，而不是 provider 自己停了。
      yield textChunk('不应出现');
      yield finishChunk('stop');
    } finally {
      resolveGeneratorDone();
    }
  };

  const { port } = await startRealServer({ streams: [stream] });
  const call = postConversation(port, VALID_BODY);
  await call.firstChunk;
  call.request.destroy();

  await waitFor(() => observedSignal?.aborted === true, 'upstream abort after client disconnect');
  generationGate.release();
  await generatorDone;
  await ticks();

  assert.equal(observedSignal.aborted, true);
  assert.ok(responseWrites.some((chunk) => chunk.includes('第一段')), '断开前的内容应当已经写出');
  assert.equal(responseWrites.some((chunk) => chunk.includes('不应出现')), false, '断开之后不得再写出任何 provider 内容');
});
