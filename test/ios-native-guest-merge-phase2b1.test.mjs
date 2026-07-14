import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const root = new URL('../ios-native/Kitchen Manager/', import.meta.url);
const read = path => readFileSync(new URL(path, root), 'utf8');
const models = read('KitchenManager/Synchronization/GuestMergeModels.swift');
const planner = read('KitchenManager/Synchronization/InventoryMergePlanner.swift');
const controller = read('KitchenManager/Synchronization/GuestMergeController.swift');
const views = read('KitchenManager/GuestMergeViews.swift');
const authStore = read('KitchenManager/Authentication/AuthStore.swift');
const accountViews = read('KitchenManager/Authentication/AccountViews.swift');
const content = read('KitchenManager/ContentView.swift');
const info = read('KitchenManager/Info.plist');
const sharedConfig = read('Config/Shared.xcconfig');
const exampleConfig = read('Config/Local.example.xcconfig');
const syncCoordinator = read('KitchenManager/Synchronization/SyncCoordinator.swift');

test('Phase 2B keeps INVENTORY_SYNC_ENABLED disabled by default, independent of SYNC_ENABLED', () => {
  for (const value of [sharedConfig, exampleConfig]) {
    assert.match(value, /SYNC_ENABLED\s*=\s*NO/);
    assert.match(value, /INVENTORY_SYNC_ENABLED\s*=\s*NO/);
  }
  assert.match(info, /KM_INVENTORY_SYNC_ENABLED/);
});

test('Phase 2B-1 only ever plans/uploads inventory_item, never another entity type', () => {
  // GuestDatasetSummary legitimately *counts* other modules read-only for
  // display context (spec: "其他模块只显示存在数量，不上传"); this checks
  // that no SyncEntityType outside inventoryItem is ever referenced when
  // staging a mutation or building a plan/candidate.
  assert.doesNotMatch(planner, /SyncEntityType\.(shoppingItem|todayPlan|weeklyMealPlan|weeklyMealPlanItem|userRecipe|recipeFavorite|frequentRecipe)/);
  assert.doesNotMatch(controller, /SyncEntityType\.(shoppingItem|todayPlan|weeklyMealPlan|weeklyMealPlanItem|userRecipe|recipeFavorite|frequentRecipe)/);
  assert.match(controller, /entityType: \.inventoryItem/);
});

test('the merge feature never auto-uploads: preview never creates a mutation, only confirmMerge does', () => {
  assert.doesNotMatch(planner, /stageUpsert|stageDelete|PendingMutation|sendMutations/);
  const previewSection = controller.slice(
    controller.indexOf('func preparePreview'),
    controller.indexOf('func resolveConflict')
  );
  assert.doesNotMatch(previewSection, /stageUpsert|stageDelete|runOnce/);
  assert.match(controller, /func confirmMerge/);
  assert.match(controller, /adapter\.stageUpsert/);
});

test('upload and rollback only use the existing SyncCoordinator / InventorySyncAdapter / ExpressSyncTransport — no second client', () => {
  assert.match(controller, /InventorySyncAdapter\(persistence: persistence\)/);
  assert.match(controller, /SyncCoordinator\(configuration: configuration, persistence: persistence, transport: transport\)/);
  assert.match(controller, /ExpressSyncTransport\(tokenProvider: provider\)/);
  assert.doesNotMatch(controller, /URLSession\(|class.*Transport.*: SyncTransport(?!.*ExpressSyncTransport)/);
});

test('confirmMerge builds its own scoped SyncConfiguration(isEnabled: true) and never reads or writes the global SYNC_ENABLED flag file', () => {
  assert.match(controller, /SyncConfiguration\(isEnabled: true\)/);
  assert.doesNotMatch(controller, /SyncConfiguration\.load\(/);
  assert.doesNotMatch(controller, /KM_SYNC_ENABLED/);
});

test('conflicts are only resolved by explicit user choice, never automatically', () => {
  assert.match(models, /enum InventoryMergeConflictChoice/);
  assert.match(models, /case keepLocal/);
  assert.match(models, /case keepRemote/);
  assert.match(models, /case keepBoth/);
  assert.match(models, /func applyingChoice/);
  assert.doesNotMatch(planner, /userChoice = \.keep/);
});

test('rollback is scoped to only this session\'s own created records, and uses soft delete via stageDelete', () => {
  const rollbackSection = controller.slice(controller.indexOf('func rollback'));
  assert.match(rollbackSection, /current\.createdEntityIds/);
  assert.match(rollbackSection, /adapter\.stageDelete/);
  assert.doesNotMatch(rollbackSection, /deleteAll|physically|DELETE FROM/i);
});

test('merge sessions are bound to (userId, householdId, entityType), never a bare device-shared key', () => {
  assert.match(models, /static func uniqueKey\(userId: UUID, householdId: UUID, entityType: SyncEntityType\)/);
  assert.match(models, /let userId: UUID/);
  assert.match(models, /let householdId: UUID/);
});

test('the Guest merge prompt is wired into the account page, gated by the feature flag, and never auto-runs at App startup or login', () => {
  assert.match(accountViews, /GuestMergePromptView/);
  assert.match(views, /controller\.isFeatureEnabled/);
  const normalAppCode = content.replace(/#if DEBUG[\s\S]*?#endif/g, '');
  assert.doesNotMatch(normalAppCode, /GuestMergeController\(\)\.(?:confirmMerge|preparePreview)/);
  assert.doesNotMatch(authStore, /guestMergeController|confirmMerge/i);
});

test('the merge flow never logs or embeds tokens, passwords, or full JWTs', () => {
  assert.doesNotMatch(controller, /print\(|debugPrint\(/);
  // GuestMergeModels.swift's doc comments legitimately *discuss* the word
  // "password" while explaining what is never stored; check actual code
  // (non-comment lines) never assigns or logs one.
  const codeLines = models.split('\n').filter(line => !line.trim().startsWith('//') && !line.trim().startsWith('///'));
  assert.doesNotMatch(codeLines.join('\n'), /password/i);
  assert.doesNotMatch(controller, /\bpassword\b/i);
});

test('does not weaken Phase 2A-4 safety: SyncCoordinator push/pull still hard-restrict to inventory_item only', () => {
  assert.match(syncCoordinator, /pending\.allSatisfy\(\{ \$0\.entityType == \.inventoryItem \}\)/);
  assert.match(syncCoordinator, /response\.changes\.allSatisfy\(\{ \$0\.entityType == \.inventoryItem \}\)/);
});

test('Guest inventory detection is read-only: no SwiftData/network calls in the detector', () => {
  const detectorSection = planner.slice(planner.indexOf('enum GuestDatasetDetector'));
  assert.doesNotMatch(detectorSection, /FetchDescriptor|URLSession|await/);
});

test('touch targets for merge actions are declared at least 44pt', () => {
  assert.match(views, /minHeight: 44/);
});
