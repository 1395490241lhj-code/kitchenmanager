/*
 * src/server/services/ai-conversation.js —— Kitchen AI 对话流的服务端契约：
 * 固定的十二个工具名与它们**由服务端持有**的 JSON Schema、请求体校验、NDJSON 事件写出。
 *
 * 客户端只发工具名。Schema 永远不从请求体读取：一个能自带 schema 的客户端等于
 * 让模型自己定义可调用的能力面，这条路由不提供这种入口。
 */
const { AI_PROMPT_MAX_CHARS, AI_CHAT_PROVIDER, normalizeAiProvider } = require('../config');
const { createPublicApiError } = require('./ai-client');

// 一次请求 = 一个 provider step。历史 + 本轮上下文 + 工具结果都由客户端带上来，
// 所以条数上限按"一段可用对话"给，超过就是客户端在无界增长。
const MAX_CONVERSATION_MESSAGES = 60;
const CONVERSATION_MESSAGE_ROLES = new Set(['system', 'user', 'assistant', 'tool']);

const RECIPE_PAYLOAD_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    recipeID: { type: 'string', description: '已存在菜谱的规范 id；新生成的菜谱留空。' },
    title: { type: 'string' },
    ingredients: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          item: { type: 'string' },
          qty: { type: 'string' },
          unit: { type: 'string' }
        },
        required: ['item']
      }
    },
    steps: { type: 'array', items: { type: 'string' } },
    reason: { type: 'string', description: '为什么推荐这道菜，一句话。' }
  },
  required: ['title']
};

function objectSchema(properties, required = []) {
  return { type: 'object', additionalProperties: false, properties, required };
}

// 名称与参数形状对齐 iOS 侧已实现的 AIPlannerMealChange / AISpecialPlanDishChange /
// AIShoppingItemProposal，解释器不需要再做一层字段翻译。
const TOOL_DEFINITIONS = Object.freeze({
  read_inventory: {
    description: '读取当前库存概览与临期食材。',
    parameters: objectSchema({
      expiringOnly: { type: 'boolean', description: '只要临期部分时为 true。' }
    })
  },
  read_tonight_plan: {
    description: '读取今晚的普通用餐计划。',
    parameters: objectSchema({})
  },
  read_planner_week: {
    description: '读取指定一周的普通用餐计划。',
    parameters: objectSchema({
      weekStart: { type: 'string', description: '该周起始日，格式 YYYY-MM-DD。' }
    }, ['weekStart'])
  },
  read_special_plan: {
    description: '读取一个聚餐计划及其菜单。',
    parameters: objectSchema({
      planID: { type: 'string', description: '聚餐计划 id。' }
    }, ['planID'])
  },
  resolve_recipe: {
    description: '把一个菜名解析为库里的规范菜谱。',
    parameters: objectSchema({
      query: { type: 'string' },
      recipeID: { type: 'string' }
    }, ['query'])
  },
  present_recipe_card: {
    description: '以菜谱卡片展示一道菜。',
    parameters: objectSchema({
      recipe: RECIPE_PAYLOAD_SCHEMA
    }, ['recipe'])
  },
  present_context_result: {
    description: '以结构化结果展示一次上下文读取。',
    parameters: objectSchema({
      kind: { type: 'string', enum: ['inventory', 'tonightPlan', 'plannerWeek', 'specialPlan', 'recipe'] },
      title: { type: 'string' },
      rows: {
        type: 'array',
        items: objectSchema({ label: { type: 'string' }, value: { type: 'string' } }, ['label', 'value'])
      }
    }, ['title', 'rows'])
  },
  propose_add_recipe_to_tonight: {
    description: '提议把一道菜加入今晚计划。执行前由客户端校验并确认。',
    parameters: objectSchema({
      recipe: RECIPE_PAYLOAD_SCHEMA,
      plannedServings: { type: 'integer' }
    }, ['recipe'])
  },
  propose_replace_planned_meal: {
    description: '提议替换一条已排的普通用餐。',
    parameters: objectSchema({
      planID: { type: 'string' },
      replacement: RECIPE_PAYLOAD_SCHEMA,
      plannedServings: { type: 'integer' }
    }, ['planID', 'replacement'])
  },
  propose_apply_planner_changes: {
    description: '提议一批普通周计划改动。',
    parameters: objectSchema({
      changes: {
        type: 'array',
        items: objectSchema({
          planID: { type: 'string' },
          replacement: RECIPE_PAYLOAD_SCHEMA,
          plannedServings: { type: 'integer' }
        }, ['planID', 'replacement'])
      }
    }, ['changes'])
  },
  propose_special_plan_changes: {
    description: '提议一批聚餐菜单改动。',
    parameters: objectSchema({
      planID: { type: 'string' },
      changes: {
        type: 'array',
        items: objectSchema({
          dishID: { type: 'string' },
          replacement: RECIPE_PAYLOAD_SCHEMA
        }, ['dishID', 'replacement'])
      }
    }, ['planID', 'changes'])
  },
  propose_add_shopping_items: {
    description: '提议把少量食材加入购物清单。',
    parameters: objectSchema({
      items: {
        type: 'array',
        items: objectSchema({
          name: { type: 'string' },
          quantity: { type: 'number' },
          unit: { type: 'string' },
          remark: { type: 'string' }
        }, ['name', 'quantity', 'unit'])
      }
    }, ['items'])
  }
});

