import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const root = new URL('../ios-native/Kitchen Manager/', import.meta.url);
const projectRoot = new URL('../', import.meta.url);
const read = path => readFileSync(new URL(path, root), 'utf8');
const readProject = path => readFileSync(new URL(path, projectRoot), 'utf8');
const smoke = read('KitchenManager/Synchronization/SyncSmoke.swift');
const coordinator = read('KitchenManager/Synchronization/SyncCoordinator.swift');
const adapter = read('KitchenManager/Synchronization/InventorySyncAdapter.swift');
const persistence = read('KitchenManager/Synchronization/SyncPersistence.swift');
const settings = read('KitchenManager/MainFeatureViews.swift');
const content = read('KitchenManager/ContentView.swift');
const info = read('KitchenManager/Info.plist');
const sharedConfig = read('Config/Shared.xcconfig');
const exampleConfig = read('Config/Local.example.xcconfig');

test('Phase 2A-4 keeps both committed smoke gates disabled', () => {
  for (const value of [sharedConfig, exampleConfig]) {
    assert.match(value, /SYNC_ENABLED\s*=\s*NO/);
    assert.match(value, /SYNC_SMOKE_ENABLED\s*=\s*NO/);
  }
  assert.match(info, /KM_SYNC_SMOKE_ENABLED/);
  assert.match(info, /KM_SYNC_SMOKE_ENVIRONMENT/);
});

test('the smoke is Debug-only and requires explicit development configuration', () => {
  assert.match(smoke, /#if DEBUG/);
  assert.match(smoke, /guard smokeConfiguration\.isSmokeEnabled/);
  assert.match(smoke, /guard smokeConfiguration\.isDevelopmentBuild/);
  assert.match(smoke, /isDevelopmentEnvironment/);
  assert.match(smoke, /APIEnvironment\.current == \.development/);
  assert.match(settings, /if syncSmokeController\.isAvailable/);
  assert.match(settings, /This will create development test data in Supabase/);
});

test('normal application startup, login and inventory UI have no sync run call', () => {
  const normalAppCode = content.replace(/#if DEBUG[\s\S]*?#endif/g, '');
  assert.doesNotMatch(normalAppCode, /SyncCoordinator|runOnce|stageUpsert|stageDelete/);
  assert.doesNotMatch(adapter.replace(/#if DEBUG[\s\S]*?#endif/g, ''), /stageSmokeUpsert/);
});

test('smoke runner restricts one coordinator run to the selected household scope', () => {
  assert.match(smoke, /__sync_smoke_inventory_/);
  assert.match(smoke, /scopes: \[scope\]/);
  assert.match(coordinator, /scopes requestedScopes: Set<SyncScope>\? = nil/);
  assert.match(coordinator, /selectedScopes = availableScopes\.filter/);
  assert.match(coordinator, /selectedScopes\.count == requestedScopes\.count/);
});

test('the smoke only stages inventory lifecycle mutations and retains a conflict until explicit cleanup', () => {
  assert.match(smoke, /adapter\.stageUpsert/);
  assert.match(smoke, /adapter\.stageSmokeUpsert/);
  assert.match(smoke, /adapter\.stageDelete/);
  assert.match(smoke, /discardPendingMutation/);
  assert.match(smoke, /state: \.conflicted/);
  assert.match(adapter, /#if DEBUG[\s\S]*?stageSmokeUpsert[\s\S]*?#endif/);
  assert.match(persistence, /func discardPendingMutation\(id: UUID\) throws/);
});

test('the smoke neither logs credentials nor adds an automatic scheduling mechanism', () => {
  assert.doesNotMatch(smoke, /print\(|debugPrint\(|Authorization|refreshToken|password|service.?role/i);
  assert.doesNotMatch(smoke, /Timer|BGTask|backgroundTask|NotificationCenter/i);
});

test('hosted regression smoke starts feed assertions from a fresh bootstrap cursor', () => {
  const source = readProject('scripts/sync-smoke.mjs');
  assert.match(source, /const householdCursor = householdScope\(before\)\.cursor/);
  assert.match(source, /const personalCursor = personalScope\(before, session\.userId\)\.cursor/);
  assert.match(source, /const expressCursor = householdScope\(bootstrapResult\.body\)\.cursor/);
  assert.doesNotMatch(source, /scopeId=\$\{scope\.id\}&cursor=0&limit=100&entityTypes=inventory_item/);
});
