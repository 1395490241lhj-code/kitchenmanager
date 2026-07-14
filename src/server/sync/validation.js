const { SyncError } = require('./errors');
const {
  ENTITY_TYPES,
  MAX_JSON_DEPTH,
  PROTECTED_FIELDS,
  getEntityDefinition
} = require('./entities');
const { parseCursor, parseVersion } = require('./cursor');
const { isUuid } = require('./stable-id');

const MAX_BATCH_SIZE = 100;
const MAX_SYNC_BODY_BYTES = 1024 * 1024;
const MAX_PULL_LIMIT = 100;

function fail(code, message, status = 400, details) {
  throw new SyncError(code, message, status, { details });
}

function isPlainObject(value) {
  return !!value && typeof value === 'object' && !Array.isArray(value) && Object.getPrototypeOf(value) === Object.prototype;
}

function assertOnlyKeys(value, allowed, context) {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) fail('unknown_field', `${context} 包含不支持的字段。`, 400, { field: key });
  }
}

function jsonByteLength(value) {
  return Buffer.byteLength(JSON.stringify(value), 'utf8');
}

function jsonDepth(value, depth = 0) {
  if (value === null || typeof value !== 'object') return depth;
  const children = Array.isArray(value) ? value : Object.values(value);
  if (!children.length) return depth + 1;
  return Math.max(...children.map(item => jsonDepth(item, depth + 1)));
}

function validateDate(value, fieldName) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) fail('invalid_field', `${fieldName} 必须是 YYYY-MM-DD。`);
  const parsed = new Date(`${value}T00:00:00Z`);
  if (!Number.isFinite(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) {
    fail('invalid_field', `${fieldName} 不是有效日期。`);
  }
  return value;
}

function validateTimestamp(value, fieldName) {
  if (typeof value !== 'string' || !value.includes('T') || !Number.isFinite(Date.parse(value))) {
    fail('invalid_field', `${fieldName} 必须是 ISO 8601 时间。`);
  }
  return new Date(value).toISOString();
}

function validateStringArray(value, rule, fieldName) {
  if (!Array.isArray(value) || value.length > rule.max) fail('invalid_field', `${fieldName} 数量超出限制。`);
  return value.map(item => {
    if (typeof item !== 'string' || item.length > rule.itemMax) fail('invalid_field', `${fieldName} 包含无效文本。`);
    return item.trim();
  });
}

function validateConsumptionItems(value, fieldName) {
  const allowed = new Set([
    'inventoryItemID', 'ingredientName', 'consumedQuantity', 'unit',
    'previousQuantity', 'resultingQuantity'
  ]);
  return value.map((item, index) => {
    if (!isPlainObject(item)) fail('invalid_field', `${fieldName}[${index}] 必须是对象。`);
    assertOnlyKeys(item, allowed, `${fieldName}[${index}]`);
    if (item.inventoryItemID !== undefined && !isUuid(item.inventoryItemID)) fail('invalid_field', 'inventoryItemID 必须是 UUID。');
    if (typeof item.ingredientName !== 'string' || !item.ingredientName.trim() || item.ingredientName.length > 200) {
      fail('invalid_field', 'ingredientName 无效。');
    }
    for (const key of ['consumedQuantity', 'previousQuantity', 'resultingQuantity']) {
      if (!Number.isFinite(item[key])) fail('invalid_field', `${key} 必须是有限数字。`);
    }
    if (typeof item.unit !== 'string' || item.unit.length > 40) fail('invalid_field', 'unit 无效。');
    return { ...item, ingredientName: item.ingredientName.trim(), unit: item.unit.trim() };
  });
}