const CONVERSATION_TOOL_NAMES = Object.freeze(Object.keys(TOOL_DEFINITIONS));

function isConversationTool(name) {
  return Object.prototype.hasOwnProperty.call(TOOL_DEFINITIONS, String(name || ''));
}

// 客户端只允许开关已有工具，不能定义工具。任何非白名单名字（以及任何试图直接
// 传 schema 对象的写法）都是 400。
function selectConversationTools(enabledNames) {
  if (enabledNames === undefined || enabledNames === null) return [];
  if (!Array.isArray(enabledNames)) throw createPublicApiError(400, '不支持的 AI 工具。', 'unsupported_tool');
  const unknown = enabledNames.filter((name) => typeof name !== 'string' || !isConversationTool(name));
  if (unknown.length) throw createPublicApiError(400, '不支持的 AI 工具。', 'unsupported_tool');
  return enabledNames.map((name) => ({
    type: 'function',
    function: {
      name,
      description: TOOL_DEFINITIONS[name].description,
      parameters: TOOL_DEFINITIONS[name].parameters
    }
  }));
}

function invalidMessages() {
  return createPublicApiError(400, '对话内容无效。', 'invalid_messages');
}

function messagesTooLarge() {
  return createPublicApiError(413, '对话内容过长。', 'messages_too_large');
}

function normalizeMessageContent(content) {
  if (typeof content === 'string') return content;
  // provider 侧的分段文本内容；只取文本，其他部件一律丢弃。
  if (Array.isArray(content)) {
    return content.map((part) => {
      if (typeof part === 'string') return part;
      return part && typeof part.text === 'string' ? part.text : '';
    }).join('');
  }
  return null;
}

// 工具调用参数的线上契约（Task 6 客户端按这个实现）：
//   · 服务端**发出**的 tool_call.arguments 永远是一个 JSON 对象；
//   · 服务端**接受**回声时，对象和它的 JSON 字符串都可以，两者都必须表示一个
//     普通 JSON 对象；空字符串按 {} 处理（上游对无参工具就是这么发的）。
//   · 其他任何形态（数字、布尔、null、数组、解析不出对象的字符串、缺字段）一律
//     400。把它悄悄当成空参数，等于让模型看到一份自己没说过的历史。
// 送往 provider 时统一规范化成字符串，因为 OpenAI 兼容接口只接受字符串。
function normalizeToolCallArguments(raw) {
  if (typeof raw === 'string') {
    const text = raw.trim();
    if (!text) return '{}';
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch (_) {
      throw invalidMessages();
    }
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw invalidMessages();
    return text;
  }
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) return JSON.stringify(raw);
  throw invalidMessages();
}

// 只重建已知字段，绝不透传请求体里的任意键。
function normalizeAssistantToolCalls(rawToolCalls) {
  if (rawToolCalls === undefined || rawToolCalls === null) return null;
  if (!Array.isArray(rawToolCalls) || !rawToolCalls.length) throw invalidMessages();
  return rawToolCalls.map((call) => {
    const id = typeof call?.id === 'string' ? call.id.trim() : '';
    const name = typeof call?.function?.name === 'string' ? call.function.name.trim() : '';
    if (!id || !isConversationTool(name)) throw invalidMessages();
    return { id, type: 'function', function: { name, arguments: normalizeToolCallArguments(call?.function?.arguments) } };
  });
}

