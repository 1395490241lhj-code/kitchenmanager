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
const mainFeatureViews = read('KitchenManager/MainFeatureViews.swift');

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
  // AuthStore's own code (excluding doc comments, which legitimately *refer*
  // to GuestMergeController/confirmMerge while documenting the access-token
  // safety contract) must never itself call into the Guest merge feature.
  const authStoreCodeLines = authStore.split('\n').filter(line => !line.trim().startsWith('//') && !line.trim().startsWith('///'));
  assert.doesNotMatch(authStoreCodeLines.join('\n'), /guestMergeController|confirmMerge/i);
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

test('no View ever calls AuthStore.currentAccessToken() directly — only AuthStoreCredentialProvider may', () => {
  assert.doesNotMatch(views, /currentAccessToken/);
  assert.doesNotMatch(accountViews, /currentAccessToken/);
  assert.doesNotMatch(content, /currentAccessToken/);
  // GuestMergeController itself must route every token read through the one
  // provider type, never call the accessor directly from confirmMerge/rollback.
  const confirmSection = controller.slice(controller.indexOf('func confirmMerge'), controller.indexOf('func rollback'));
  const rollbackSection = controller.slice(controller.indexOf('func rollback'));
  assert.doesNotMatch(confirmSection, /currentAccessToken/);
  assert.doesNotMatch(rollbackSection, /currentAccessToken/);
  assert.match(controller, /final class AuthStoreCredentialProvider: SyncAccessTokenProviding/);
  assert.match(controller, /await authStore\?\.currentAccessToken\(\)/);
});

test('confirmMerge/rollback take a live AuthStore reference, never a raw access token string parameter', () => {
  assert.match(controller, /func confirmMerge\(authStore: AuthStore\) async/);
  assert.match(controller, /func rollback\(authStore: AuthStore\) async/);
  assert.doesNotMatch(controller, /func confirmMerge\([^)]*accessToken/);
  assert.doesNotMatch(controller, /func rollback\([^)]*accessToken/);
});

test('AuthStoreCredentialProvider holds only a weak AuthStore reference and re-queries the token fresh each call', () => {
  const providerSection = controller.slice(
    controller.indexOf('private final class AuthStoreCredentialProvider'),
    controller.indexOf('final class GuestMergeController')
  );
  assert.match(providerSection, /weak var authStore: AuthStore\?/);
  assert.doesNotMatch(providerSection, /var\s+\w*[Tt]oken\w*\s*:/, 'the provider must never cache a token value on a stored property');
});

test('Phase 2B-2.5: same-id keepBoth forks a new UUID rather than re-using the existing remote entity id', () => {
  assert.match(models, /var forkedLocalItemId: UUID\?/);
  const applyingChoiceSection = models.slice(models.indexOf('func applyingChoice'));
  assert.match(applyingChoiceSection, /forkedLocalItemId\s*=\s*\(remoteItemId == localItemId\)\s*\?\s*\(forkedLocalItemId \?\? UUID\(\)\)\s*:\s*nil/);
});

test('Phase 2B-2.5: the same-id keepBoth fork is always created at baseVersion 0, never inheriting the original entity\'s remote version', () => {
  const forkSection = controller.slice(controller.indexOf('if let forkedId = candidate.forkedLocalItemId'), controller.indexOf('guard let localItem = try await persistence.inventoryItem(id: candidate.localItemId) else { continue }'));
  assert.match(forkSection, /forkedItem\.id = forkedId/);
  // The fork must go through a plain stageUpsert on a never-before-seen id
  // (no seeded/known remoteVersion attached to it), which is what makes
  // InventorySyncAdapter.stageUpsert compute baseVersion as 0.
  assert.doesNotMatch(forkSection, /remoteVersion: candidate\.remoteVersion/);
});

test('Phase 2B-2.5: the original entity id is never simultaneously staged as keepRemote/no-op and create for the same candidate', () => {
  const stagingLoop = controller.slice(controller.indexOf('for candidate in toUpload'), controller.indexOf('let configuration = SyncConfiguration(isEnabled: true)'));
  // The fork branch must `continue` immediately after staging the forked
  // id, so control never falls through into staging `candidate.localItemId`
  // (the original, certain remote entity) for the very same candidate.
  const forkBranch = stagingLoop.slice(stagingLoop.indexOf('if let forkedId = candidate.forkedLocalItemId'), stagingLoop.indexOf('guard let localItem = try await persistence.inventoryItem(id: candidate.localItemId) else { continue }'));
  assert.match(forkBranch, /continue\s*\n\s*\}/, 'the fork branch must continue, never fall through to staging the original id too');
});

