const { SyncError } = require('./errors');

const MAX_RECIPE_ITEMS = 100;
const MAX_RECIPE_STEPS = 100;
const MAX_RECIPE_TAGS = 20;
const MAX_SNAPSHOT_BYTES = 256 * 1024;
const MAX_JSON_DEPTH = 6;

function field(type, options = {}) { return Object.freeze({ type, ...options }); }

const common = {
  string: (max, options = {}) => field('string', { max, ...options }),
  number: (options = {}) => field('number', options),
  integer: (options = {}) => field('integer', options),
  boolean: (options = {}) => field('boolean', options),
  date: (options = {}) => field('date', options),
  timestamp: (options = {}) => field('timestamp', options),
  uuidArray: (max = 100) => field('uuidArray', { max }),
  stringArray: (max, itemMax) => field('stringArray', { max, itemMax }),
  jsonArray: (max, options = {}) => field('jsonArray', { max, ...options }),
  jsonObject: (options = {}) => field('jsonObject', options)
};

const ENTITY_DEFINITIONS = Object.freeze({
  inventory_item: {
    scope: 'household',
    fields: {
      name: common.string(200, { required: true }), normalizedName: common.string(200, { required: true }),
      quantity: common.number({ nullable: true }), unit: common.string(40, { default: '' }),
      purchaseDate: common.date({ nullable: true }), expiryDate: common.date({ nullable: true }),
      shelfLifeDays: common.integer({ nullable: true, min: 0, max: 36500 }), kind: common.string(40, { nullable: true }),
      stockStatus: common.string(40, { nullable: true }), isFrozen: common.boolean({ default: false }),
      dryPrep: common.string(500, { nullable: true }), gear: common.string(40, { nullable: true }),
      unitType: common.string(40, { nullable: true }), outOfStockAt: common.timestamp({ nullable: true }),
      cookedCount: common.integer({ min: 0, max: 1000000, default: 0 }), lastCookedAt: common.timestamp({ nullable: true }),
      isStaple: common.boolean({ default: false }), lowStockThreshold: common.number({ nullable: true }),
      defaultRestockQuantity: common.number({ nullable: true }), autoSuggestRestock: common.boolean({ default: false }),
      stapleNote: common.string(1000, { nullable: true }), stapleCategory: common.string(100, { nullable: true }),
      stapleTrackingMode: common.string(20, { enum: ['quantity', 'status'], default: 'quantity' }),
      stapleAvailabilityStatus: common.string(20, { enum: ['available', 'low', 'missing'], default: 'available' }),
      sortOrder: common.integer({ min: -1000000, max: 1000000, default: 0 })
    }
  },
  shopping_item: {
    scope: 'household',
    fields: {
      name: common.string(200, { required: true }), normalizedName: common.string(200, { required: true }),
      quantity: common.number({ nullable: true }), quantityText: common.string(100, { nullable: true }),
      unit: common.string(40, { default: '' }), source: common.string(120, { default: '手动' }),
      sourceDetail: common.string(500, { nullable: true }), isDone: common.boolean({ default: false }),
      stockedIn: common.boolean({ default: false }), stockedInAt: common.timestamp({ nullable: true }),
      completedAt: common.timestamp({ nullable: true }), remark: common.string(1000, { nullable: true }),
      sortOrder: common.integer({ min: -1000000, max: 1000000, default: 0 })
    }
  },
  today_plan: {
    scope: 'household',
    fields: {
      recipeId: common.string(300, { nullable: true }), recipeName: common.string(300, { required: true }),
      plannedDate: common.date({ required: true }), servings: common.integer({ min: 1, max: 100, default: 1 }),
      isCooked: common.boolean({ default: false }), cookedAt: common.timestamp({ nullable: true }),
      sortOrder: common.integer({ min: -1000000, max: 1000000, default: 0 })
    }
  },
  consumption_record: {
    scope: 'household',
    fields: {
      occurredAt: common.timestamp({ required: true }), recipeId: common.string(300, { nullable: true }),
      recipeName: common.string(300, { default: '' }), planIds: common.uuidArray(100),
      items: common.jsonArray(100, { maxBytes: MAX_SNAPSHOT_BYTES, maxDepth: 4 }),
      isUndone: common.boolean({ default: false }), sortOrder: common.integer({ min: -1000000, max: 1000000, default: 0 })
    }
  },
  weekly_meal_plan: {
    scope: 'household',
    fields: {
      weekStart: common.date({ required: true }), servings: common.integer({ min: 1, max: 100, default: 1 }),
      summary: common.string(4000, { nullable: true }),
      shoppingItems: common.jsonArray(200, { maxBytes: MAX_SNAPSHOT_BYTES, maxDepth: 4 }),
      sourceSchemaVersion: common.integer({ min: 1, max: 1000, default: 1 })
    }
  },
  weekly_meal_plan_item: {
    scope: 'household',
    fields: {
      planId: field('uuid', { required: true }), dayIndex: common.integer({ min: 0, max: 6, required: true }),
      mealIndex: common.integer({ min: 0, max: 100, required: true }), mealTitle: common.string(300, { nullable: true }),
      recipeId: common.string(300, { nullable: true }), recipeTitle: common.string(300, { required: true }),
      recipeSnapshot: common.jsonObject({ maxBytes: MAX_SNAPSHOT_BYTES, maxDepth: MAX_JSON_DEPTH }),
      reason: common.string(2000, { nullable: true }), source: common.string(100, { nullable: true }),
      isSavedToLibrary: common.boolean({ default: false }), sortOrder: common.integer({ min: -1000000, max: 1000000, default: 0 })
    }
  },
  user_recipe: {
    scope: 'household',
    maxBytes: MAX_SNAPSHOT_BYTES,
    fields: {
      title: common.string(300, { required: true }), tags: common.stringArray(MAX_RECIPE_TAGS, 100),
      ingredients: common.stringArray(MAX_RECIPE_ITEMS, 500), seasonings: common.stringArray(MAX_RECIPE_ITEMS, 500),
      steps: common.stringArray(MAX_RECIPE_STEPS, 4000), cookingTimeMinutes: common.integer({ nullable: true, min: 0, max: 100000 }),
      difficulty: common.string(100, { nullable: true }), sourcePlatform: common.string(100, { nullable: true }),
      sourceOriginalURL: common.string(2048, { nullable: true }), sourceCanonicalURL: common.string(2048, { nullable: true }),
      sourceImportedAt: common.timestamp({ nullable: true }), sourceTitle: common.string(500, { nullable: true }),
      sourceAuthor: common.string(300, { nullable: true }), contentFingerprint: common.string(256, { nullable: true }),
      sortOrder: common.integer({ min: -1000000, max: 1000000, default: 0 })
    }
  },
  recipe_favorite: {
    scope: 'user',
    fields: { recipeId: common.string(300, { required: true }) }
  },
  frequent_recipe: {
    scope: 'user',
    fields: { recipeId: common.string(300, { required: true }) }
  }
});