function validateWeeklyShoppingItems(value, fieldName) {
  const allowed = new Set(['id', 'name', 'quantityText', 'unit', 'reason']);
  return value.map((item, index) => {
    if (!isPlainObject(item)) fail('invalid_field', `${fieldName}[${index}] 必须是对象。`);
    assertOnlyKeys(item, allowed, `${fieldName}[${index}]`);
    if (item.id !== undefined && !isUuid(item.id)) fail('invalid_field', `${fieldName}[${index}].id 必须是 UUID。`);
    if (typeof item.name !== 'string' || !item.name.trim() || item.name.length > 200) fail('invalid_field', '周菜单购物项名称无效。');
    for (const key of ['quantityText', 'unit', 'reason']) {
      if (item[key] !== undefined && item[key] !== null && (typeof item[key] !== 'string' || item[key].length > 1000)) {
        fail('invalid_field', `周菜单购物项 ${key} 无效。`);
      }
    }
    return { ...item, name: item.name.trim() };
  });
}

function validateRecipeSnapshot(value, fieldName) {
  const allowed = new Set([
    'id', 'title', 'ingredients', 'seasonings', 'steps', 'tags', 'cookingTime',
    'difficulty', 'reason', 'source', 'existingRecipeID', 'isSavedToLibrary'
  ]);
  assertOnlyKeys(value, allowed, fieldName);
  for (const key of ['id', 'title', 'difficulty', 'reason', 'source', 'existingRecipeID']) {
    if (value[key] !== undefined && value[key] !== null && (typeof value[key] !== 'string' || value[key].length > 4000)) {
      fail('invalid_field', `${fieldName}.${key} 无效。`);
    }
  }
  for (const key of ['ingredients', 'seasonings', 'steps', 'tags']) {
    if (value[key] !== undefined) {
      if (!Array.isArray(value[key]) || value[key].length > 100 || value[key].some(item => typeof item !== 'string' || item.length > 4000)) {
        fail('invalid_field', `${fieldName}.${key} 无效。`);
      }
    }
  }
  if (value.cookingTime !== undefined && value.cookingTime !== null && !Number.isFinite(value.cookingTime)) {
    fail('invalid_field', `${fieldName}.cookingTime 无效。`);
  }
  if (value.isSavedToLibrary !== undefined && typeof value.isSavedToLibrary !== 'boolean') {
    fail('invalid_field', `${fieldName}.isSavedToLibrary 无效。`);
  }
  return value;
}

function validateJsonValue(value, rule, fieldName, entityType) {
  if (rule.type === 'jsonArray' && !Array.isArray(value)) fail('invalid_field', `${fieldName} 必须是数组。`);
  if (rule.type === 'jsonObject' && !isPlainObject(value)) fail('invalid_field', `${fieldName} 必须是对象。`);
  if (rule.max !== undefined && value.length > rule.max) fail('invalid_field', `${fieldName} 数量超出限制。`);
  if (jsonByteLength(value) > (rule.maxBytes || 256 * 1024)) fail('payload_too_large', `${fieldName} 数据过大。`, 413);
  if (jsonDepth(value) > (rule.maxDepth || MAX_JSON_DEPTH)) fail('invalid_field', `${fieldName} 嵌套过深。`);
  if (entityType === 'consumption_record' && fieldName === 'items') return validateConsumptionItems(value, fieldName);
  if (entityType === 'weekly_meal_plan' && fieldName === 'shoppingItems') return validateWeeklyShoppingItems(value, fieldName);
  if (entityType === 'weekly_meal_plan_item' && fieldName === 'recipeSnapshot') return validateRecipeSnapshot(value, fieldName);
  return value;
}