function normalizeConversationMessages(rawMessages) {
  if (!Array.isArray(rawMessages) || !rawMessages.length) throw invalidMessages();
  if (rawMessages.length > MAX_CONVERSATION_MESSAGES) throw messagesTooLarge();

  let totalChars = 0;
  const messages = rawMessages.map((raw) => {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw invalidMessages();
    const role = typeof raw.role === 'string' ? raw.role.trim() : '';
    if (!CONVERSATION_MESSAGE_ROLES.has(role)) throw invalidMessages();
    const content = normalizeMessageContent(raw.content);
    const toolCalls = role === 'assistant' ? normalizeAssistantToolCalls(raw.tool_calls) : null;
    if (content === null && !toolCalls) throw invalidMessages();

    const message = { role };
    if (content !== null) message.content = content;
    totalChars += content ? content.length : 0;
    if (toolCalls) {
      message.tool_calls = toolCalls;
      totalChars += toolCalls.reduce((sum, call) => sum + call.function.arguments.length, 0);
    }
    if (role === 'tool') {
      const toolCallId = typeof raw.tool_call_id === 'string' ? raw.tool_call_id.trim() : '';
      if (!toolCallId) throw invalidMessages();
      message.tool_call_id = toolCallId;
    }
    return message;
  });

  if (totalChars > AI_PROMPT_MAX_CHARS) throw messagesTooLarge();
  return messages;
}

// provider 是显式选择，不是提示。缺省走全局云端默认；显式的 gemini/groq 照办；
// 其他任何显式取值一律 400，绝不悄悄回落到云端——一个明确选了 Apple 的客户端
// 被静默改道成云端，等于在用户不知情的情况下把对话送出设备。
const SUPPORTED_CONVERSATION_PROVIDERS = new Set(['gemini', 'groq']);

function normalizeConversationProvider(rawProvider) {
  // 信任边界上不做类型强转：String(['gemini']) 会变成 'gemini'，让一个数组冒充
  // 合法取值。不是字符串就是畸形请求，直接拒。
  if (rawProvider !== undefined && rawProvider !== null && typeof rawProvider !== 'string') {
    throw createPublicApiError(400, '不支持的 AI 服务商。', 'unsupported_provider');
  }
  const requested = (rawProvider || '').trim().toLowerCase();
  if (!requested) return AI_CHAT_PROVIDER;
  if (!SUPPORTED_CONVERSATION_PROVIDERS.has(requested)) {
    throw createPublicApiError(400, '不支持的 AI 服务商。', 'unsupported_provider');
  }
  return normalizeAiProvider(requested);
}

function normalizeConversationRequest(body) {
  const source = body && typeof body === 'object' ? body : {};
  const provider = normalizeConversationProvider(source.provider);
  // 请求体里的 requestID 只服务于客户端自己的关联，服务端不需要它：日志字段是
  // 白名单制，不接受这个名字，把它带进来只会变成一个被静默丢弃的死字段。
  return {
    provider,
    messages: normalizeConversationMessages(source.messages),
    tools: selectConversationTools(source.enabledTools)
  };
}

// 流内错误的用户可见文案。上游错误文本、状态码与 provider 诊断永远不进入这里。
const STREAM_ERROR_COPY = Object.freeze({
  provider_unavailable: 'AI 服务暂时不可用。',
  invalid_tool_arguments: 'AI 返回的操作参数无法解析。',
  unsupported_tool: '不支持的 AI 工具。'
});

function streamErrorEvent(code) {
  const safeCode = Object.prototype.hasOwnProperty.call(STREAM_ERROR_COPY, code) ? code : 'provider_unavailable';
  return { type: 'error', code: safeCode, message: STREAM_ERROR_COPY[safeCode] };
}

function writeConversationEvent(res, event) {
  res.write(`${JSON.stringify(event)}\n`);
}

module.exports = {
  MAX_CONVERSATION_MESSAGES,
  CONVERSATION_TOOL_NAMES,
  TOOL_DEFINITIONS,
  isConversationTool,
  selectConversationTools,
  normalizeConversationRequest,
  streamErrorEvent,
  writeConversationEvent
};