test('Phase 2B-2.5: rollback only ever references entity ids recorded in createdEntityIds (the fork), never the original candidate id directly', () => {
  const rollbackSection = controller.slice(controller.indexOf('func rollback'));
  assert.match(rollbackSection, /for entityId in current\.createdEntityIds/);
  assert.doesNotMatch(rollbackSection, /candidate\.localItemId/);
  // The read-back loop after upload must record the forked id (not the
  // original localItemId) into createdEntityIds for a forked candidate.
  const readBackSection = controller.slice(controller.indexOf('var uploaded = 0'), controller.indexOf('current.uploadedItemCount = uploaded'));
  assert.match(readBackSection, /let entityIdToCheck = candidate\.forkedLocalItemId \?\? candidate\.localItemId/);
  assert.match(readBackSection, /newCreatedIds\.append\(entityIdToCheck\)/);
});

test('Phase 2B-2.5: the different-id ambiguous-duplicate keepBoth path is unaffected — only same-id conflicts fork', () => {
  const applyingChoiceSection = models.slice(models.indexOf('func applyingChoice'));
  // The ternary keys the fork strictly off `remoteItemId == localItemId`;
  // a different-id match (`remoteItemId != localItemId`) always resolves to
  // `nil`, i.e. no fork, keeping its pre-existing `.create`-with-its-own-id
  // behavior exactly as before.
  assert.match(applyingChoiceSection, /remoteItemId == localItemId\)\s*\?\s*\(forkedLocalItemId \?\? UUID\(\)\)\s*:\s*nil/);
});

test('Phase 2B-2.5: default switches remain NO — no new flag was introduced for the identity-fork fix itself', () => {
  for (const value of [sharedConfig, exampleConfig]) {
    assert.match(value, /INVENTORY_SYNC_ENABLED\s*=\s*NO/);
  }
});

// Phase 2B-3: formal merge/sync UI, gated by a second independent flag,
// still with zero automatic network activity anywhere.

test('Phase 2B-3: INVENTORY_MERGE_UI_ENABLED is a second, independent flag, disabled by default everywhere', () => {
  for (const value of [sharedConfig, exampleConfig]) {
    assert.match(value, /INVENTORY_MERGE_UI_ENABLED\s*=\s*NO/);
  }
  assert.match(info, /KM_INVENTORY_MERGE_UI_ENABLED/);
  assert.match(models, /struct InventoryMergeUIConfiguration/);
  assert.match(models, /KM_INVENTORY_MERGE_UI_ENABLED/);
});

test('Phase 2B-3: no automatic runOnce anywhere in the UI/app-lifecycle files — every call site is user-initiated', () => {
  // The only production (non-Debug) call sites are confirmMerge, rollback,
  // and the new syncNow — all three require an explicit user tap through
  // GuestMergeViews.swift; none of them are reachable from App startup,
  // sign-in, a timer, or a background task.
  assert.doesNotMatch(content, /\.onAppear[\s\S]{0,200}runOnce/);
  assert.doesNotMatch(authStore, /runOnce/);
  assert.doesNotMatch(mainFeatureViews, /runOnce/);
  const runOnceSites = [...controller.matchAll(/coordinator\.runOnce/g)];
  assert.equal(runOnceSites.length, 3, 'expected exactly confirmMerge, rollback, and syncNow to call runOnce — any more/fewer is a scope change that needs review');
});

test('Phase 2B-3: signing in never triggers a sync/merge call, only refreshes account/household profile data', () => {
  const signInSection = authStore.slice(authStore.indexOf('func signIn'), authStore.indexOf('func signIn') + 1500);
  assert.doesNotMatch(signInSection, /runOnce|confirmMerge|syncNow|GuestMergeController/);
});