function validateField(value, rule, fieldName, entityType) {
  if (value === null) {
    if (rule.nullable) return null;
    fail('invalid_field', `${fieldName} 不能为 null。`);
  }
  switch (rule.type) {
    case 'string': {
      if (typeof value !== 'string' || value.length > rule.max) fail('invalid_field', `${fieldName} 文本无效或过长。`);
      const normalized = value.trim();
      if (rule.required && !normalized) fail('missing_field', `${fieldName} 不能为空。`);
      if (rule.enum && !rule.enum.includes(normalized)) fail('invalid_field', `${fieldName} 不在允许范围。`);
      return normalized;
    }
    case 'number':
      if (!Number.isFinite(value)) fail('invalid_field', `${fieldName} 必须是有限数字。`);
      if (rule.min !== undefined && value < rule.min) fail('invalid_field', `${fieldName} 小于最小值。`);
      if (rule.max !== undefined && value > rule.max) fail('invalid_field', `${fieldName} 超过最大值。`);
      return value;
    case 'integer':
      if (!Number.isSafeInteger(value)) fail('invalid_field', `${fieldName} 必须是安全整数。`);
      if (rule.min !== undefined && value < rule.min) fail('invalid_field', `${fieldName} 小于最小值。`);
      if (rule.max !== undefined && value > rule.max) fail('invalid_field', `${fieldName} 超过最大值。`);
      return value;
    case 'boolean':
      if (typeof value !== 'boolean') fail('invalid_field', `${fieldName} 必须是布尔值。`);
      return value;
    case 'date': return validateDate(value, fieldName);
    case 'timestamp': return validateTimestamp(value, fieldName);
    case 'uuid':
      if (!isUuid(value)) fail('invalid_field', `${fieldName} 必须是 UUID。`);
      return value.toLowerCase();
    case 'uuidArray':
      if (!Array.isArray(value) || value.length > rule.max || value.some(item => !isUuid(item))) {
        fail('invalid_field', `${fieldName} 必须是 UUID 数组。`);
      }
      return value.map(item => item.toLowerCase());
    case 'stringArray': return validateStringArray(value, rule, fieldName);
    case 'jsonArray':
    case 'jsonObject': return validateJsonValue(value, rule, fieldName, entityType);
    default: throw new TypeError(`Unsupported validation rule: ${rule.type}`);
  }
}

function validateEntityData(entityType, input) {
  if (!isPlainObject(input)) fail('invalid_data', 'mutation.data 必须是对象。');
  const definition = getEntityDefinition(entityType);
  for (const key of Object.keys(input)) {
    if (PROTECTED_FIELDS.has(key)) fail('protected_field', `不允许客户端设置 ${key}。`);
  }
  assertOnlyKeys(input, new Set(Object.keys(definition.fields)), 'mutation.data');
  if (definition.maxBytes && jsonByteLength(input) > definition.maxBytes) fail('payload_too_large', '实体数据过大。', 413);

  const output = {};
  for (const [fieldName, rule] of Object.entries(definition.fields)) {
    const value = input[fieldName];
    if (value === undefined) {
      if (rule.required) fail('missing_field', `缺少 ${fieldName}。`);
      if ('default' in rule) output[fieldName] = rule.default;
      else if (rule.type.endsWith('Array')) output[fieldName] = [];
      else if (rule.type === 'jsonObject') output[fieldName] = {};
      else output[fieldName] = null;
      continue;
    }
    output[fieldName] = validateField(value, rule, fieldName, entityType);
  }
  return output;
}

function validateMutation(input) {
  if (!isPlainObject(input)) fail('invalid_mutation', 'mutation 必须是对象。');
  assertOnlyKeys(input, new Set([
    'mutationId', 'entityType', 'entityId', 'operation', 'baseVersion', 'clientUpdatedAt', 'data'
  ]), 'mutation');
  if (!isUuid(input.mutationId)) fail('invalid_mutation_id', 'mutationId 必须是 UUID。');
  if (!ENTITY_TYPES.includes(input.entityType)) fail('unsupported_entity_type', '不支持的同步数据类型。');
  if (!isUuid(input.entityId)) fail('invalid_entity_id', 'entityId 必须是 UUID。');
  if (!['upsert', 'delete'].includes(input.operation)) fail('invalid_operation', 'operation 必须是 upsert 或 delete。');
  let baseVersion;
  try { baseVersion = parseVersion(input.baseVersion, { allowNull: true }); } catch { fail('invalid_base_version', 'baseVersion 必须是非负整数。'); }
  const clientUpdatedAt = input.clientUpdatedAt === undefined || input.clientUpdatedAt === null
    ? null
    : validateTimestamp(input.clientUpdatedAt, 'clientUpdatedAt');
  if (input.operation === 'delete') {
    if (input.data !== undefined && (!isPlainObject(input.data) || Object.keys(input.data).length)) {
      fail('invalid_data', 'delete mutation 不接受业务 data。');
    }
    return {
      mutationId: input.mutationId.toLowerCase(), entityType: input.entityType,
      entityId: input.entityId.toLowerCase(), operation: 'delete',
      baseVersion: baseVersion === null ? null : baseVersion.toString(), clientUpdatedAt, data: {}
    };
  }
  return {
    mutationId: input.mutationId.toLowerCase(), entityType: input.entityType,
    entityId: input.entityId.toLowerCase(), operation: 'upsert',
    baseVersion: baseVersion === null ? null : baseVersion.toString(), clientUpdatedAt,
    data: validateEntityData(input.entityType, input.data)
  };
}

