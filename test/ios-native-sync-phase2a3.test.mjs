import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const root = new URL('../ios-native/Kitchen Manager/', import.meta.url);
const read = path => readFileSync(new URL(path, root), 'utf8');
const models = read('KitchenManager/Synchronization/SyncModels.swift');
const persistenceModels = read('KitchenManager/Synchronization/SyncPersistenceModels.swift');
const coordinator = read('KitchenManager/Synchronization/SyncCoordinator.swift');
const coordinatorCode = coordinator.replace(/\/\/.*$/gm, '');
const transport = read('KitchenManager/Synchronization/SyncTransport.swift');
const adapter = read('KitchenManager/Synchronization/InventorySyncAdapter.swift');
const content = read('KitchenManager/ContentView.swift');
const sharedConfig = read('Config/Shared.xcconfig');
const exampleConfig = read('Config/Local.example.xcconfig');
const ignore = read('../../.gitignore');

test('Phase 2A-3 keeps sync disabled in committed and example iOS configuration', () => {
  assert.match(sharedConfig, /SYNC_ENABLED\s*=\s*NO/);
  assert.match(exampleConfig, /SYNC_ENABLED\s*=\s*NO/);
  assert.match(coordinator, /guard configuration\.isEnabled/);
  assert.match(coordinator, /return \.disabled/);
});

test('sync coordinator is not wired into startup, login, timers, or background tasks', () => {
  assert.doesNotMatch(content, /SyncCoordinator|runOnce|\/api\/sync\//);
  assert.doesNotMatch(coordinatorCode, /Timer|BGTask|backgroundTask|AuthStore|NotificationCenter/);
});

test('cursor and entity contract preserves decimal strings and all Phase 2A entity names', () => {
  assert.match(models, /struct SyncCursorValue/);
  assert.match(models, /let rawValue: String/);
  for (const name of [
    'inventory_item', 'shopping_item', 'today_plan', 'consumption_record',
    'weekly_meal_plan', 'weekly_meal_plan_item', 'user_recipe',
    'recipe_favorite', 'frequent_recipe'
  ]) assert.match(models, new RegExp(`"${name}"`));
});

test('sync persistence records metadata, pending queue and per-scope cursor without credentials', () => {
  for (const model of ['SyncMetadataRecord', 'PendingMutationRecord', 'SyncCursorRecord']) {
    assert.match(persistenceModels, new RegExp(`final class ${model}`));
  }
  assert.doesNotMatch(persistenceModels, /accessToken|refreshToken|Authorization|password|service.?role/i);
});

test('transport reuses APIClient and limits Phase 2A-3 pull to inventory proof of concept', () => {
  assert.match(transport, /private let client: APIClient/);
  assert.match(transport, /api\/sync\/bootstrap/);
  assert.match(transport, /api\/sync\/changes/);
  assert.match(transport, /api\/sync\/mutations/);
  assert.match(transport, /SyncEntityType\.inventoryItem\.rawValue/);
  assert.doesNotMatch(transport, /print\(|debugPrint\(|logger/);
});

test('inventory adapter is explicit and existing inventory writes remain untouched', () => {
  assert.match(adapter, /func stageUpsert/);
  assert.match(adapter, /func stageDelete/);
  assert.match(adapter, /func applyRemote/);
  assert.doesNotMatch(content, /stageUpsert|stageDelete|applyRemote/);
});

test('local credential files remain ignored', () => {
  assert.match(ignore, /Config\/Local\.xcconfig/);
  assert.doesNotMatch(sharedConfig + exampleConfig, /service.?role|database.?password|access.?token|refresh.?token/i);
});