test('Phase 2B-3: App launch never triggers a sync/merge call', () => {
  const contentViewMinusDebug = content.replace(/#if DEBUG[\s\S]*?#endif/g, '');
  assert.doesNotMatch(contentViewMinusDebug, /runOnce|confirmMerge\(|\.syncNow\(/);
});

test('Phase 2B-3: merge preview still never creates a PendingMutation (unchanged from Phase 2B-1)', () => {
  const previewSection = controller.slice(controller.indexOf('func preparePreview'), controller.indexOf('func resolveConflict'));
  assert.doesNotMatch(previewSection, /stageUpsert|stageDelete|runOnce|PendingMutation/);
});

test('Phase 2B-3: syncNow only ever scopes to the inventory_item entity type, and only via the existing SyncCoordinator/adapter', () => {
  const syncNowSection = controller.slice(controller.indexOf('func syncNow'), controller.indexOf('func pendingInventoryCount'));
  assert.match(syncNowSection, /SyncCoordinator\(configuration: SyncConfiguration\(isEnabled: true\), persistence: persistence, transport: transport\)/);
  assert.doesNotMatch(syncNowSection, /SyncEntityType\.(shoppingItem|todayPlan|weeklyMealPlan|weeklyMealPlanItem|userRecipe|recipeFavorite|frequentRecipe)/);
  assert.doesNotMatch(syncNowSection, /KM_SYNC_ENABLED|SyncConfiguration\.load/);
});

test('Phase 2B-3: syncNow refuses without the network flag and without a signed-in user, mirroring confirmMerge/rollback', () => {
  const syncNowSection = controller.slice(controller.indexOf('func syncNow'), controller.indexOf('func pendingInventoryCount'));
  assert.match(syncNowSection, /guard isFeatureEnabled else/);
  assert.match(syncNowSection, /guard let userId = authStore\.currentUserID else/);
});

test('Phase 2B-3: no service-role key, no raw token access from any View, and the manual sync UI never prints technical error text', () => {
  assert.doesNotMatch(views, /service_role|SERVICE_ROLE|currentAccessToken/);
  assert.doesNotMatch(views, /print\(|debugPrint\(/);
  assert.match(controller, /userFacingSyncError/, 'syncNow must map SyncError to plain user-facing copy, never the raw error');
});

test('Phase 2B-3: same-id keepBoth identity-fork semantics are preserved (no regression from the new skip choice)', () => {
  assert.match(models, /case skip$/m);
  const applyingChoiceSection = models.slice(models.indexOf('func applyingChoice'));
  assert.match(applyingChoiceSection, /case \.skip:\s*\n\s*copy\.action = \.skip\s*\n\s*copy\.forkedLocalItemId = nil/);
  assert.match(applyingChoiceSection, /remoteItemId == localItemId\)\s*\?\s*\(forkedLocalItemId \?\? UUID\(\)\)\s*:\s*nil/);
});

test('Phase 2B-3: Shopping/Today Plan/Weekly Plan/Recipe entity types never appear anywhere in the merge/sync UI or controller', () => {
  const forbidden = /SyncEntityType\.(shoppingItem|todayPlan|weeklyMealPlan|weeklyMealPlanItem|userRecipe|recipeFavorite|frequentRecipe)/;
  assert.doesNotMatch(controller, forbidden);
  assert.doesNotMatch(views, forbidden);
  assert.doesNotMatch(planner, forbidden);
});

test('Phase 2B-3: manual sync button and keepBoth-fork notice expose stable accessibility identifiers for UI testing', () => {
  assert.match(views, /accessibilityIdentifier\("inventorySyncNowButton"\)/);
  assert.match(views, /accessibilityIdentifier\("guestMergeKeepBothForkNotice/);
  assert.match(views, /accessibilityIdentifier\("guestMergeConflictPicker/);
});

test('Phase 2B-3: manual sync and conflict-resolution controls declare at least 44pt touch targets', () => {
  const syncSection = views.slice(views.indexOf('struct InventorySyncStatusView'), views.indexOf('struct InventoryMergeFlowView'));
  assert.match(syncSection, /minHeight: 44/);
});

test('Phase 2B-3: the conflict picker offers all four documented choices (keepLocal/keepRemote/keepBoth/skip)', () => {
  const conflictViewSection = views.slice(views.indexOf('struct InventoryMergeConflictView'), views.indexOf('struct InventoryMergeProgressView'));
  assert.match(conflictViewSection, /InventoryMergeConflictChoice\.keepLocal/);
  assert.match(conflictViewSection, /InventoryMergeConflictChoice\.keepRemote/);
  assert.match(conflictViewSection, /InventoryMergeConflictChoice\.keepBoth/);
  assert.match(conflictViewSection, /InventoryMergeConflictChoice\.skip/);
});

test('Phase 2B-3: the preview screen never displays a raw UUID, mutation id, cursor, token, or household internal id', () => {
  const previewSection = views.slice(views.indexOf('struct InventoryMergePreviewView'), views.indexOf('struct InventoryMergeConflictView'));
  assert.doesNotMatch(previewSection, /\.uuidString|mutationId|cursor|accessToken|householdId\.uuidString/);
});