function validateScope(scopeType, scopeId) {
  if (!['household', 'user'].includes(scopeType)) {
    fail('invalid_scope_type', 'scopeType 必须是 household 或 user。');
  }
  if (!isUuid(scopeId)) fail('invalid_scope_id', 'scopeId 必须是 UUID。');
  return { scopeType, scopeId: scopeId.toLowerCase() };
}

function validateMutationsRequest(body) {
  if (!isPlainObject(body)) fail('invalid_body', '请求体必须是对象。');
  if (jsonByteLength(body) > MAX_SYNC_BODY_BYTES) fail('batch_too_large', '同步请求体过大。', 413);
  assertOnlyKeys(body, new Set(['scopeType', 'scopeId', 'mutations']), '请求体');
  const scope = validateScope(body.scopeType, body.scopeId);
  if (!Array.isArray(body.mutations) || body.mutations.length < 1) fail('invalid_mutations', 'mutations 不能为空。');
  if (body.mutations.length > MAX_BATCH_SIZE) fail('batch_too_large', `每批最多 ${MAX_BATCH_SIZE} 条 mutation。`, 413);
  const mutations = body.mutations.map(validateMutation);
  if (mutations.some(item => getEntityDefinition(item.entityType).scope !== scope.scopeType)) {
    fail('scope_entity_mismatch', 'mutation entityType 与请求 scope 不匹配。');
  }
  return { ...scope, mutations };
}

function validateChangesQuery(query = {}) {
  assertOnlyKeys(query, new Set(['scopeType', 'scopeId', 'cursor', 'limit', 'entityTypes']), 'query');
  const scope = validateScope(query.scopeType, query.scopeId);
  let cursor;
  try { cursor = parseCursor(query.cursor === undefined ? '0' : query.cursor); } catch { fail('invalid_cursor', 'cursor 必须是有效 BIGINT 十进制字符串。'); }
  const rawLimit = query.limit === undefined ? 100 : String(query.limit);
  if (!/^[1-9]\d*$/.test(rawLimit)) fail('invalid_limit', 'limit 必须是正整数。');
  const limit = Number(rawLimit);
  if (!Number.isSafeInteger(limit) || limit > MAX_PULL_LIMIT) fail('invalid_limit', `limit 最大为 ${MAX_PULL_LIMIT}。`);
  const values = query.entityTypes === undefined || query.entityTypes === ''
    ? []
    : (Array.isArray(query.entityTypes) ? query.entityTypes : String(query.entityTypes).split(','));
  const entityTypes = [...new Set(values.map(value => String(value).trim()).filter(Boolean))];
  if (entityTypes.some(value => !ENTITY_TYPES.includes(value))) fail('unsupported_entity_type', 'entityTypes 包含不支持的数据类型。');
  if (entityTypes.some(value => getEntityDefinition(value).scope !== scope.scopeType)) {
    fail('scope_entity_mismatch', 'entityTypes 与请求 scope 不匹配。');
  }
  return { ...scope, cursor: cursor.toString(), limit, entityTypes };
}

module.exports = {
  MAX_BATCH_SIZE,
  MAX_PULL_LIMIT,
  MAX_SYNC_BODY_BYTES,
  isPlainObject,
  jsonByteLength,
  jsonDepth,
  validateChangesQuery,
  validateEntityData,
  validateMutation,
  validateMutationsRequest,
  validateScope
};
