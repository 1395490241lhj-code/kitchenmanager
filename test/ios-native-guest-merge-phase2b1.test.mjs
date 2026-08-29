import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';

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
const kitchenStore = read('KitchenManager/KitchenStore.swift');
const syncPersistence = read('KitchenManager/Synchronization/SyncPersistence.swift');
const eligibility = read('KitchenManager/Synchronization/InventorySyncEligibility.swift');
const enrollment = read('KitchenManager/Synchronization/InventorySyncEnrollment.swift');
const inventorySyncAdapter = read('KitchenManager/Synchronization/InventorySyncAdapter.swift');
const dogfoodConfig = read('KitchenManager/Synchronization/InventorySyncDogfoodConfiguration.swift');
const diagnostics = read('KitchenManager/Synchronization/InventorySyncDiagnostics.swift');
const consistencyChecker = read('KitchenManager/Synchronization/InventorySyncConsistencyChecker.swift');
const guestMergeSmoke = read('KitchenManager/Synchronization/GuestMergeSmoke.swift');
const syncSmoke = read('KitchenManager/Synchronization/SyncSmoke.swift');
const diagnosticsView = read('KitchenManager/Synchronization/InventorySyncDiagnosticsView.swift');

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

test('rollback is scoped to only this session\'s own created records, and uses a remote-only soft delete', () => {
  const rollbackSection = controller.slice(controller.indexOf('func performRollback'));
  assert.match(rollbackSection, /current\.createdEntityIds/);
  assert.match(rollbackSection, /adapter\.stageRemoteDeletePreservingLocal/);
  assert.doesNotMatch(rollbackSection, /deleteAll|physically|DELETE FROM/i);
});

test('R3: rollback never uses the destructive local-removing delete helper', () => {
  const rollbackSection = controller.slice(controller.indexOf('func performRollback'));
  assert.doesNotMatch(
    rollbackSection,
    /stageDeleteRemovingLocalRecord|commitInventoryAndSync|removeInventory/,
    'rollback must never physically delete a local durable InventoryRecord'
  );
  // The whole controller — CRUD hook included — never *calls* the destructive
  // helper. (Its doc comment names it, to say precisely that.)
  assert.doesNotMatch(controller, /adapter\.stageDeleteRemovingLocalRecord/);
});