const ENTITY_TYPES = Object.freeze(Object.keys(ENTITY_DEFINITIONS));
const PROTECTED_FIELDS = new Set([
  'id', 'entityId', 'userId', 'user_id', 'householdId', 'household_id',
  'version', 'createdAt', 'created_at', 'updatedAt', 'updated_at',
  'deletedAt', 'deleted_at', 'createdBy', 'created_by', 'updatedBy', 'updated_by'
]);

const DB_FIELD_NAMES = Object.freeze({
  normalizedName: 'normalized_name', purchaseDate: 'purchase_date', expiryDate: 'expiry_date',
  shelfLifeDays: 'shelf_life_days', stockStatus: 'stock_status', isFrozen: 'is_frozen', dryPrep: 'dry_prep',
  unitType: 'unit_type', outOfStockAt: 'out_of_stock_at', cookedCount: 'cooked_count', lastCookedAt: 'last_cooked_at',
  isStaple: 'is_staple', lowStockThreshold: 'low_stock_threshold', defaultRestockQuantity: 'default_restock_quantity',
  autoSuggestRestock: 'auto_suggest_restock', stapleNote: 'staple_note', stapleCategory: 'staple_category',
  stapleTrackingMode: 'staple_tracking_mode', stapleAvailabilityStatus: 'staple_availability_status', sortOrder: 'sort_order',
  quantityText: 'quantity_text', sourceDetail: 'source_detail', isDone: 'is_done', stockedIn: 'stocked_in',
  stockedInAt: 'stocked_in_at', completedAt: 'completed_at', recipeId: 'recipe_id', recipeName: 'recipe_name',
  plannedDate: 'planned_date', isCooked: 'is_cooked', cookedAt: 'cooked_at', occurredAt: 'occurred_at',
  planIds: 'plan_ids', isUndone: 'is_undone', weekStart: 'week_start', shoppingItems: 'shopping_items',
  sourceSchemaVersion: 'source_schema_version', planId: 'plan_id', dayIndex: 'day_index', mealIndex: 'meal_index',
  mealTitle: 'meal_title', recipeTitle: 'recipe_title', recipeSnapshot: 'recipe_snapshot',
  isSavedToLibrary: 'is_saved_to_library', cookingTimeMinutes: 'cooking_time_minutes',
  sourcePlatform: 'source_platform', sourceOriginalURL: 'source_original_url', sourceCanonicalURL: 'source_canonical_url',
  sourceImportedAt: 'source_imported_at', sourceTitle: 'source_title', sourceAuthor: 'source_author',
  contentFingerprint: 'content_fingerprint'
});

function getEntityDefinition(entityType) {
  const definition = ENTITY_DEFINITIONS[entityType];
  if (!definition) throw new SyncError('unsupported_entity_type', '不支持的同步数据类型。', 400);
  return definition;
}

function toDatabaseData(entityType, data) {
  getEntityDefinition(entityType);
  return Object.fromEntries(Object.entries(data).map(([key, value]) => [DB_FIELD_NAMES[key] || key, value]));
}

function fromDatabaseRecord(entityType, record) {
  if (!record || typeof record !== 'object') return record;
  const definition = getEntityDefinition(entityType);
  const reverse = new Map(Object.entries(DB_FIELD_NAMES).map(([client, database]) => [database, client]));
  const result = {};
  for (const [key, value] of Object.entries(record)) {
    if (['household_id', 'user_id', 'created_by', 'updated_by'].includes(key)) continue;
    if (key === 'id') { result.id = value; continue; }
    if (key === 'version') { result.version = String(value); continue; }
    if (key === 'created_at') { result.createdAt = value; continue; }
    if (key === 'updated_at') { result.updatedAt = value; continue; }
    if (key === 'deleted_at') { result.deletedAt = value; continue; }
    const clientKey = reverse.get(key) || key;
    if (definition.fields[clientKey]) result[clientKey] = value;
  }
  return result;
}

module.exports = {
  DB_FIELD_NAMES,
  ENTITY_DEFINITIONS,
  ENTITY_TYPES,
  MAX_JSON_DEPTH,
  MAX_RECIPE_ITEMS,
  MAX_RECIPE_STEPS,
  MAX_RECIPE_TAGS,
  MAX_SNAPSHOT_BYTES,
  PROTECTED_FIELDS,
  fromDatabaseRecord,
  getEntityDefinition,
  toDatabaseData
};