test('R3: the destructive delete helper has zero production consumers — smoke/marker cleanup only', () => {
  // Enumerated from the tree rather than from a hand-written file list, so a
  // newly added production file that calls it is caught too.
  const allowedCallers = new Set(['GuestMergeSmoke.swift', 'SyncSmoke.swift']);
  const swiftSources = [];
  const walk = dir => {
    for (const entry of readdirSync(new URL(dir, root), { withFileTypes: true })) {
      if (entry.isDirectory()) walk(`${dir}${entry.name}/`);
      else if (entry.name.endsWith('.swift')) swiftSources.push([entry.name, `${dir}${entry.name}`]);
    }
  };
  walk('KitchenManager/');
  assert.ok(swiftSources.length > 20, 'the production source walk must actually have found the sources');
  for (const [name, path] of swiftSources) {
    if (allowedCallers.has(name)) continue;
    assert.doesNotMatch(
      read(path),
      /\.stageDeleteRemovingLocalRecord\(/,
      `${name} must not call the destructive delete helper`
    );
  }
  // The adapter still declares it, and both smoke harnesses still use it.
  assert.match(inventorySyncAdapter, /func stageDeleteRemovingLocalRecord\(/);
  assert.match(guestMergeSmoke, /\.stageDeleteRemovingLocalRecord\(/);
  assert.match(syncSmoke, /\.stageDeleteRemovingLocalRecord\(/);
});

test('R3: the remote-only delete helper stages a mutation and never writes InventoryRecord', () => {
  const helper = inventorySyncAdapter.slice(inventorySyncAdapter.indexOf('func stageRemoteDeletePreservingLocal'));
  const body = helper.slice(0, helper.indexOf('\n    }'));
  assert.match(body, /persistence\.stageInventoryMutation/);
  assert.doesNotMatch(body, /commitInventoryAndSync|removeInventory|mutateInventory/);
  // No ambiguous boolean parameter: the two intentions are separated by name.
  // (The doc comment may *mention* `preserveLocal:` to say why it was rejected.)
  assert.doesNotMatch(inventorySyncAdapter, /preserveLocal:\s*Bool/);
});

test('R3: ordinary user deletion still deletes locally and stages the remote delete separately', () => {
  // KitchenStore owns the local deletion; the sync layer only stages intent.
  const crudHook = controller.slice(controller.indexOf('func stageMutationIfEligible'));
  assert.match(crudHook, /persistence\.stageInventoryMutation/);
  assert.doesNotMatch(crudHook, /stageDeleteRemovingLocalRecord|removeInventory/);
});

test('R3: a rolled-back, remotely-tombstoned row can never be resurrected by a later local edit', () => {
  assert.match(eligibility, /case remotelyDeleted/);
  // Covers every intent — a `.create` carve-out would be an unguarded way back
  // into the resurrect path this rule exists to close.
  assert.match(
    eligibility,
    /state == \.synced, scopedMetadata\.deletedAt != nil \{[\s\S]{0,120}\.localOnly\(reason: \.remotelyDeleted\)/
  );
  assert.doesNotMatch(eligibility, /deletedAt != nil, intent != \.create/);
  // The tombstone metadata is the shield against a repeated tombstone pull
  // deleting the preserved local row — rollback must not clear it.
  const rollbackSection = controller.slice(controller.indexOf('func performRollback'));
  assert.doesNotMatch(rollbackSection, /deleteMetadata/);
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
  const confirmSection = controller.slice(controller.indexOf('func performConfirmMerge'), controller.indexOf('func performRollback'));
  const rollbackSection = controller.slice(controller.indexOf('func performRollback'));
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
  const forkSection = controller.slice(controller.indexOf('if let forkedId = candidate.activeForkedLocalItemId'), controller.indexOf('guard let localItem = try await persistence.inventoryItem(id: candidate.localItemId) else { continue }'));
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
  const forkBranch = stagingLoop.slice(stagingLoop.indexOf('if let forkedId = candidate.activeForkedLocalItemId'), stagingLoop.indexOf('guard let localItem = try await persistence.inventoryItem(id: candidate.localItemId) else { continue }'));
  assert.match(forkBranch, /continue\s*\n\s*\}/, 'the fork branch must continue, never fall through to staging the original id too');
});

test('Phase 2B-2.5: rollback only ever references entity ids recorded in createdEntityIds (the fork), never the original candidate id directly', () => {
  const rollbackSection = controller.slice(controller.indexOf('func performRollback'));
  assert.match(rollbackSection, /for entityId in current\.createdEntityIds/);
  assert.doesNotMatch(rollbackSection, /candidate\.localItemId/);
  // The read-back loop after upload must record the forked id (not the
  // original localItemId) into createdEntityIds for a forked candidate.
  const readBackSection = controller.slice(controller.indexOf('var uploaded = 0'), controller.indexOf('current.uploadedItemCount = uploaded'));
  assert.match(readBackSection, /let entityIdToCheck = candidate\.activeForkedLocalItemId \?\? candidate\.localItemId/);
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
  const syncNowSection = controller.slice(controller.indexOf('func performSyncNow'), controller.indexOf('func pendingInventoryCount'));
  assert.match(syncNowSection, /SyncCoordinator\(configuration: SyncConfiguration\(isEnabled: true\), persistence: persistence, transport: transport\)/);
  assert.doesNotMatch(syncNowSection, /SyncEntityType\.(shoppingItem|todayPlan|weeklyMealPlan|weeklyMealPlanItem|userRecipe|recipeFavorite|frequentRecipe)/);
  assert.doesNotMatch(syncNowSection, /KM_SYNC_ENABLED|SyncConfiguration\.load/);
});

test('Phase 2B-3: syncNow refuses without the network flag and without a signed-in user, mirroring confirmMerge/rollback', () => {
  const syncNowSection = controller.slice(controller.indexOf('func performSyncNow'), controller.indexOf('func pendingInventoryCount'));
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
  // UI-5B2B-B2B: `.skip` retains the reservation; only `activeForkedLocalItemId` gates upload.
  assert.match(applyingChoiceSection, /case \.skip:\s*\n\s*copy\.action = \.skip/);
  assert.match(applyingChoiceSection, /remoteItemId == localItemId\)\s*\?\s*\(forkedLocalItemId \?\? UUID\(\)\)\s*:\s*nil/);
});

test('Phase 2B-3: Shopping/Today Plan/Weekly Plan/Recipe entity types never appear anywhere in the merge/sync UI or controller', () => {
  const forbidden = /SyncEntityType\.(shoppingItem|todayPlan|weeklyMealPlan|weeklyMealPlanItem|userRecipe|recipeFavorite|frequentRecipe)/;
  assert.doesNotMatch(controller, forbidden);
  assert.doesNotMatch(views, forbidden);
  assert.doesNotMatch(planner, forbidden);
});

test('Phase 2B-3: manual sync button and per-choice conflict rows expose stable accessibility identifiers for UI testing', () => {
  assert.match(views, /accessibilityIdentifier\("inventorySyncNowButton"\)/);
  // UI-5B2B-B1 replaced the single segmented picker with one identified row per
  // choice, so the per-choice identifier is now the stable UI-testing handle.
  assert.match(views, /accessibilityIdentifier\(\s*"guestMergeConflictChoice-/);
});

// UI-5B2B-B1 split the conflict screen into a pure presentation type plus the
// view that renders it, so several tests below slice the same two regions.
const conflictPresentationSection = () => views.slice(
  views.indexOf('struct InventoryMergeConflictChoicePresentation'),
  views.indexOf('struct InventoryMergeConflictView')
);
const conflictViewSection = () => views.slice(
  views.indexOf('struct InventoryMergeConflictView'),
  views.indexOf('struct InventoryMergeProgressView')
);

test('UI-5B2B-B1: the same-record keepBoth fork explanation is shown before the choice, not after it', () => {
  // It used to be a separate notice rendered only once keepBoth was already
  // picked. A tap now resolves the conflict and the row leaves the list, so
  // that notice could never appear; the same explanation is instead part of
  // the keepBoth row's up-front consequence copy.
  assert.match(conflictPresentationSection(), /家庭库存里已有这条记录/);
  assert.match(conflictPresentationSection(), /单独新增一份/);
  assert.match(conflictPresentationSection(), /不会覆盖家庭原有的记录/);
});

test('Phase 2B-3: manual sync and conflict-resolution controls declare at least 44pt touch targets', () => {
  const syncSection = views.slice(views.indexOf('struct InventorySyncStatusView'), views.indexOf('struct InventoryMergeFlowView'));
  assert.match(syncSection, /minHeight: 44/);
});

test('Phase 2B-3: the conflict screen offers all four documented choices (keepLocal/keepRemote/keepBoth/skip)', () => {
  // UI-5B2B-B1 moved the choice list out of the view and into a pure
  // presentation type, so the declaration is asserted here and the view's use
  // of it in the next test — kept separate so a failure names which one broke.
  assert.match(
    conflictPresentationSection(),
    /static let orderedChoices: \[InventoryMergeConflictChoice\] = \[\.keepLocal, \.keepRemote, \.keepBoth, \.skip\]/
  );
  for (const choice of ['keepLocal', 'keepRemote', 'keepBoth', 'skip']) {
    assert.match(conflictPresentationSection(), new RegExp(`case \\.${choice}:`));
  }
});

test('UI-5B2B-B1: the conflict screen renders exactly the ordered choice list, never its own copy of it', () => {
  assert.match(
    conflictViewSection(),
    /ForEach\(InventoryMergeConflictChoicePresentation\.orderedChoices/
  );
});

test('UI-5B2B-B1: no phantom keepRemote default can make 保留家庭 look chosen', () => {
  // The exact defect this phase fixed: a view-local `?? .keepRemote` fallback.
  assert.doesNotMatch(conflictViewSection(), /\?\?\s*\.keepRemote/);
});

test('UI-5B2B-B1: the conflict screen keeps no view-local pendingChoice selection state', () => {
  // The state that made the displayed selection independent of the stored one.
  assert.doesNotMatch(conflictViewSection(), /pendingChoice/);
});

test('UI-5B2B-B1: the displayed selection is derived from the persisted candidate choice', () => {
  assert.match(conflictViewSection(), /isSelected: candidate\.userChoice == choice/);
});

test('Phase 2B-3: the preview screen never displays a raw UUID, mutation id, cursor, token, or household internal id', () => {
  const previewSection = views.slice(views.indexOf('struct InventoryMergePreviewView'), views.indexOf('struct InventoryMergeConflictView'));
  // Accessibility identifiers may embed a candidate id — they are test handles,
  // never rendered text. Strip those lines before checking for visible leaks.
  const visible = previewSection
    .split('\n')
    .filter(line => !line.includes('accessibilityIdentifier'))
    .join('\n');
  assert.doesNotMatch(visible, /\.uuidString|mutationId|cursor|accessToken|householdId\.uuidString/);
});

// Phase 2B-4: synced-scope Inventory CRUD mutation staging — still zero
// automatic network activity anywhere; only a manual sync sends anything.

test('Phase 2B-4: KitchenStore never calls the network or the sync coordinator directly — only exposes a generic, optional change hook', () => {
  assert.doesNotMatch(kitchenStore, /runOnce|URLSession|SyncCoordinator|APIClient|AuthStore/);
  assert.match(kitchenStore, /var onInventoryChanged: \(\(\[InventoryItem\], \[InventoryItem\]\) -> Void\)\?/);
});

test('Phase 2B-4: the composition root (ContentView) is the only place KitchenStore is told about sync, and it never fires runOnce directly', () => {
  assert.match(content, /onInventoryChanged = /);
  assert.doesNotMatch(content.replace(/#if DEBUG[\s\S]*?#endif/g, ''), /runOnce/);
});

test('Phase 2B-4: repository/persistence writes never call runOnce — still exactly 3 call sites total in GuestMergeController (confirmMerge, rollback, syncNow)', () => {
  assert.doesNotMatch(syncPersistence, /runOnce/);
  const runOnceSites = [...controller.matchAll(/coordinator\.runOnce/g)];
  assert.equal(runOnceSites.length, 3);
});

test('Phase 2B-4: InventorySyncEligibility is the single centralized policy — Guest-only/not-enrolled always resolves to localOnly, never duplicated inline elsewhere', () => {
  assert.match(eligibility, /enum InventorySyncEligibility/);
  assert.match(eligibility, /case localOnly\(reason: LocalOnlyReason\)/);
  assert.match(eligibility, /guard let enrollment, enrollment\.householdId == householdId, enrollment\.status\.allowsMutationStaging else/);
  // The decision must not be re-implemented inline in the controller or the
  // views — both must call into InventorySyncEligibility.evaluate, not
  // reimplement the flag/enrollment/metadata checks themselves.
  assert.match(controller, /InventorySyncEligibility\.evaluate/);
  assert.doesNotMatch(views, /InventorySyncEligibility/);
});

test('Phase 2B-4: enrollment only becomes .enrolled inside confirmMerge\'s completed branch, never anywhere else', () => {
  const enrolledSites = [...controller.matchAll(/status: \.enrolled/g)];
  assert.equal(enrolledSites.length, 1, 'exactly one place may transition enrollment to .enrolled');
  const completedSection = controller.slice(controller.indexOf('current.status = .completed'), controller.indexOf('} else if failed > 0'));
  assert.match(completedSection, /saveEnrollment/);
});

test('Phase 2B-4: create/update/delete coalescing rules exist and cover create+update, create+delete cancel, update+update, update+delete, and duplicate-delete', () => {
  assert.match(syncPersistence, /case \(\.upsert, \.upsert\):/);
  assert.match(syncPersistence, /case \(\.upsert, \.delete\):/);
  assert.match(syncPersistence, /case \(\.delete, \.upsert\):/);
  assert.match(syncPersistence, /case \(\.delete, \.delete\):/);
  assert.match(syncPersistence, /cancel entirely/);
  assert.match(syncPersistence, /merge into a single delete intent/i);
});

test('Phase 2B-4: delete always stages a tombstone (deletedAt + pendingDelete), never a physical remote delete request from the client', () => {
  assert.match(syncPersistence, /EntitySyncState\.pendingDelete/);
  assert.doesNotMatch(syncPersistence, /DELETE FROM|deleteAllRemote|physically/i);
});

test('Phase 2B-4: CRUD staging is scoped to inventory_item only — no other entity type ever appears in the eligibility/staging path', () => {
  const forbidden = /SyncEntityType\.(shoppingItem|todayPlan|weeklyMealPlan|weeklyMealPlanItem|userRecipe|recipeFavorite|frequentRecipe)/;
  assert.doesNotMatch(eligibility, forbidden);
  assert.doesNotMatch(enrollment, forbidden);
  const handleChangeSection = controller.slice(controller.indexOf('func handleInventoryDidChange'));
  assert.match(handleChangeSection, /entityType: \.inventoryItem/);
});

test('Phase 2B-4: eligibility requires the metadata scope to match the current household — cross-household/account metadata is never treated as existing', () => {
  assert.match(eligibility, /metadata\.scope\.type == \.household && metadata\.scope\.id == householdId/);
});

test('Phase 2B-4: enrollment defaults to NO staging everywhere — INVENTORY_SYNC_ENABLED stays the required gate, and no ignored-flag dependency exists in ordinary tests', () => {
  for (const value of [sharedConfig, exampleConfig]) {
    assert.match(value, /INVENTORY_SYNC_ENABLED\s*=\s*NO/);
  }
  assert.doesNotMatch(eligibility, /Local\.xcconfig|ProcessInfo/);
});

test('Phase 2B-4: no service-role key, and no View reads a token or calls the staging/eligibility APIs directly', () => {
  assert.doesNotMatch(kitchenStore, /service_role|SERVICE_ROLE/);
  assert.doesNotMatch(views, /service_role|SERVICE_ROLE|currentAccessToken|stageInventoryMutation|InventorySyncEligibility/);
});

test('Phase 2B-4: Shopping/Today Plan/Weekly Plan/Recipe/Favorites/Frequent are never wired into the inventory change hook or eligibility policy', () => {
  const forbidden = /Shopping|TodayPlan|WeeklyPlan|Recipe|Favorite|Frequent/;
  assert.doesNotMatch(eligibility, forbidden);
  assert.doesNotMatch(enrollment, forbidden);
});

test('Phase 2B-4: no Timer, background task, or Realtime path triggers automatic sync anywhere in the new files', () => {
  const forbidden = /Timer\(|BGTaskScheduler|DispatchSourceTimer|RealtimeChannel|\.schedule\(/;
  for (const file of [kitchenStore, controller, syncPersistence, eligibility, enrollment, content]) {
    assert.doesNotMatch(file, forbidden);
  }
});

test('Phase 2B-4: the payload encoder is shared (InventorySyncAdapter.encodedPayload), never a second drifting implementation', () => {
  assert.match(inventorySyncAdapter, /func encodedPayload\(for item: InventoryItem\) throws -> Data/);
  assert.match(controller, /adapter\.encodedPayload\(for: item\)/);
});

test('Sync P3: the classification pair is written from one snapshot, and the PWA-owned `kind` column is never touched', () => {
  // Both axes live in the single private payload builder, so a
  // classification change can never send one half without the other.
  assert.match(inventorySyncAdapter, /"isStaple": \.bool\(item\.isStaple\)/);
  assert.match(inventorySyncAdapter, /"preparationKind": \.string\(item\.kind == \.readyToCook \? "readyToCook" : "none"\)/);
  // `kind` is the PWA's own raw/dry/staple column. Writing it from here
  // would corrupt the other client's data, and `preparation_kind` is
  // NOT NULL so an explicit null is rejected rather than read as "none".
  // Anchored to line-start so these match a dictionary key literal only —
  // never prose in a doc comment that happens to name the field.
  assert.doesNotMatch(inventorySyncAdapter, /^\s*"kind":/m);
  assert.doesNotMatch(inventorySyncAdapter, /^\s*"preparationKind": \.null/m);
  assert.doesNotMatch(inventorySyncAdapter, /^\s*value\["preparationKind"\] = .*\.null/m);
});

test('Sync P3: decode precedence is staple > readyToCook > ordinary, resolved in exactly one place', () => {
  assert.match(inventorySyncAdapter, /private func classification\(_ data: \[String: SyncJSONValue\]\) -> InventoryItemKind/);
  assert.match(inventorySyncAdapter, /if bool\(data\["isStaple"\]\) == true \{ return \.staple \}/);
  assert.match(inventorySyncAdapter, /string\(data\["preparationKind"\]\) == "readyToCook" \? \.readyToCook : \.ordinary/);
  // The local enum's vocabulary is not the wire's preparation vocabulary —
  // `InventoryItemKind(rawValue:)` would silently accept "staple".
  assert.doesNotMatch(inventorySyncAdapter, /InventoryItemKind\(rawValue:/);
  // The resolved kind travels onward; precedence is never re-implemented.
  assert.match(inventorySyncAdapter, /kind: classification\(change\.data\)/);
  assert.match(inventorySyncAdapter, /kind: item\.kind,/);
});

test('Sync P3: the merge planner compares and hashes the whole classification, not its isStaple projection', () => {
  assert.match(planner, /let kind: InventoryItemKind/);
  assert.match(planner, /var isStaple: Bool \{ kind == \.staple \}/);
  assert.match(planner, /local\.kind != remote\.kind/);
  assert.doesNotMatch(planner, /local\.isStaple != remote\.isStaple/);
  assert.match(planner, /fields\.append\(item\.kind\.rawValue\)/);
  assert.match(planner, /:\\\(item\.kind\.rawValue\)/);
  // Classification stays metadata: the matching key is still name + unit.
  assert.match(planner, /return "\\\(normalizedName\)\|\\\(normalizedUnit\)"/);
});

test('Phase 2B-5: both new dogfood flags default NO in every committed configuration', () => {
  for (const value of [sharedConfig, exampleConfig]) {
    assert.match(value, /INVENTORY_SYNC_DOGFOOD_ENABLED\s*=\s*NO/);
    assert.match(value, /INVENTORY_SYNC_DIAGNOSTICS_ENABLED\s*=\s*NO/);
  }
  assert.match(info, /KM_INVENTORY_SYNC_DOGFOOD_ENABLED/);
  assert.match(info, /KM_INVENTORY_SYNC_DIAGNOSTICS_ENABLED/);
});

test('Phase 2B-5: existing flags remain NO (dogfood work never flips a prior default)', () => {
  for (const value of [sharedConfig, exampleConfig]) {
    assert.match(value, /INVENTORY_SYNC_ENABLED\s*=\s*NO/);
    assert.match(value, /INVENTORY_MERGE_UI_ENABLED\s*=\s*NO/);
    assert.match(value, /GUEST_MERGE_SMOKE_ENABLED\s*=\s*NO/);
    assert.match(value, /SYNC_ENABLED\s*=\s*NO/);
    assert.match(value, /SYNC_SMOKE_ENABLED\s*=\s*NO/);
  }
});

test('Phase 2B-5: the diagnostics snapshot struct never declares an email/password/token/full-UUID field, and its redactedJSON dictionary keys are exactly the declared fields', () => {
  const structBody = diagnostics.slice(diagnostics.indexOf('struct InventorySyncDiagnosticsSnapshot'), diagnostics.indexOf('func redactedJSON'));
  const forbiddenFieldNames = /let (email|password|jwt|refreshToken|authorization|entityId|householdId|mutationId|itemName|payload)\b/i;
  assert.doesNotMatch(structBody, forbiddenFieldNames);
  const jsonBody = diagnostics.slice(diagnostics.indexOf('let payload: [String: Any]'), diagnostics.indexOf('return (try? JSONSerialization'));
  const forbiddenJSONKeys = /"(email|password|jwt|refreshToken|authorization|entityId|householdId|mutationId|itemName)"/i;
  assert.doesNotMatch(jsonBody, forbiddenJSONKeys);
});

test('Phase 2B-5: the consistency checker is a pure, read-only function — it never calls a persistence save/write method', () => {
  const forbidden = /saveMetadata|saveEnrollment|stageInventoryMutation|deleteMetadata|save\(|try context\.save/;
  assert.doesNotMatch(consistencyChecker, forbidden);
  assert.match(consistencyChecker, /static func check\(/);
});

test('Phase 2B-5: the queue cap never blocks a delete and never blocks coalescing into an already-staged mutation', () => {
  assert.match(eligibility, /intent != \.delete, currentPendingCount >= maxPendingMutations/);
  assert.match(eligibility, /!hasExistingPendingMutationForEntity/);
});

test('Phase 2B-5: recovery/consistency code never physically deletes remote data or uses a service-role key', () => {
  for (const file of [consistencyChecker, diagnostics, dogfoodConfig, diagnosticsView]) {
    assert.doesNotMatch(file, /service_role|SERVICE_ROLE|DELETE FROM|physically delete/i);
  }
});

test('Phase 2B-5: the diagnostics screen offers no delete/clear/force-overwrite action, and is gated by showsDiagnosticsScreen', () => {
  assert.doesNotMatch(diagnosticsView, /clear all|forceOverwrite|remoteVersion =|deleteDatabase|force remoteVersion/i);
  assert.match(diagnosticsView, /showsDiagnosticsScreen/);
});

test('Phase 2B-5: dogfood enabling never implies automatic sync — no Timer/BGTaskScheduler/Realtime appears in any new Phase 2B-5 file', () => {
  const forbidden = /Timer\(|BGTaskScheduler|DispatchSourceTimer|RealtimeChannel|\.schedule\(/;
  for (const file of [dogfoodConfig, diagnostics, consistencyChecker, diagnosticsView]) {
    assert.doesNotMatch(file, forbidden);
  }
});

test('Phase 2B-5: Local.xcconfig remains ignored by git', () => {
  const gitignore = readFileSync(new URL('../.gitignore', import.meta.url), 'utf8');
  assert.match(gitignore, /Local\.xcconfig/);
});

test('Phase 2B-6: fault-injection code exists only in the test target, never under KitchenManager/ (the app target)', () => {
  for (const file of [kitchenStore, controller, syncPersistence, eligibility, enrollment, dogfoodConfig, diagnostics, consistencyChecker, diagnosticsView, content, views]) {
    assert.doesNotMatch(file, /InventorySyncFaultInjectingTransport|InventorySyncFault\b/);
  }
});

test('Phase 2B-6: all flags remain default NO after fault-injection/dogfood-smoke work', () => {
  for (const value of [sharedConfig, exampleConfig]) {
    assert.match(value, /SYNC_ENABLED\s*=\s*NO/);
    assert.match(value, /INVENTORY_SYNC_ENABLED\s*=\s*NO/);
    assert.match(value, /INVENTORY_MERGE_UI_ENABLED\s*=\s*NO/);
    assert.match(value, /GUEST_MERGE_SMOKE_ENABLED\s*=\s*NO/);
    assert.match(value, /INVENTORY_SYNC_DOGFOOD_ENABLED\s*=\s*NO/);
    assert.match(value, /INVENTORY_SYNC_DIAGNOSTICS_ENABLED\s*=\s*NO/);
  }
});

test('Phase 2B-6: no automatic sync, timer, background task, or Realtime path exists anywhere in the sync layer', () => {
  const forbidden = /Timer\(|BGTaskScheduler|DispatchSourceTimer|RealtimeChannel|\.schedule\(/;
  for (const file of [kitchenStore, controller, syncPersistence, eligibility, enrollment, dogfoodConfig, diagnostics, consistencyChecker, diagnosticsView]) {
    assert.doesNotMatch(file, forbidden);
  }
});

test('Phase 2B-6: no production business-logic file outside GuestMergeController/the Debug-only smoke runners calls runOnce', () => {
  // KitchenStore, the eligibility/enrollment policy, the dogfood
  // config/diagnostics/consistency-checker types, and the diagnostics View
  // must never call runOnce directly — the only production call site is
  // GuestMergeController (manual "立即同步库存"/retry), plus the pre-existing
  // Debug-only smoke runners (GuestMergeSmoke.swift/SyncSmoke.swift), which
  // are gated by their own smoke flags and covered by their own guards.
  for (const file of [kitchenStore, eligibility, enrollment, dogfoodConfig, diagnostics, consistencyChecker, diagnosticsView, content]) {
    assert.doesNotMatch(file, /\.runOnce\(/);
  }
  assert.match(controller, /\.runOnce\(/);
});

test('Phase 2B-6: no service-role key and no access token read directly by any View', () => {
  for (const file of [diagnosticsView, views, accountViews, mainFeatureViews]) {
    assert.doesNotMatch(file, /service_role|SERVICE_ROLE|currentAccessToken/);
  }
});

test('Phase 2B-6: the new hosted dogfood smoke marker prefix is distinct and swept by the cleanup script', () => {
  assert.match(read('KitchenManager/Synchronization/GuestMergeSmoke.swift'), /__inventory_dogfood_/);
  const cleanupScript = readFileSync(new URL('../scripts/cleanup-guest-merge-smoke-markers.mjs', import.meta.url), 'utf8');
  assert.match(cleanupScript, /__inventory_dogfood_/);
});

test('Phase 2B-6: the consistency checker remains read-only after this phase\'s changes', () => {
  assert.doesNotMatch(consistencyChecker, /saveMetadata|saveEnrollment|stageInventoryMutation|deleteMetadata|try context\.save/);
});

test('Phase 2B-6: recovery/fault-handling code never physically deletes remote data', () => {
  for (const file of [controller, syncPersistence, consistencyChecker]) {
    assert.doesNotMatch(file, /DELETE FROM|physically delete|deleteAllRemote/i);
  }
});

test('Phase 2B-6: Shopping/Today Plan/Weekly Plan/Recipe/Favorites/Frequent remain unwired from the sync/dogfood layer', () => {
  const forbidden = /Shopping|TodayPlan|WeeklyPlan|Recipe|Favorite|Frequent/;
  for (const file of [eligibility, enrollment, dogfoodConfig, diagnostics, consistencyChecker]) {
    assert.doesNotMatch(file, forbidden);
  }
});

// MARK: - Phase 2B-8: production remote preview, stale-preview safety gate, Conflict UI reachability

test('Phase 2B-8: the production preview call site passes an authenticated transport, never a nil/no-op one', () => {
  // The explicit merge sheet owns the authenticated preview read. The
  // account-page prompt only presents the entry point and must not start a
  // remote read while it is rendering.
  const flowStart = views.indexOf('struct InventoryMergeFlowView');
  const flow = views.slice(flowStart);
  assert.match(flow, /\.task\(id: previewTaskID\)[\s\S]{0,2000}controller\.preparePreview\([\s\S]*?userId: userId,[\s\S]*?householdId: householdId,[\s\S]*?kitchenStore: kitchenStore,[\s\S]*?authStore: authStore/);
  assert.match(controller, /func preparePreview\(\s*userId: UUID,\s*householdId: UUID,\s*kitchenStore: KitchenStore,\s*authStore: AuthStore\s*\) async/);
});

test('Phase 2B-8: the production preview overload builds its transport via the existing AuthStoreCredentialProvider/transportFactory pattern, not a new mechanism', () => {
  const overloadStart = controller.indexOf('func preparePreview(\n        userId: UUID,\n        householdId: UUID,\n        kitchenStore: KitchenStore,\n        authStore: AuthStore');
  assert.notEqual(overloadStart, -1, 'the authStore-taking preparePreview overload must exist');
  const overloadBody = controller.slice(overloadStart, overloadStart + 400);
  assert.match(overloadBody, /AuthStoreCredentialProvider\(authStore: authStore\)/);
  assert.match(overloadBody, /transportFactory\(provider\)/);
});

test('Phase 2B-8: GuestMergePromptView never reads a token directly — only ever passes its own AuthStore reference', () => {
  assert.doesNotMatch(views, /currentAccessToken|Authorization"|Bearer /);
  assert.match(views, /@EnvironmentObject private var authStore: AuthStore/);
});

test('Phase 2B-8: a preview fetch failure can never be silently reported as an empty/successful cloud state', () => {
  assert.match(controller, /previewFetchFailureMessage/);
  // The remote-fetch try/catch must be isolated from the rest of
  // preparePreview's body — a caught error must return immediately, never
  // fall through to constructing/saving a session with an empty
  // knownRemoteItems array as if the read had legitimately found nothing.
  const previewStart = controller.indexOf('func preparePreview(\n        userId: UUID,\n        householdId: UUID,\n        kitchenStore: KitchenStore,\n        remoteTransport');
  const previewEnd = controller.indexOf('func preparePreview(\n        userId: UUID,\n        householdId: UUID,\n        kitchenStore: KitchenStore,\n        authStore: AuthStore');
  const body = controller.slice(previewStart, previewEnd);
  assert.match(body, /catch \{[\s\S]*?previewFetchFailureMessage = Self\.userFacingSyncError/);
  assert.match(body, /return\s*\}/);
});

test('Phase 2B-8: fetchKnownRemoteItems throws (never silently truncates/breaks) on scope mismatch or exceeding the page cap', () => {
  assert.doesNotMatch(controller, /guard response\.scope == scope else \{ break \}/);
  assert.match(controller, /guard response\.scope == scope else \{ throw/);
  assert.match(controller, /guard !hasMore else \{ throw/);
});

test('Phase 2B-8: a remote snapshot fingerprint concept exists and folds into the plan hash', () => {
  assert.match(models, /let remoteSnapshotHash: String\?/);
  assert.match(models, /let remoteSnapshotFetchedAt: Date\?/);
  assert.match(planner, /static func remoteSnapshotHash\(/);
  assert.match(planner, /func planHash\([^)]*remoteSnapshotHash: String\?/s);
});

test('Phase 2B-8: confirmMerge revalidates the remote fingerprint before staging any mutation, and rejects a stale plan', () => {
  const confirmStart = controller.indexOf('func performConfirmMerge(authStore: AuthStore) async {');
  const stageStart = controller.indexOf('for candidate in toUpload');
  assert.ok(confirmStart >= 0 && stageStart > confirmStart, 'confirmMerge must exist and stage candidates after its own body starts');
  const preStageBody = controller.slice(confirmStart, stageStart);
  assert.match(preStageBody, /fetchKnownRemoteItems\(householdId: current\.householdId, transport: transport\)/);
  assert.match(preStageBody, /InventoryMergePlanner\.remoteSnapshotHash\(currentRemoteItems\)/);
  assert.match(preStageBody, /家庭库存已变化，请重新预览/);
  // The revalidation must run before any actual stage/upload call (bare
  // mentions of these names in comments are fine — only real calls matter).
  assert.doesNotMatch(preStageBody, /adapter\.stageUpsert|adapter\.stageDelete|transport\.sendMutations|\.runOnce\(/);
});

test('Phase 2B-8: the silent-duplicate release-blocker regression test exists', () => {
  const guestMergeTests = readFileSync(
    new URL('../ios-native/Kitchen Manager/KitchenManagerTests/GuestMergeTests.swift', import.meta.url),
    'utf8'
  );
  assert.match(guestMergeTests, /func testProductionPreviewDoesNotSilentlyCreateBusinessEquivalentRemoteItem\(\)/);
});

test('Phase 2B-8: all feature flags remain default NO, and no new flag was introduced for this fix', () => {
  for (const value of [sharedConfig, exampleConfig]) {
    assert.match(value, /SYNC_ENABLED\s*=\s*NO/);
    assert.match(value, /INVENTORY_SYNC_ENABLED\s*=\s*NO/);
    assert.match(value, /INVENTORY_MERGE_UI_ENABLED\s*=\s*NO/);
  }
});

test('Phase 2B-8: no service-role key, no automatic sync trigger, and Shopping/Plan/Recipe remain unwired by this fix', () => {
  assert.doesNotMatch(controller, /service_role|SERVICE_ROLE/i);
  assert.doesNotMatch(controller, /Timer\(|BGTaskScheduler|Realtime/);
  const newProductionSurface = controller.slice(controller.indexOf('func preparePreview'), controller.indexOf('func resolveConflict'));
  assert.doesNotMatch(newProductionSurface, /Shopping|TodayPlan|WeeklyPlan|Recipe|Favorite|Frequent/);
});

// UI-5B2B-B2A: the preview summary is corrected and the resolved results become
// visible, entirely through a new pure presentation mapping. The model's own
// aggregates and every write path stay exactly as they were.

const summaryPresentation = read('KitchenManager/Synchronization/InventoryMergeSummaryPresentation.swift');

test('UI-5B2B-B2A: the summary mapping is pure — no controller, persistence, AuthStore, transport or SwiftUI', () => {
  // Doc comments legitimately name the things the mapping must not touch
  // ("never touches a controller"), so the rule applies to code lines only.
  const code = summaryPresentation
    .split('\n').filter(line => !line.trim().startsWith('///')).join('\n');
  assert.doesNotMatch(code, /import SwiftUI/);
  assert.doesNotMatch(code, /GuestMergeController|SyncPersistence|AuthStore|SyncTransport|SyncCoordinator/);
  assert.doesNotMatch(code, /URLSession|stageUpsert|saveGuestMergeSession|resolveConflict/);
});

test('UI-5B2B-B2A:每个 summary 数字使用约定的 predicate', () => {
  assert.match(summaryPresentation, /static func willCreate[\s\S]{0,120}action == \.create && !c\.needsDecision/);
  assert.match(summaryPresentation, /static func willUpdate[\s\S]{0,120}action == \.update && !c\.needsDecision/);
  assert.match(summaryPresentation, /static func keptRemote[\s\S]{0,160}conflictReason != nil && c\.userChoice == \.keepRemote/);
  assert.match(summaryPresentation, /static func skippedThisTime[\s\S]{0,160}conflictReason != nil && c\.userChoice == \.skip/);
  assert.match(summaryPresentation, /static func stillNeedsDecision[\s\S]{0,120}c\.needsDecision/);
  assert.match(summaryPresentation, /static func nothingToDo[\s\S]{0,160}action == \.skip && c\.conflictReason == nil/);
});

test('UI-5B2B-B2A: conflict reason breakdown 只统计 needsDecision', () => {
  assert.match(
    summaryPresentation,
    /conflictReason == reason && \$0\.needsDecision/,
    'conflict reason 统计必须同时要求 needsDecision，否则已解决项会被算成需要处理'
  );
});

test('UI-5B2B-B2A: the preview no longer derives its counts from the plan aggregates it used to overcount with', () => {
  const previewSection = views.slice(views.indexOf('struct InventoryMergePreviewView'), views.indexOf('struct InventoryMergeConflictView'));
  for (const stale of ['plan.quantityConflicts', 'plan.expiryConflicts', 'plan.metadataConflicts', 'plan.ambiguousConflicts']) {
    assert.doesNotMatch(previewSection, new RegExp(stale.replace('.', '\\.')));
  }
  assert.match(previewSection, /InventoryMergeSummaryPresentation\.make/);
  assert.match(previewSection, /InventoryMergeConflictReasonPresentation\.make/);
});

test('UI-5B2B-B2A: 保留家庭与本次跳过在预览中可见', () => {
  const previewSection = views.slice(views.indexOf('struct InventoryMergePreviewView'), views.indexOf('struct InventoryMergeConflictView'));
  assert.match(previewSection, /guestMergeSummaryKeptRemote/);
  assert.match(previewSection, /guestMergeSummarySkipped/);
  assert.match(previewSection, /guestMergeSummaryStillNeedsDecision/);
});

test('UI-5B2B-B2B: the resolved review screen is controller-backed and read-only without editing rights', () => {
  // Bounded at the editor: `InventoryMergeChoiceEditorView` now sits between
  // the review and the progress view, and it legitimately resolves conflicts.
  const reviewSection = views.slice(
    views.indexOf('struct InventoryMergeResolvedReviewView'),
    views.indexOf('struct InventoryMergeChoiceEditorView')
  );
  assert.match(reviewSection, /@ObservedObject var controller: GuestMergeController/);
  assert.match(reviewSection, /private var plan: InventoryMergePlan\? \{ controller\.plan \}/);
  // The review itself never resolves, never renders choice rows, never pickers.
  assert.doesNotMatch(reviewSection, /resolveConflict/);
  assert.doesNotMatch(reviewSection, /InventoryMergeConflictChoiceRow|pickerStyle|Picker\(/);
});

test('UI-5B2B-B2A: the review screen asserts no per-item upload state in either direction', () => {
  const reviewSection = views.slice(
    views.indexOf('struct InventoryMergeResolvedReviewView'),
    views.indexOf('struct InventoryMergeProgressView')
  );
  // A session that partially confirmed carries a plan mixing already-uploaded
  // choices with newly-decided ones, so "尚未上传" would be false there — and
  // "已上传" would be false before a first confirm. The footer claims neither.
  for (const banned of ['已上传', '已合并', '尚未上传']) {
    assert.doesNotMatch(reviewSection, new RegExp(banned));
  }
  assert.match(reviewSection, /InventoryMergeReviewFooterPresentation\.make\(session: session\)/);
});

test('UI-5B2B-B2A: the neutral review footer never asserts an upload state', () => {
  const footerSection = summaryPresentation.slice(
    summaryPresentation.indexOf('struct InventoryMergeReviewFooterPresentation'),
    summaryPresentation.indexOf('struct InventoryMergeConfirmationPresentation')
  );
  assert.match(footerSection, /不代表各条目的当前上传状态/);
  for (const banned of ['尚未上传', '已上传', '已合并', '即将上传']) {
    assert.doesNotMatch(footerSection, new RegExp(banned));
  }
});

test('UI-5B2B-B2A: a session that already confirmed never gets the first-pass definite copy', () => {
  // The post-partial branch must be evaluated before every other case, so a
  // partly-uploaded session can never fall through to 确认合并库存 /
  // 完成，不上传任何条目 / 先合并其余 N 条.
  const confirmSection = summaryPresentation.slice(
    summaryPresentation.indexOf('struct InventoryMergeConfirmationPresentation')
  );
  assert.match(confirmSection, /hasUploadedAlready\(session: session\)/);
  const guardIndex = confirmSection.indexOf('hasUploadedAlready');
  for (const later of ['完成，不上传任何条目', '确认当前处理结果', '先合并其余', '确认合并库存']) {
    assert.ok(
      guardIndex < confirmSection.indexOf(later),
      `已上传守卫必须先于 ${later} 分支`
    );
  }
  assert.match(confirmSection, /确认当前处理计划/);
  // Exact user-facing sentence, with no developer-facing meta-narration.
  assert.match(confirmSection, /当前页面汇总本次会话的整体计划，系统会根据当前同步状态继续处理。/);
  for (const banned of ['文案', '重新定义', '尚未上传', '已经上传', '已经合并']) {
    assert.doesNotMatch(confirmSection, new RegExp(banned));
  }
});

test('UI-5B2B-B2A: summary row labels do not promise that every listed item is still upcoming', () => {
  const previewSection = views.slice(views.indexOf('struct InventoryMergePreviewView'), views.indexOf('struct InventoryMergeConflictView'));
  assert.match(previewSection, /LabeledContent\("计划新增"/);
  assert.match(previewSection, /LabeledContent\("计划更新"/);
  assert.doesNotMatch(previewSection, /LabeledContent\("将新增"/);
  assert.doesNotMatch(previewSection, /LabeledContent\("将更新"/);
});

test('UI-5B2B-B2A: the presentation mapping reads only immutable session fields', () => {
  // Allowed: status/confirmedAt/uploadedItemCount/conflictCount/failedCount.
  // Never a controller, persistence, or network handle.
  assert.doesNotMatch(summaryPresentation, /SyncPersistence|SyncTransport|SyncCoordinator/);
  // `GuestMergeSession` is read for confirm history; a controller never is.
  const code = summaryPresentation.split('\n').filter(line => !line.trim().startsWith('///')).join('\n');
  assert.doesNotMatch(code, /GuestMergeController/);
  const sessionFieldCode = summaryPresentation
    .split('\n').filter(line => !line.trim().startsWith('///')).join('\n');
  assert.doesNotMatch(sessionFieldCode, /URLSession|stageUpsert|saveGuestMergeSession|resolveConflict|confirmMerge\(/);
  assert.match(summaryPresentation, /session\.confirmedAt != nil \|\| session\.uploadedItemCount > 0/);
});

test('UI-5B2B-B2A: the post-partial-confirm fixture really carries confirm history', () => {
  const fixtures = read('KitchenManager/Authentication/AccountLifecyclePresentation.swift');
  assert.match(fixtures, /case postPartialConfirmResumed = "UITEST_MERGE_SUMMARY_POST_PARTIAL_CONFIRM"/);
  assert.match(
    fixtures,
    /confirmedAt: \(self == \.postPartialConfirmResumed \|\| self == \.confirmedButNothingUploaded\) \? now : nil/
  );
  assert.match(fixtures, /uploadedItemCount: self == \.postPartialConfirmResumed \? 2 : 0/);
});

test('UI-5B2B-B2A: confirmation copy covers zero-upload without ever saying 先合并其余 0 条', () => {
  assert.match(summaryPresentation, /完成，不上传任何条目/);
  assert.match(summaryPresentation, /确认当前处理结果/);
  assert.match(summaryPresentation, /先合并其余 \\\(uploadable\) 条/);
  // The zero-uploadable branch must be checked before the partial-merge branch.
  const zeroIndex = summaryPresentation.indexOf('确认当前处理结果');
  const partialIndex = summaryPresentation.indexOf('先合并其余');
  assert.ok(zeroIndex < partialIndex, 'zero-upload 分支必须先于 partial-merge 分支');
});

test('UI-5B2B-B2A: confirm stays enabled and its action is unchanged', () => {
  const previewSection = views.slice(views.indexOf('struct InventoryMergePreviewView'), views.indexOf('struct InventoryMergeConflictView'));
  assert.match(previewSection, /await controller\.confirmMerge\(authStore: authStore\)/);
  assert.match(previewSection, /\.disabled\(controller\.isBusy \|\| plan == nil \|\| controller\.clientUpgradeRequired\)/);
});

test('UI-5B2B-B2A: 分组只依赖 conflictReason 与 userChoice，不新增 persisted enum', () => {
  assert.match(
    summaryPresentation,
    /guard candidate\.conflictReason != nil, let choice = candidate\.userChoice else \{ return nil \}/
  );
  assert.doesNotMatch(summaryPresentation, /: String, Codable|Codable, Sendable/);
});

test('UI-5B2B-B2A: the summary fixtures are DEBUG-only and seed a previewReady session', () => {
  const fixtures = read('KitchenManager/Authentication/AccountLifecyclePresentation.swift');
  assert.match(fixtures, /^#if DEBUG/m);
  assert.match(fixtures, /enum AccountLifecycleSummaryFixture: String, CaseIterable/);
  assert.match(fixtures, /status: \.previewReady/);
  // Seeding is a single local persistence write; never a coordinator run.
  // Bounded to the enum itself: the pre-existing fixture transport further down
  // the file legitimately declares a throwing `sendMutations` stub.
  const summaryFixtureSection = fixtures.slice(
    fixtures.indexOf('enum AccountLifecycleSummaryFixture'),
    fixtures.indexOf('final class AccountLifecycleFixtureAuthService')
  );
  assert.doesNotMatch(summaryFixtureSection, /runOnce|stageUpsert|sendMutations|resolveConflict/);
});

// ---------------------------------------------------------------------------
// UI-5B2B-B2B: safe editing of recorded conflict choices.
// Each guarantee is its own block so a failure names what broke.
// ---------------------------------------------------------------------------

const b2bModels = read('KitchenManager/Synchronization/GuestMergeModels.swift');
const b2bController = read('KitchenManager/Synchronization/GuestMergeController.swift');
const b2bViews = read('KitchenManager/GuestMergeViews.swift');
const b2bFixtures = read('KitchenManager/Authentication/AccountLifecyclePresentation.swift');
const b2bProbe = read('KitchenManager/Authentication/RestartUITestProbe.swift');
const b2bContent = read('KitchenManager/ContentView.swift');

test('UI-5B2B-B2B: activeForkedLocalItemId requires all four conditions', () => {
  const section = b2bModels.slice(
    b2bModels.indexOf('var activeForkedLocalItemId'),
    b2bModels.indexOf('/// A conflict that still needs an explicit user decision')
  );
  assert.match(section, /userChoice == \.keepBoth/);
  assert.match(section, /action == \.create/);
  assert.match(section, /remoteItemId == localItemId/);
  assert.match(section, /let reserved = forkedLocalItemId/);
});

test('UI-5B2B-B2B: applyingChoice retains the reserved fork on non-keepBoth choices', () => {
  const section = b2bModels.slice(b2bModels.indexOf('func applyingChoice'));
  const body = section.slice(0, section.indexOf('return copy'));
  // No branch may clear it any more.
  assert.doesNotMatch(body, /copy\.forkedLocalItemId = nil/);
});

test('UI-5B2B-B2B: repeated keepBoth reuses the existing reservation', () => {
  assert.match(b2bModels, /forkedLocalItemId \?\? UUID\(\)/);
});

test('UI-5B2B-B2B: confirm staging selects the fork by active identity', () => {
  assert.match(b2bController, /if let forkedId = candidate\.activeForkedLocalItemId/);
});

test('UI-5B2B-B2B: confirm outcome verification uses the active identity', () => {
  assert.match(b2bController, /let entityIdToCheck = candidate\.activeForkedLocalItemId \?\? candidate\.localItemId/);
});

test('UI-5B2B-B2B: no upload-identity branch reads the raw reserved fork', () => {
  // Every remaining mention in the controller must be the active accessor.
  const allReads = b2bController.match(/candidate\.(active)?ForkedLocalItemId/g) || [];
  const rawReads = allReads.filter(match => !match.includes('active'));
  assert.equal(rawReads.length, 0, `上传路径不得直接读取 raw reserved fork：${rawReads.length} 处`);
  assert.ok(allReads.length > 0, '应存在 active fork 读取');
});

test('UI-5B2B-B2B: resolveConflict branches on unresolved versus resolved', () => {
  const section = b2bController.slice(b2bController.indexOf('func resolveConflict'));
  assert.match(section, /if candidate\.userChoice == nil \{/);
  assert.match(section, /\} else \{/);
});

test('UI-5B2B-B2B: every confirm-history signal blocks a resolved edit', () => {
  const section = b2bController.slice(b2bController.indexOf('func resolveConflict'));
  assert.match(section, /current\.confirmedAt == nil/);
  assert.match(section, /current\.uploadedItemCount == 0/);
  assert.match(section, /current\.createdEntityIds\.isEmpty/);
});

test('UI-5B2B-B2B: resolved re-edit is not permitted from the conflict root', () => {
  const section = b2bController.slice(b2bController.indexOf('func resolveConflict'));
  const resolvedBranch = section.slice(section.indexOf('} else {'), section.indexOf('applyingChoice(choice)'));
  assert.doesNotMatch(resolvedBranch, /== \.conflict/);
});

test('UI-5B2B-B2B: the dedicated edit error never clears the global error', () => {
  const section = b2bController.slice(b2bController.indexOf('func resolveConflict'));
  const success = section.slice(section.indexOf('conflictChoiceErrorMessage = nil'), section.indexOf('applyingChoice(choice)'));
  assert.doesNotMatch(success, /lastErrorMessage = nil/);
});

test('UI-5B2B-B2B: edit errors are scoped to the candidate that produced them', () => {
  assert.match(b2bController, /conflictChoiceErrorCandidateId/);
  assert.match(b2bController, /func conflictChoiceError\(for candidateId: UUID\)/);
  assert.match(b2bController, /func clearConflictChoiceError\(unless candidateId: UUID\)/);
});

test('UI-5B2B-B2B: the preview exposes a pre-confirm conflict entry', () => {
  const previewSection = b2bViews.slice(
    b2bViews.indexOf('struct InventoryMergePreviewView'),
    b2bViews.indexOf('struct InventoryMergeConflictChoicePresentation')
  );
  assert.match(previewSection, /确认前处理冲突/);
  assert.match(previewSection, /guestMergePreConfirmConflictLink/);
  assert.match(previewSection, /mode: \.preConfirmNavigation/);
});

test('UI-5B2B-B2B: the pre-confirm destination never fakes a session status', () => {
  const conflictSection = b2bViews.slice(
    b2bViews.indexOf('enum InventoryMergeConflictPresentationMode'),
    b2bViews.indexOf('struct InventoryMergeResolvedReviewView')
  );
  assert.doesNotMatch(conflictSection, /status = \./);
  assert.doesNotMatch(conflictSection, /\.conflict\b.*=/);
});

test('UI-5B2B-B2B: the review reads live controller state, not a captured plan', () => {
  const reviewSection = b2bViews.slice(
    b2bViews.indexOf('struct InventoryMergeResolvedReviewView'),
    b2bViews.indexOf('struct InventoryMergeChoiceEditorView')
  );
  assert.match(reviewSection, /@ObservedObject var controller: GuestMergeController/);
  assert.match(reviewSection, /private var plan: InventoryMergePlan\? \{ controller\.plan \}/);
  assert.doesNotMatch(reviewSection, /let plan: InventoryMergePlan/);
});

test('UI-5B2B-B2B: the editor stores only a candidate id and looks it up live', () => {
  const editorSection = b2bViews.slice(b2bViews.indexOf('struct InventoryMergeChoiceEditorView'));
  assert.match(editorSection, /let candidateId: UUID/);
  assert.match(editorSection, /controller\.plan\?\.candidates\.first \{ \$0\.localItemId == candidateId \}/);
  assert.doesNotMatch(editorSection, /let candidate: InventoryMergeCandidate\n/);
});

test('UI-5B2B-B2B: post-confirm review hides every editing entry', () => {
  const reviewSection = b2bViews.slice(
    b2bViews.indexOf('struct InventoryMergeResolvedReviewView'),
    b2bViews.indexOf('struct InventoryMergeChoiceEditorView')
  );
  assert.match(reviewSection, /private var canEdit: Bool \{ availability\.isEditable \}/);
  assert.match(reviewSection, /if canEdit \{/);
  assert.match(reviewSection, /此会话已经开始同步，已记录的处理方式仅供查看。/);
});

test('UI-5B2B-B2B: no segmented picker returns on any editing surface', () => {
  assert.doesNotMatch(b2bViews, /pickerStyle\(\.segmented\)/);
});

test('UI-5B2B-B2B: restart seed and resume bypass the generic 测试库存 reset', () => {
  const initSection = b2bContent.slice(0, b2bContent.indexOf('var body: some Scene'));
  assert.match(initSection, /switch AccountLifecycleSummaryFixture\.restartLaunchMode/);
  assert.match(initSection, /case \.seed:/);
  assert.match(initSection, /case \.resume:\s*\n\s*break/);
  // The generic reset is now only reachable in `.none`.
  const noneBranch = initSection.slice(initSection.indexOf('case .none:'));
  assert.match(noneBranch, /addInventory\(name: "测试库存"/);
});

test('UI-5B2B-B2B: the resume launch performs no fixture seeding', () => {
  assert.match(b2bFixtures, /if isResumeOnlyLaunch \{ return true \}/);
});

test('UI-5B2B-B2B: preparePreview records its real branch outcome', () => {
  assert.match(b2bController, /uiTestPreviewOrigin = \.regeneratedInvalidPlan/);
  assert.match(b2bController, /uiTestPreviewOrigin = \.resumedExisting/);
  assert.match(b2bController, /uiTestPreviewOrigin = \.createdNew/);
});

test('UI-5B2B-B2B: every restart probe and seam is DEBUG-only', () => {
  // The whole probe file is wrapped, with the terminating #endif last.
  assert.match(b2bProbe, /^import Foundation\nimport SwiftUI\n\n#if DEBUG/);
  assert.match(b2bProbe.trimEnd(), /#endif$/);
  assert.equal((b2bProbe.match(/#if DEBUG/g) || []).length, 1);
  assert.equal((b2bProbe.match(/#endif/g) || []).length, 1);
  // Controller instrumentation and seam.
  for (const symbol of ['UITestPreviewOrigin', 'markSyncStartedForUITesting']) {
    const index = b2bController.indexOf(symbol);
    assert.ok(index > 0, `${symbol} 应存在`);
    const before = b2bController.slice(0, index);
    const opens = (before.match(/#if DEBUG/g) || []).length;
    const closes = (before.match(/#endif/g) || []).length;
    assert.ok(opens > closes, `${symbol} 必须位于 #if DEBUG 内`);
  }
});

test('UI-5B2B-B2B: the sync-start seam is a visible row, so it is also gated on editability', () => {
  // It renders as an ordinary Form row rather than a hidden probe, so the
  // launch argument alone is not enough: a read-only review must not show it,
  // otherwise it appears in the post-confirm screenshot.
  assert.match(
    b2bViews,
    /if canEdit, ProcessInfo\.processInfo\.arguments\.contains\("UITEST_ALLOW_SYNC_START_SEAM"\)/
  );
  const index = b2bViews.indexOf('uitest.markSyncStarted');
  assert.ok(index > 0);
  const before = b2bViews.slice(0, index);
  assert.ok(
    (before.match(/#if DEBUG/g) || []).length > (before.match(/#endif/g) || []).length,
    'seam 必须位于 #if DEBUG 内'
  );
});

test('UI-5B2B-B2B: restart probes use fixed identifiers, never interpolated ones', () => {
  assert.match(b2bProbe, /static let forkIdentity = "uitest\.restart\.forkIdentity"/);
  assert.doesNotMatch(b2bProbe, /accessibilityIdentifier\("uitest\.restart\.[a-zA-Z]*\\\(/);
});
