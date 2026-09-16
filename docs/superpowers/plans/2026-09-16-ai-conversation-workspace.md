# Kitchen Manager AI Conversation Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the production `Kitchen AI` conversation workspace approved in the design spec: one local-first multi-turn workspace entered from Home and Planner, with live kitchen context, streaming responses, native structured blocks, safe domain actions, history, expiry/reactivation, and deterministic Undo/retry semantics.

**Architecture:** Keep dialogue ownership separate from kitchen truth. A local SwiftData `ConversationStore` owns conversations/messages/action receipts/context provenance; `ConversationContextAssembler` selects fresh domain context; a stateless streaming backend turns model text/tool calls into NDJSON events; `ConversationOrchestrator` runs the client-side tool loop; `ConversationActionCoordinator` is the only conversation-side mutation gateway, and all writes go through authoritative Kitchen/Recipe domain APIs. Home and Planner only supply `AIConversationEntryContext` and never own separate chat state.

**Tech Stack:** Swift 6 / SwiftUI / SwiftData / Foundation URLSession streaming, XCTest/XCUITest, Node.js / Express, OpenAI-compatible chat-completions providers (Gemini/Groq through the existing server routing), existing Apple Foundation Models recipe-candidate path unchanged.

**Spec:** `docs/superpowers/specs/2026-09-16-ai-conversation-workspace-design.md`

## Global Constraints

- Preserve `KitchenStore.plans` as canonical ordinary-meal schedule truth; Special Plan remains its own domain model.
- AI is a capability, not a second visual brand. Extend Quiet Kitchen R3.1; no AI gradient, glow, dashboard chrome, or new bottom tab.
- Keep the product Guest-first and Local-first. V1 conversation history is device-local SwiftData only: no Supabase sync and no current backup/restore payload change.
- Never upload the full kitchen dataset by default. `ConversationContextAssembler` sends only context relevant to the current turn and honors one-turn source exclusions.
- V1 input is text only. Do not expose a tappable image/file attachment action.
- V1 content blocks are exactly: `text`, `recipe`, `plannerPreview`, `contextResult`, `actionStatus`, `error`.
- Low-risk actions may execute after validation and must expose deterministic Undo; medium/high-risk actions show a real diff and require explicit confirmation.
- A model never mutates KitchenStore/RecipeStore directly. Model mutation intent becomes a typed `AIActionProposal`, then `ConversationActionCoordinator` validates and executes it.
- Every mutation carries an `actionID` and `idempotencyKey`; retry must not duplicate a succeeded mutation.
- Conversation memory is not live truth. Inventory, Planner, Recipe, and Special Plan facts are reread from current domain state when a turn depends on them.
- Initial active periods: `.general` 48h; `.dailyMeal` 48h; `.weeklyPlanning` later of 48h after activity or 24h after referenced week end; `.specialPlan` later of 48h after activity or 24h after event; pinned does not auto-expire.
- Free/paid retention differences are policy seams only in V1. Do not add billing/subscription UI or persist a tier name as truth.
- The globally selected AI provider remains the user preference. The conversation UI has no provider picker. Explicit Apple selection is capability-unavailable for full conversation V1; do not silently promote the recipe-only Apple path to tool-capable chat.
- Preserve existing `/api/ai-chat` semantics and `AIChatService` callers. The new streaming contract is additive.
- Never expose chain-of-thought, raw reasoning, token counts, provider diagnostics, arbitrary tool schemas, secrets, or full request bodies in user UI/logs.
- Custom interactive controls retain the app's 44pt target and support Dynamic Type, VoiceOver, Dark Mode, safe areas, and Reduce Motion.
- Swift/SwiftUI/Xcode-facing work is validated through Xcode MCP when available; CLI `xcodebuild` is the fallback. Test selection remains governed by `docs/development/TESTING.md`.

### Validation preflight used by all iOS tasks

At execution time, first inspect `AGENTS.md`, `docs/development/TESTING.md`, and the approved spec. Create an isolated worktree using `superpowers:using-git-worktrees`. Fetch origin and verify the worktree base is the reviewed `origin/main` before editing.

When Xcode MCP is available, use its build/test tools as the authoritative iOS evidence. For CLI fallback, choose an actually installed simulator once per execution session:

```bash
xcrun simctl list devices available
SIMULATOR_NAME="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ && /(Booted|Shutdown)/ { name=$1; sub(/^[[:space:]]*/, "", name); sub(/[[:space:]]*$/, "", name); print name; exit }')"
test -n "$SIMULATOR_NAME"
export IOS_DEST="platform=iOS Simulator,name=$SIMULATOR_NAME"
```

Focused test command shape:

```bash
xcodebuild \
  -project "ios-native/Kitchen Manager/Kitchen Manager.xcodeproj" \
  -scheme KitchenManager \
  -destination "$IOS_DEST" \
  -parallel-testing-enabled NO \
  -only-testing:KitchenManagerTests/TestClassName \
  test
```

The Xcode project uses a file-system synchronized root group, so new Swift files under the synchronized app/test directories should not require hand-editing `project.pbxproj`. If Xcode does not see a new file, diagnose the synchronized-group exception rather than blindly patching project membership.

---

## File/Module Map

Create focused units rather than growing `HomeView.swift`, `PlannerView.swift`, or `KitchenStore.swift` into conversation subsystems:

```text
ios-native/Kitchen Manager/KitchenManager/
├── AIConversationModels.swift              # stable conversation/block/action value types
├── ConversationRetentionPolicy.swift       # expiry + affinity policy, no UI
├── ConversationStore.swift                 # local conversation/history state over persistence
├── ConversationContextAssembler.swift      # bounded recent history + fresh live context
├── AIConversationTransport.swift           # NDJSON streaming client protocol + production transport
├── AIConversationProviderRouter.swift      # global provider capability decision only
├── ConversationResponseInterpreter.swift   # wire tool calls -> typed read/action/block requests
├── ConversationActionCoordinator.swift     # risk, validation, idempotency, execute, Undo
├── ConversationOrchestrator.swift          # turn state machine + provider/tool loop
├── AIConversationController.swift          # SwiftUI-facing state and commands
├── AIConversationView.swift                # workspace shell, empty state, composer, nav
├── AIConversationBlocks.swift              # six block renderers
├── AIConversationHistoryView.swift         # pinned/recent/ended management
├── GeneratedRecipeMaterializer.swift       # shared generated recipe resolve/save/compensation helper
└── Persistence/
    ├── ConversationRecords.swift            # 4 SwiftData records, no relationship graph
    └── ConversationPersistence.swift        # atomic CRUD + failing implementation

src/server/services/
└── ai-conversation.js                       # fixed tool allowlist + NDJSON stream event helpers

server.js                                    # additive POST /api/ai-conversation
src/server/services/ai-client.js             # additive provider streaming primitive

ios-native/Kitchen Manager/KitchenManagerTests/
├── AIConversationModelsTests.swift
├── ConversationRetentionPolicyTests.swift
├── ConversationPersistenceTests.swift
├── AIConversationSchemaUpgradeTests.swift
├── ConversationDomainToolsTests.swift
├── AIConversationTransportTests.swift
├── ConversationContextAssemblerTests.swift
├── ConversationActionCoordinatorTests.swift
├── ConversationOrchestratorTests.swift
└── AIConversationControllerTests.swift

ios-native/Kitchen Manager/KitchenManagerUITests/
└── AIConversationWorkspaceUITests.swift

test/
└── ai-conversation-stream.test.mjs
```

Existing files intentionally modified by the plan:

- `Persistence/KitchenPersistenceFactory.swift`: add conversation persistence to the shared bundle/schema/failure path.
- `KitchenStore.swift`: add narrow persist-before-publish Planner/Special Plan/Shopping APIs required by AI actions; existing call sites keep existing semantics.
- `SpecialPlanMenuAcceptance.swift`: reuse the extracted generated-recipe materializer and safe Special Plan write without changing existing UX.
- `Recipe.swift`: only if a small visibility/API adjustment is required to let the shared materializer call existing fingerprint/save/delete behavior; do not redesign RecipeStore.
- `Networking/APIClient.swift`: add one centralized line-stream request path; no direct `URLSession.shared` in conversation code.
- `ContentView.swift`: composition root for conversation store/controller and DEBUG fake transport.
- `HomeView.swift`: one Kitchen AI entry and destination.
- `PlannerView.swift`: one Kitchen AI route/tool-menu entry carrying the displayed week anchor.
- `server.js`, `src/server/services/ai-client.js`: additive streaming endpoint/primitive.
- `KitchenManagerTests/BackupValidationTests.swift`: update the one direct `KitchenPersistenceBundle(...)` constructor after the bundle gains `conversations`.
- Existing AI/provider tests and server-route tests: pin no-regression behavior.

---

### Task 1: Define conversation values, retention, and affinity as pure logic

**Files:**
- Create: `ios-native/Kitchen Manager/KitchenManager/AIConversationModels.swift`
- Create: `ios-native/Kitchen Manager/KitchenManager/ConversationRetentionPolicy.swift`
- Test: `ios-native/Kitchen Manager/KitchenManagerTests/AIConversationModelsTests.swift`
- Test: `ios-native/Kitchen Manager/KitchenManagerTests/ConversationRetentionPolicyTests.swift`

**Interfaces:**
- Produces: `AIConversation`, `AIConversationMessage`, `AIContentBlock`, `AIConversationActionRecord`, `AIContextSnapshot`, `AIConversationEntryContext`, `AIConversationTurnState`, `AIActionProposal`, `AIActionRisk`.
- Produces: `ConversationRetentionPolicy.activeUntil(for:lastActivityAt:calendar:)` and `ConversationAffinityResolver.bestConversation(for:from:now:)`.
- Consumes: existing `Recipe`, `MealPlanItem`, and `SpecialPlanDish` only as Codable snapshots/references; no store access.

- [ ] **Step 1: Write failing model round-trip tests**

Pin the six-block closed set, message state, action status, and transient/canonical recipe snapshot behavior:

```swift
func testContentBlocksRoundTripWithoutArbitraryWidgetCase() throws {
    let recipe = Recipe(id: "ai-probe", title: "番茄鸡蛋面", ingredients: ["番茄", "鸡蛋"], steps: ["炒熟"])
    let blocks: [AIContentBlock] = [
        .text(.init(text: "推荐两个选择")),
        .recipe(.init(recipe: recipe, isTransient: true, reason: "优先使用临期番茄")),
        .plannerPreview(.init(title: "周三 · 晚餐", changes: [
            .init(targetID: UUID(), before: "宫保鸡丁", after: "清蒸鲈鱼")
        ], pendingActionID: UUID())),
        .contextResult(.init(title: "快过期", rows: [.init(label: "青椒", detail: "明天") ])),
        .actionStatus(.init(message: "已加入今晚", actionID: UUID(), canUndo: true)),
        .error(.init(message: "暂时无法读取库存", retry: .contextRead))
    ]
    let data = try JSONEncoder().encode(blocks)
    XCTAssertEqual(try JSONDecoder().decode([AIContentBlock].self, from: data), blocks)
}
```

Also test `AIConversationMessage` round-trip and that a user-edited title is not represented by a subscription/tier field.

- [ ] **Step 2: Run focused model tests and confirm RED**

Run the focused `AIConversationModelsTests` class through Xcode MCP or the CLI shape in the preflight. Expected failure: conversation types are undefined.

- [ ] **Step 3: Implement the closed value model**

Use explicit Codable enums rather than `[String: Any]` payloads. The core shapes are:

```swift
nonisolated enum AIConversationLifecycleType: String, Codable, Sendable {
    case general, dailyMeal, weeklyPlanning, specialPlan
}

nonisolated enum AIConversationAffinity: String, Codable, Sendable {
    case general, dailyMeal, weeklyPlanning, specialPlan
}

nonisolated enum AIConversationRole: String, Codable, Sendable {
    case user, assistant, systemStatus
}

nonisolated enum AIConversationMessageState: String, Codable, Sendable {
    case pending, streaming, completed, cancelled, failed
}

nonisolated enum AIConversationTurnState: Equatable, Sendable {
    case idle, preparingContext, requesting, streaming, toolRequested
    case executing, awaitingConfirmation, completed, cancelled, failed
}

nonisolated enum AIConversationEntryContext: Equatable, Sendable {
    case home
    case planner(weekStart: Date, specialPlanID: UUID?)
}
```

Define the six `AIContentBlock` cases and small typed payloads with stable UUID block ids. `AIRecipeBlock` stores a `Recipe` snapshot plus `isTransient`; history rendering must not depend on a future recipe-store lookup, while mutations re-resolve/materialize at execution time.

Define semantic action proposals as a closed enum, not model-authored strings:

```swift
nonisolated enum AIActionProposal: Codable, Equatable, Sendable {
    case addRecipeToTonight(recipe: AIRecipeBlock)
    case replacePlannedMeal(planID: UUID, replacement: AIRecipeBlock)
    case applyPlannerChanges(changes: [AIPlannerMealChange])
    case replaceSpecialPlanDishes(planID: UUID, changes: [AISpecialPlanDishChange])
    case addShoppingItems(items: [AIShoppingItemProposal])
}
```

- [ ] **Step 4: Write failing retention/affinity tests**

Use a fixed Gregorian calendar and fixed dates. Cover the exact approved policy:

```swift
func testSpecialPlanExpiryUsesLaterOfActivityOrEventGrace() {
    let now = date("2026-09-16T10:00:00-04:00")
    let event = date("2026-09-20T18:30:00-04:00")
    let conversation = AIConversation.fixture(
        lifecycleType: .specialPlan,
        lastActivityAt: now,
        anchorDate: event
    )
    XCTAssertEqual(
        policy.activeUntil(for: conversation, lastActivityAt: now, calendar: calendar),
        event.addingTimeInterval(24 * 60 * 60)
    )
}
```

Also cover 48h general/daily, week-end + 24h, pinned non-expiry, Home preference for daily/general, Planner preference for matching week/special anchor, and no relevant match returning nil.

- [ ] **Step 5: Implement `ConversationRetentionPolicy` and affinity resolver**

Keep dates deterministic and dependency-inject `Calendar`; do not read subscription state. `isPinned` returns `.distantFuture` (or a documented non-expiring sentinel) from the V1 policy. Week expiry derives the referenced week's end from `anchorDate`; Special Plan derives from the event anchor.

- [ ] **Step 6: Run both focused test classes**

Expected: PASS through Xcode MCP / focused XCTest.

- [ ] **Step 7: Commit**

```bash
git add "ios-native/Kitchen Manager/KitchenManager/AIConversationModels.swift" \
        "ios-native/Kitchen Manager/KitchenManager/ConversationRetentionPolicy.swift" \
        "ios-native/Kitchen Manager/KitchenManagerTests/AIConversationModelsTests.swift" \
        "ios-native/Kitchen Manager/KitchenManagerTests/ConversationRetentionPolicyTests.swift"
git commit -m "feat(ios): define AI conversation model and retention policy"
```

---

### Task 2: Add local SwiftData conversation persistence and prove schema safety

**Files:**
- Create: `ios-native/Kitchen Manager/KitchenManager/Persistence/ConversationRecords.swift`
- Create: `ios-native/Kitchen Manager/KitchenManager/Persistence/ConversationPersistence.swift`
- Modify: `ios-native/Kitchen Manager/KitchenManager/Persistence/KitchenPersistenceFactory.swift`
- Modify: `ios-native/Kitchen Manager/KitchenManagerTests/BackupValidationTests.swift`
- Test: `ios-native/Kitchen Manager/KitchenManagerTests/ConversationPersistenceTests.swift`
- Test: `ios-native/Kitchen Manager/KitchenManagerTests/AIConversationSchemaUpgradeTests.swift`

**Interfaces:**
- Produces: `ConversationPersistenceProtocol` and `SwiftDataConversationPersistence`.
- Adds: `let conversations: ConversationPersistenceProtocol` to `KitchenPersistenceBundle`.
- Persistence methods used later:

```swift
func loadConversations() throws -> [AIConversation]
func loadMessages(conversationID: UUID) throws -> [AIConversationMessage]
func loadActions(conversationID: UUID) throws -> [AIConversationActionRecord]
func action(idempotencyKey: String) throws -> AIConversationActionRecord?
func createConversationWithFirstMessage(_ conversation: AIConversation, message: AIConversationMessage) throws
func upsertConversation(_ conversation: AIConversation) throws
func upsertMessage(_ message: AIConversationMessage) throws
func upsertAction(_ action: AIConversationActionRecord) throws
func upsertContextSnapshot(_ snapshot: AIContextSnapshot, conversationID: UUID) throws
func deleteConversation(id: UUID) throws
func recoverInterruptedMessages(now: Date) throws
```

- [ ] **Step 1: Write failing persistence round-trip/atomicity tests**

Create an isolated container through `KitchenPersistenceFactory.isolatedInMemory()`. Prove:

1. first message creates conversation + user message together;
2. message block order survives reload;
3. action idempotency key lookup survives reload;
4. context snapshots round-trip;
5. delete removes only the conversation's conversation/message/action/context rows;
6. interrupted `.streaming` assistant messages become `.failed` (not silently completed) on recovery;
7. no conversation appears if `createConversationWithFirstMessage` throws before save.

- [ ] **Step 2: Run `ConversationPersistenceTests` and confirm RED**

Expected: missing conversation persistence types/bundle member.

- [ ] **Step 3: Implement four flat SwiftData records**

Use scalar query columns plus JSON payload; do not introduce a relationship graph:

```swift
@Model final class ConversationRecord {
    @Attribute(.unique) var id: UUID
    var lastActivityAt: Date
    var activeUntil: Date
    var isPinned: Bool
    var affinityRawValue: String
    var payloadData: Data
}

@Model final class ConversationMessageRecord {
    @Attribute(.unique) var id: UUID
    var conversationID: UUID
    var createdAt: Date
    var stateRawValue: String
    var payloadData: Data
}

@Model final class ConversationActionRecord {
    @Attribute(.unique) var actionID: UUID
    var conversationID: UUID
    var idempotencyKey: String
    var statusRawValue: String
    var payloadData: Data
}

@Model final class ConversationContextSnapshotRecord {
    @Attribute(.unique) var id: UUID
    var conversationID: UUID
    var turnID: UUID
    var readAt: Date
    var payloadData: Data
}
```

Every operation in one logical persistence method uses one owned `ModelContext` and rolls back on failure. `createConversationWithFirstMessage` inserts both records before one `context.save()`.

- [ ] **Step 4: Wire the shared bundle/schema and failing fallback**

Add the four records to `KitchenPersistenceFactory.makeContainer`, add `conversations` to `KitchenPersistenceBundle`, instantiate `SwiftDataConversationPersistence(container:)` in `bundle(container:)`, and add `FailingConversationPersistence` in the factory failure path.

Update the direct bundle initializer in `BackupValidationTests.swift` to pass `base.conversations`. Do not add conversation history to `KitchenBackupPayload`.

- [ ] **Step 5: Add the on-disk 14-model -> conversation-schema upgrade test**

Follow `SpecialPlanSchemaUpgradeTests.swift`: build the legacy model list ending at `SpecialPlanRecord`, write representative existing Inventory/TodayPlan/SpecialPlan data, close/reopen through current `KitchenPersistenceFactory.makeContainer`, then assert old data survives, conversation collection is empty, and conversation CRUD works.

- [ ] **Step 6: Run persistence + schema-upgrade focused tests**

Run `ConversationPersistenceTests`, `AIConversationSchemaUpgradeTests`, `SwiftDataConsistencyTests`, and `BackupValidationTests`. Expected: PASS; backup schema/version remains unchanged.

- [ ] **Step 7: Commit**

```bash
git add "ios-native/Kitchen Manager/KitchenManager/Persistence/ConversationRecords.swift" \
        "ios-native/Kitchen Manager/KitchenManager/Persistence/ConversationPersistence.swift" \
        "ios-native/Kitchen Manager/KitchenManager/Persistence/KitchenPersistenceFactory.swift" \
        "ios-native/Kitchen Manager/KitchenManagerTests/ConversationPersistenceTests.swift" \
        "ios-native/Kitchen Manager/KitchenManagerTests/AIConversationSchemaUpgradeTests.swift" \
        "ios-native/Kitchen Manager/KitchenManagerTests/BackupValidationTests.swift"
git commit -m "feat(ios): persist local AI conversations"
```

---

### Task 3: Build AI-safe canonical mutation seams and shared generated-recipe materialization

**Files:**
- Create: `ios-native/Kitchen Manager/KitchenManager/GeneratedRecipeMaterializer.swift`
- Modify: `ios-native/Kitchen Manager/KitchenManager/SpecialPlanMenuAcceptance.swift`
- Modify: `ios-native/Kitchen Manager/KitchenManager/KitchenStore.swift`
- Test: `ios-native/Kitchen Manager/KitchenManagerTests/ConversationDomainToolsTests.swift`
- Test: existing `SpecialPlanMenuTests.swift`, `PlannerMealCRUDTests.swift`, `ShoppingListPersistenceTests.swift`

**Interfaces:**
- Produces shared `GeneratedRecipeMaterializer.materialize(_:recipeStore:)` returning resolved recipes plus ids created by this call and `rollbackCreatedRecipes`.
- Produces persist-before-publish domain methods used only by the later conversation adapter; existing public methods retain existing behavior.
- Planner additions:

```swift
nonisolated struct PlanRecipeReplacement: Equatable, Sendable {
    let planID: UUID
    let recipeID: String
    let recipeName: String
    let plannedServings: Int?
}

@discardableResult
func replacePlanRecipes(_ replacements: [PlanRecipeReplacement]) -> PlanReplacementOutcome
```

- Special Plan additions:

```swift
nonisolated struct SpecialPlanDishReplacement: Equatable, Sendable {
    let dishID: UUID
    let recipeID: String
    let recipeName: String
}

@discardableResult
func replaceSpecialPlanDishes(
    planID: UUID,
    replacements: [SpecialPlanDishReplacement]
) -> SpecialPlanMutationOutcome<SpecialPlan>

@discardableResult
func restoreSpecialPlan(_ snapshot: SpecialPlan) -> SpecialPlanMutationOutcome<SpecialPlan>
```

- Shopping additions:

```swift
nonisolated struct ShoppingMutationReceipt: Equatable, Sendable {
    let before: [KitchenShoppingItem]
    let after: [KitchenShoppingItem]
}

@discardableResult
func addShoppingItemsPersisted(_ additions: [KitchenShoppingItem]) -> ShoppingMutationOutcome<ShoppingMutationReceipt>
@discardableResult
func restoreShoppingItems(_ snapshot: [KitchenShoppingItem]) -> ShoppingMutationOutcome<[KitchenShoppingItem]>
```

- [ ] **Step 1: Write failing mutation-safety tests**

Tests must prove all-or-none semantics under injected persistence failures:

- two planned-meal replacements either both persist or neither publishes;
- replacement preserves plan ids/dates, sets replacement recipe id/name, validates servings, and resets replaced `isCooked` to false;
- missing/duplicate plan ids are rejected before write;
- Special Plan replacement preserves title/date/people/constraints and changes only named dish references, all in one durable write;
- Shopping batch uses the existing merge semantics but only publishes after persistence succeeds;
- restore methods are deterministic and persist-first.

- [ ] **Step 2: Extract generated recipe materialization with regression tests still green**

Move the existing conservative resolution rules from `SpecialPlanMenuAcceptance` into `GeneratedRecipeMaterializer`: exact existing id, then exact `RecipeStore.fingerprint`, otherwise create a user recipe. Track only ids created by the current call for compensation.

Core result:

```swift
struct MaterializedRecipeBatch {
    let recipes: [Recipe]
    let createdRecipeIDs: [String]
}
```

Update `SpecialPlanMenuAcceptance.acceptMenu` to call this helper; on later failure, roll back only `createdRecipeIDs`. Run existing Special Plan generation/acceptance tests before continuing.

- [ ] **Step 3: Implement ordinary Planner replacement as one `commitPlans`**

Build a local `updated = plans`, resolve every target id first, reject duplicate/missing targets, apply recipe identity/servings, reset only replaced rows' `isCooked`, then invoke `commitPlans(updated)` exactly once. Do not implement replacement as `removePlan` + `addPlan`.

- [ ] **Step 4: Implement persist-before-publish Special Plan and Shopping helpers**

For Special Plan, create `commitSpecialPlans(_:)` mirroring `commitPlans`: `specialPlanPersistence.replacePlans` first, then suppressed publish. For Shopping, create `commitShoppingItems(_:)` using `shoppingListPersistence.replaceShoppingItems` first, then suppressed publish. Existing legacy setters/callers remain unchanged.

- [ ] **Step 5: Run focused domain regression**

Run `ConversationDomainToolsTests`, `SpecialPlanMenuTests`, `PlannerMealCRUDTests`, `ShoppingListPersistenceTests`, and `SpecialPlanPersistenceTests`. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add "ios-native/Kitchen Manager/KitchenManager/GeneratedRecipeMaterializer.swift" \
        "ios-native/Kitchen Manager/KitchenManager/SpecialPlanMenuAcceptance.swift" \
        "ios-native/Kitchen Manager/KitchenManager/KitchenStore.swift" \
        "ios-native/Kitchen Manager/KitchenManagerTests/ConversationDomainToolsTests.swift"
git commit -m "feat(ios): add safe domain mutations for Kitchen AI"
```

---

### Task 4: Add the finite conversation domain-tool adapter

**Files:**
- Create: `ios-native/Kitchen Manager/KitchenManager/ConversationDomainTools.swift`
- Extend tests: `ios-native/Kitchen Manager/KitchenManagerTests/ConversationDomainToolsTests.swift`

**Interfaces:**
- Produces `AIConversationDomainTooling` for read-only live context and validated mutations.
- Concrete `KitchenConversationDomainTools` owns references to `KitchenStore` and `RecipeStore`; it owns no duplicate kitchen state.
- Required read API:

```swift
func inventoryContext(now: Date) -> AIInventoryContext
func tonightPlanContext(now: Date, calendar: Calendar) -> AITonightPlanContext
func plannerWeekContext(weekStart: Date, calendar: Calendar) -> AIPlannerWeekContext
func specialPlanContext(id: UUID) -> AISpecialPlanContext?
func resolveRecipe(id: String) -> Recipe?
```

- Required mutation API returns typed receipts for later Undo:

```swift
func addRecipeToTonight(_ block: AIRecipeBlock, now: Date) throws -> AIDomainMutationReceipt
func replacePlannedMeals(_ changes: [AIPlannerMealChange]) throws -> AIDomainMutationReceipt
func replaceSpecialPlanDishes(planID: UUID, changes: [AISpecialPlanDishChange]) throws -> AIDomainMutationReceipt
func addShoppingItems(_ items: [AIShoppingItemProposal]) throws -> AIDomainMutationReceipt
func undo(_ receipt: AIDomainMutationReceipt) throws
```

- [ ] **Step 1: Write failing live-read tests**

Seed KitchenStore with ordinary, staple, ready-to-cook, expiring, planned, and Special Plan data. Assert Inventory reads use truthful current values; tonight reads only today's ordinary plans; week reads canonical `KitchenStore.plans` plus current Special Plans; `resolveRecipe` uses RecipeStore.

- [ ] **Step 2: Implement read adapters without prompt formatting**

Return small Codable domain-context structs. Do not build natural-language prompts here; ContextAssembler owns serialization/budgeting later.

- [ ] **Step 3: Write failing mutation/Undo tests including transient recipes**

For `addRecipeToTonight`:

- canonical recipe: add dated plan and receipt points to exact plan id;
- transient generated recipe: materialize through `GeneratedRecipeMaterializer`, then add plan;
- if plan persistence fails, compensate any recipe created by that call;
- Undo removes exact plan; if the action created a user recipe, delete it only when no current ordinary plan or Special Plan still references that id.

For planner/special/shopping, receipt stores the exact pre-mutation snapshot needed by the deterministic restore API.

- [ ] **Step 4: Implement the finite mutation adapter**

Map only the five mutation types approved in the spec. Reject any unsupported action before domain write. Normalize Shopping source to a stable product string such as `Kitchen AI` and keep the existing merge behavior.

- [ ] **Step 5: Run `ConversationDomainToolsTests`**

Expected: PASS with read freshness, failure compensation, and Undo coverage.

- [ ] **Step 6: Commit**

```bash
git add "ios-native/Kitchen Manager/KitchenManager/ConversationDomainTools.swift" \
        "ios-native/Kitchen Manager/KitchenManagerTests/ConversationDomainToolsTests.swift"
git commit -m "feat(ios): expose bounded Kitchen AI domain tools"
```

---

### Task 5: Add a stateless streaming conversation endpoint without changing `/api/ai-chat`

**Files:**
- Create: `src/server/services/ai-conversation.js`
- Modify: `src/server/services/ai-client.js`
- Modify: `server.js`
- Create: `test/ai-conversation-stream.test.mjs`
- Modify: `test/ai-server-routes.test.mjs`
- Modify if required by existing assertions: `test/ai-provider-mode.test.mjs`

**Interfaces:**
- Produces `POST /api/ai-conversation` with `application/x-ndjson` response.
- Request body:

```json
{
  "provider": "gemini",
  "messages": [{"role":"user","content":"今晚想吃清淡一点"}],
  "enabledTools": ["read_inventory","present_recipe_card"],
  "requestID": "uuid"
}
```

- Fixed server-owned tool names:

```text
read_inventory
read_tonight_plan
read_planner_week
read_special_plan
resolve_recipe
present_recipe_card
present_context_result
propose_add_recipe_to_tonight
propose_replace_planned_meal
propose_apply_planner_changes
propose_special_plan_changes
propose_add_shopping_items
```

- NDJSON events:

```json
{"type":"text_delta","text":"我先看看现在的库存。"}
{"type":"tool_call","id":"call_1","name":"read_inventory","arguments":{}}
{"type":"completed","finishReason":"tool_calls"}
{"type":"error","code":"provider_unavailable","message":"AI 服务暂时不可用。"}
```

Tool-call argument chunks are assembled on the server and emitted only as one complete JSON object. Raw provider reasoning is discarded.

- [ ] **Step 1: Write failing Node contract tests**

Use a dependency seam around provider streaming so tests do not call real AI. Cover:

- missing/oversized messages -> safe 400/413;
- unknown `enabledTools` -> 400, never arbitrary schema pass-through;
- valid stream emits NDJSON deltas then completed;
- fragmented upstream tool arguments are aggregated to one `tool_call` event;
- no reasoning field is forwarded;
- rate limiting runs before provider work;
- client disconnect aborts upstream stream;
- transient primary failure can fallback only before the first user-visible event;
- failure after first delta emits error and does not start a second provider.

- [ ] **Step 2: Run the new Node test and confirm RED**

```bash
node --test test/ai-conversation-stream.test.mjs
```

Expected: route/service missing.

- [ ] **Step 3: Implement server-owned schemas and request validation**

`ai-conversation.js` exports the fixed tool definitions and:

```js
function selectConversationTools(enabledNames) {
  const unknown = enabledNames.filter((name) => !TOOL_DEFINITIONS[name]);
  if (unknown.length) throw createPublicApiError(400, '不支持的 AI 工具。', 'unsupported_tool');
  return enabledNames.map((name) => TOOL_DEFINITIONS[name]);
}
```

Enforce a bounded message count and total text <= existing `AI_PROMPT_MAX_CHARS`. The client sends tool names only; schemas stay server-owned.

- [ ] **Step 4: Add `streamChatCompletion` to `ai-client.js`**

Use the existing provider client/config and OpenAI-compatible stream mode. Aggregate tool-call fragments by `index/id`, yield text deltas immediately, and yield complete tool calls only when their JSON arguments parse. Never yield `delta.reasoning` or equivalent provider-internal content.

- [ ] **Step 5: Add `/api/ai-conversation` using existing limit/error helpers**

The route is stateless: one request represents one provider step. When it ends in tool calls, iOS executes them locally and starts another request with provider messages/tool results. Do not attempt bidirectional execution inside one HTTP response.

Set:

```js
res.status(200);
res.setHeader('Content-Type', 'application/x-ndjson; charset=utf-8');
res.setHeader('Cache-Control', 'no-store');
```

Use `checkAiRateLimit`, safe public errors, request correlation, and existing provider resolution. Abort upstream generation on `req.close` only when the response has not already naturally completed.

- [ ] **Step 6: Run Node focused regression**

```bash
node --test test/ai-conversation-stream.test.mjs
node --test test/ai-server-routes.test.mjs
node --test test/ai-provider-mode.test.mjs
```

Expected: PASS; `/api/ai-chat` assertions remain unchanged.

- [ ] **Step 7: Commit**

```bash
git add src/server/services/ai-conversation.js src/server/services/ai-client.js server.js \
        test/ai-conversation-stream.test.mjs test/ai-server-routes.test.mjs test/ai-provider-mode.test.mjs
git commit -m "feat(server): stream Kitchen AI conversation events"
```

---

### Task 6: Add centralized iOS NDJSON transport and capability-aware provider routing

**Files:**
- Modify: `ios-native/Kitchen Manager/KitchenManager/Networking/APIClient.swift`
- Create: `ios-native/Kitchen Manager/KitchenManager/AIConversationTransport.swift`
- Create: `ios-native/Kitchen Manager/KitchenManager/AIConversationProviderRouter.swift`
- Create: `ios-native/Kitchen Manager/KitchenManagerTests/AIConversationTransportTests.swift`
- Extend: `ios-native/Kitchen Manager/KitchenManagerTests/AIRecommendationProviderTests.swift`

**Interfaces:**
- `APIClient.streamLines(_:) -> AsyncThrowingStream<String, Error>` shares request building/status/rate-limit semantics with existing calls.
- `AIConversationTransport.stream(_ request:) -> AsyncThrowingStream<AIConversationStreamEvent, Error>`.
- `AIConversationProviderRouter.route() -> AIConversationProviderRoute`, where `.cloud(provider: AIRecommendationProvider)` supports Gemini/Groq and `.unavailable(message:)` covers explicit Apple for V1.

- [ ] **Step 1: Write failing APIClient line-stream tests**

Use `MockURLProtocol` / mocked URLSession to emit a small NDJSON body and assert lines arrive in order. Cover HTTP 429 `Retry-After`, malformed UTF-8/JSON at the transport layer, and Task cancellation mapping to the existing cancellation error family.

- [ ] **Step 2: Add one centralized streaming primitive to `APIClient`**

Build requests through the same private request builder. Use `URLSession.bytes(for:)`; validate the HTTP response before yielding lines. Do not log line contents, headers, prompts, or context payloads.

- [ ] **Step 3: Implement typed wire request/events**

```swift
nonisolated struct AIConversationWireRequest: Encodable, Sendable {
    let provider: String
    let messages: [AIProviderMessage]
    let enabledTools: [String]
    let requestID: UUID
}

nonisolated enum AIConversationStreamEvent: Equatable, Sendable {
    case textDelta(String)
    case toolCall(id: String, name: String, arguments: Data)
    case completed(finishReason: String?)
    case error(code: String, message: String)
}
```

Decode one JSON object per line and throw a typed safe error on malformed protocol data.

- [ ] **Step 4: Write and implement provider capability routing tests**

Pin these behaviors:

- selected Gemini -> cloud Gemini;
- selected Groq -> cloud Groq;
- selected Apple -> `.unavailable("Kitchen AI 对话暂不支持设备端模型。")`;
- no conversation-layer provider preference is persisted;
- existing recommendation routing tests stay unchanged.

Do not add a conversation-specific Apple fallback when offline.

- [ ] **Step 5: Run focused tests**

Run `AIConversationTransportTests`, `AIRecommendationProviderTests`, `AIChatServiceTests`, and `APIClientRequestConstructionTests`. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add "ios-native/Kitchen Manager/KitchenManager/Networking/APIClient.swift" \
        "ios-native/Kitchen Manager/KitchenManager/AIConversationTransport.swift" \
        "ios-native/Kitchen Manager/KitchenManager/AIConversationProviderRouter.swift" \
        "ios-native/Kitchen Manager/KitchenManagerTests/AIConversationTransportTests.swift" \
        "ios-native/Kitchen Manager/KitchenManagerTests/AIRecommendationProviderTests.swift"
git commit -m "feat(ios): add Kitchen AI streaming transport"
```

---

### Task 7: Assemble bounded context, interpret tools, and maintain title/summary metadata

**Files:**
- Create: `ios-native/Kitchen Manager/KitchenManager/ConversationContextAssembler.swift`
- Create: `ios-native/Kitchen Manager/KitchenManager/ConversationResponseInterpreter.swift`
- Create: `ios-native/Kitchen Manager/KitchenManager/ConversationMetadataService.swift`
- Create: `ios-native/Kitchen Manager/KitchenManagerTests/ConversationContextAssemblerTests.swift`
- Create: `ios-native/Kitchen Manager/KitchenManagerTests/ConversationResponseInterpreterTests.swift`

**Interfaces:**
- `ConversationContextAssembler.prepare(...) -> PreparedAIConversationRequest`.
- `ConversationResponseInterpreter.interpret(toolCall:context:) -> AIConversationToolIntent`.
- `ConversationMetadataService` reuses the existing one-shot `AIChatService` for non-blocking title/summary generation.
- Exact V1 model-text budget: <= 10,500 characters before request encoding:

```text
system/product instructions   1,600
existing summary              1,200
fresh live context            3,000
recent prior messages         3,200
current user message          1,500
```

Recent window is at most 12 prior messages and trims oldest first.

- [ ] **Step 1: Write failing context-budget/freshness tests**

Cover:

- Home question about expiring food requests Inventory and tonight context, not full week/Special Plan dump;
- Planner entry anchors the opened week;
- a one-turn `inventory` exclusion prevents Inventory read for that message and resets afterwards;
- old assistant text claiming “4 eggs” never substitutes for a fresh `inventoryContext` read;
- exactly the newest messages that fit the 3,200-char recent budget remain;
- assembled model text never exceeds 10,500 chars.

- [ ] **Step 2: Implement deterministic context selection and serialization**

Use a small intent heuristic only to decide which local read tools may be useful before the model runs; the model can still request additional allowed read tools later. Serialize domain structs to concise JSON text, not a prose dump. Never include auth/sync ids, secrets, hidden diagnostics, or unrelated kitchen collections.

- [ ] **Step 3: Write failing tool-interpretation tests**

For each fixed server tool name, decode exact arguments into one typed intent. Unknown tool names or malformed args become a safe `AIErrorBlock`/protocol error and never reach ActionCoordinator.

`present_recipe_card` decodes a complete `Recipe` snapshot with `isTransient`; mutation tools decode only the approved `AIActionProposal` cases.

- [ ] **Step 4: Implement response interpreter**

Keep wire decoding separate from UI. The output enum is semantic:

```swift
nonisolated enum AIConversationToolIntent: Equatable, Sendable {
    case read(AIReadToolRequest)
    case appendBlock(AIContentBlock)
    case proposeAction(AIActionProposal)
}
```

- [ ] **Step 5: Add non-blocking title and summary metadata service**

Use existing `AIChatService.request` with task types `conversation_title` and `conversation_summary`. Title generation runs after the first successful response and only applies if the stored title is still `新对话`; a user rename that lands first wins. Summary refresh runs after turn completion when more than 12 messages exist or the stored summary is stale. Failure leaves the previous title/summary untouched and never fails the user turn.

- [ ] **Step 6: Run focused tests**

Run `ConversationContextAssemblerTests`, `ConversationResponseInterpreterTests`, and `AIChatServiceTests`. Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add "ios-native/Kitchen Manager/KitchenManager/ConversationContextAssembler.swift" \
        "ios-native/Kitchen Manager/KitchenManager/ConversationResponseInterpreter.swift" \
        "ios-native/Kitchen Manager/KitchenManager/ConversationMetadataService.swift" \
        "ios-native/Kitchen Manager/KitchenManagerTests/ConversationContextAssemblerTests.swift" \
        "ios-native/Kitchen Manager/KitchenManagerTests/ConversationResponseInterpreterTests.swift"
git commit -m "feat(ios): assemble fresh Kitchen AI context"
```

---

### Task 8: Enforce risk, idempotency, confirmation, and Undo in one action coordinator

**Files:**
- Create: `ios-native/Kitchen Manager/KitchenManager/ConversationActionCoordinator.swift`
- Create: `ios-native/Kitchen Manager/KitchenManagerTests/ConversationActionCoordinatorTests.swift`

**Interfaces:**
- Consumes: `AIActionProposal`, `AIConversationDomainTooling`, `ConversationPersistenceProtocol`/ConversationStore action records.
- Produces:

```swift
struct PreparedAIAction: Identifiable, Equatable {
    let id: UUID
    let proposal: AIActionProposal
    let risk: AIActionRisk
    let preview: AIContentBlock?
    let idempotencyKey: String
}

func prepare(_ proposal: AIActionProposal, conversationID: UUID, turnID: UUID) throws -> PreparedAIAction
func execute(_ action: PreparedAIAction) throws -> AIActionExecutionResult
func undo(actionID: UUID) throws -> AIActionExecutionResult
```

- Risk table:
  - low: add one resolved recipe to tonight; add <= 5 Shopping items;
  - medium: replace one planned meal; add/apply a bounded Planner change set;
  - high: >1 Special Plan dish replacement, destructive/bulk changes, or any action whose domain adapter marks the diff substantial.
  - V1 unsupported destructive actions are rejected rather than invented.

- [ ] **Step 1: Write failing risk/preview tests**

Assert a single add-to-tonight is low/no preview; one planned meal replacement is medium with actual before/after; Special Plan two-dish change is high with every diff row; unsupported actions cannot be prepared.

- [ ] **Step 2: Write failing idempotency tests**

Persist a succeeded action with a known key, call `execute` again, assert no domain tool invocation occurs and the existing success result is returned. Also prove failed actions may retry using the same logical proposal without duplicating prior successful side effects.

- [ ] **Step 3: Implement stable idempotency keys from canonical proposal data**

Do not use model prose. Build the key from conversation id + action type + canonical target ids + canonical replacement/item payload. Hash with a stable digest (CryptoKit SHA-256) and persist the resulting hex string.

- [ ] **Step 4: Implement prepare/execute state transitions**

Persist:

```text
proposed -> awaitingConfirmation      medium/high
proposed -> executing -> succeeded    low
awaitingConfirmation -> executing -> succeeded | failed
```

A UI Apply tap calls `execute(preparedAction)` directly. It never generates a synthetic user message or asks the model to reinterpret confirmation.

- [ ] **Step 5: Implement deterministic Undo**

Use the exact `AIDomainMutationReceipt` captured on success. Before restoring, validate that the target state still matches the action's post-state; if it diverged, return a truthful non-destructive error instead of overwriting later user changes. Persist `.undone` only after the reverse domain write succeeds.

- [ ] **Step 6: Run `ConversationActionCoordinatorTests`**

Expected: PASS for risk, real diff, low-risk direct execution, confirmation, idempotency, retry, Undo, and diverged-state refusal.

- [ ] **Step 7: Commit**

```bash
git add "ios-native/Kitchen Manager/KitchenManager/ConversationActionCoordinator.swift" \
        "ios-native/Kitchen Manager/KitchenManagerTests/ConversationActionCoordinatorTests.swift"
git commit -m "feat(ios): coordinate safe Kitchen AI actions"
```

---

### Task 9: Implement the turn orchestrator and tool loop

**Files:**
- Create: `ios-native/Kitchen Manager/KitchenManager/ConversationOrchestrator.swift`
- Create: `ios-native/Kitchen Manager/KitchenManagerTests/ConversationOrchestratorTests.swift`

**Interfaces:**
- Consumes: context assembler, provider router, transport, interpreter, domain reads, action coordinator.
- Produces an async event stream for controller/UI:

```swift
nonisolated enum AIConversationTurnEvent: Equatable, Sendable {
    case state(AIConversationTurnState)
    case appendText(String)
    case appendBlock(AIContentBlock)
    case replaceBlock(AIContentBlock)
    case pendingAction(PreparedAIAction)
    case finished
}

func runTurn(_ input: AIConversationTurnInput) -> AsyncThrowingStream<AIConversationTurnEvent, Error>
func cancelCurrentTurn()
```

- [ ] **Step 1: Write scripted fake-transport tests for the read-tool loop**

Script provider step 1 -> text delta + `read_inventory`; fake domain read returns current inventory; provider step 2 receives an assistant tool-call + tool-result transcript and returns two `present_recipe_card` tool calls + completion. Assert UI events contain streamed text and two recipe blocks in order.

- [ ] **Step 2: Write mutation-path tests**

Cover:

- low-risk `propose_add_recipe_to_tonight` executes once, yields `actionStatus`, and does not require a model round-trip after execution;
- medium/high proposal yields preview + `.awaitingConfirmation` and stops the turn without mutation;
- later confirmation is action-coordinator-only, not an orchestrator/model request.

- [ ] **Step 3: Write cancellation/retry/partial-success tests**

Assert:

- cancel ends active transport task, keeps emitted text, terminal state `.cancelled`;
- provider failure after one recipe block leaves that block present and adds a scoped error;
- retry of generation restarts provider generation but sees succeeded action idempotency and never duplicates it;
- context-read failure can produce `contextResult/error` and continue without that source only when interpreter marks the source optional.

- [ ] **Step 4: Implement the explicit state machine**

Keep one current `Task`. States follow the approved graph; no forest of `isLoading/isStreaming/isExecuting` booleans. The ephemeral provider transcript exists only for the active turn and includes tool results required to continue a stateless server request; persisted conversation history remains semantic user/assistant content blocks.

- [ ] **Step 5: Implement bounded tool-loop protection**

Set a V1 maximum of 6 provider steps and 12 tool calls per turn. Hitting either limit ends with a safe error block; it never continues indefinitely. Read tools may continue the provider loop. Presentation tools append validated blocks. Mutation proposal tools hand off to ActionCoordinator and end/pause as described above.

- [ ] **Step 6: Run `ConversationOrchestratorTests`**

Expected: PASS across read loop, cards, mutation, cancel, partial success, retries, and loop limits.

- [ ] **Step 7: Commit**

```bash
git add "ios-native/Kitchen Manager/KitchenManager/ConversationOrchestrator.swift" \
        "ios-native/Kitchen Manager/KitchenManagerTests/ConversationOrchestratorTests.swift"
git commit -m "feat(ios): orchestrate multi-turn Kitchen AI requests"
```

---

### Task 10: Build ConversationStore/controller and wire the app composition root

**Files:**
- Create: `ios-native/Kitchen Manager/KitchenManager/ConversationStore.swift`
- Create: `ios-native/Kitchen Manager/KitchenManager/AIConversationController.swift`
- Modify: `ios-native/Kitchen Manager/KitchenManager/ContentView.swift`
- Create: `ios-native/Kitchen Manager/KitchenManagerTests/AIConversationControllerTests.swift`
- Modify if source guard requires bundle shape: `test/ios-native-kitchen-store-composition.test.mjs`

**Interfaces:**
- `ConversationStore`: load/history/create-on-first-message/update/delete/reactivate/pin/rename; no domain mutation logic.
- `AIConversationController`: UI-facing properties:

```swift
@Published private(set) var currentConversation: AIConversation?
@Published private(set) var messages: [AIConversationMessage]
@Published private(set) var turnState: AIConversationTurnState
@Published var draftText: String
@Published var nextTurnExcludedContexts: Set<AIContextKind>
@Published private(set) var preparedAction: PreparedAIAction?
```

Commands: `open(entryContext:)`, `send()`, `stop()`, `newConversation(entryContext:)`, `reactivate(id:)`, `confirmPreparedAction()`, `undo(actionID:)`, `rename`, `setPinned`, `delete`.

- [ ] **Step 1: Write failing ConversationStore lifecycle tests**

Prove:

- empty draft is not persisted/history-visible;
- first user message atomically persists conversation + message;
- relevant active conversation is selected via affinity;
- expired conversation is history-visible but not silently reactivated;
- explicit reactivation recalculates expiry;
- pin/unpin flows through policy;
- deleting conversation never reverses domain actions.

- [ ] **Step 2: Implement ConversationStore over persistence**

On init/open, call `recoverInterruptedMessages(now:)` before presenting history. History grouping is derived from `isPinned` + `activeUntil`, not persisted as a second status truth.

- [ ] **Step 3: Write controller tests with fake orchestrator**

Assert immediate user-message rendering, streaming assistant block growth, Stop preserving partial text, pending preview confirmation, Undo status replacement, one-turn context exclusion reset, and title generation only replacing `新对话`.

- [ ] **Step 4: Implement AIConversationController**

Persist assistant streaming record at turn start but do not save every token. Update the in-memory text block as deltas arrive; persist at stable boundaries: structured block append, completed, cancelled, or failed. This keeps crash truth without one SwiftData save per token.

After first successful response, schedule title generation; after qualifying turns, schedule summary refresh. Both are non-blocking and update only if their optimistic precondition still holds.

- [ ] **Step 5: Wire production dependencies once in `KitchenManagerApp.init()`**

Refactor the existing RecipeStore construction just enough to keep a local `recipeStoreInstance`, then build:

```swift
let conversationStore = ConversationStore(
    persistence: persistence.conversations,
    retentionPolicy: .v1
)
let domainTools = KitchenConversationDomainTools(
    kitchenStore: kitchenStoreInstance,
    recipeStore: recipeStoreInstance
)
let router = AIConversationProviderRouter(userDefaults: recipeTestDefaults)
let transport: any AIConversationTransporting = AIConversationTransport()
let actionCoordinator = ConversationActionCoordinator(
    conversationStore: conversationStore,
    domainTools: domainTools
)
let orchestrator = ConversationOrchestrator(...)
let controller = AIConversationController(...)
```

Store controller as a `@StateObject` and inject with `.environmentObject`. No auth/sync credentials enter these objects.

Under DEBUG only, launch argument `UITEST_AI_CONVERSATION_FAKE` swaps transport for a deterministic scripted fake so XCUITests never spend AI quota or hit Render.

- [ ] **Step 6: Run controller/composition regression**

Run `AIConversationControllerTests` plus the Node composition guard. Build the iOS target. Expected: PASS / clean build.

- [ ] **Step 7: Commit**

```bash
git add "ios-native/Kitchen Manager/KitchenManager/ConversationStore.swift" \
        "ios-native/Kitchen Manager/KitchenManager/AIConversationController.swift" \
        "ios-native/Kitchen Manager/KitchenManager/ContentView.swift" \
        "ios-native/Kitchen Manager/KitchenManagerTests/AIConversationControllerTests.swift" \
        test/ios-native-kitchen-store-composition.test.mjs
git commit -m "feat(ios): compose Kitchen AI conversation state"
```

---

### Task 11: Build the Quiet Kitchen conversation UI, blocks, context sheet, and History

**Files:**
- Create: `ios-native/Kitchen Manager/KitchenManager/AIConversationView.swift`
- Create: `ios-native/Kitchen Manager/KitchenManager/AIConversationBlocks.swift`
- Create: `ios-native/Kitchen Manager/KitchenManager/AIConversationHistoryView.swift`
- Create/extend: `ios-native/Kitchen Manager/KitchenManagerUITests/AIConversationWorkspaceUITests.swift`

**Interfaces:**
- `AIConversationView(entryContext: AIConversationEntryContext)` uses the environment `AIConversationController`.
- Block views consume only `AIContentBlock`; they do not call KitchenStore directly.
- History view calls controller commands and renders pinned/recent/ended derived groups.

- [ ] **Step 1: Add DEBUG fixture scripts and failing empty-state UI tests**

With `UITEST_AI_CONVERSATION_FAKE`, seed no conversation and assert Home-style `AIConversationView(entryContext: .home)` shows:

- navigation title `Kitchen AI`;
- contextual headline and starters `用快过期的食材做饭`, `今晚想吃清淡一点`, `看看现在能做什么`, `帮我补一道菜`;
- composer identifier `kitchenAI.composer` and send control;
- no visible/provider picker and no tappable attachment button.

Add a Planner-context fixture asserting weekly/Special Plan starters instead.

- [ ] **Step 2: Implement the workspace shell and contextual empty state**

Use the existing canvas/semantic colors/spacing from KitchenTheme. Assistant prose is open content; user text gets a restrained trailing bubble. The bottom composer respects keyboard/safe-area behavior and switches Send -> Stop during streaming.

Top-right overflow contains exactly New Conversation, History, Rename, Pin/Unpin, Delete. Rename/delete use native sheets/alerts.

- [ ] **Step 3: Add failing structured-block UI tests**

Script the fake transport to stream prose + two recipe cards, then a Planner diff. Assert the cards render names, at most one primary + one secondary action, and Planner preview exposes `应用修改` only for pending confirmation.

- [ ] **Step 4: Implement the six block renderers**

Required render behavior:

- `text`: assistant typography/open layout;
- `recipe`: title, useful compact metadata/reason, `查看菜谱`, context-appropriate action;
- `plannerPreview`: every before -> after change, no hidden diff;
- `contextResult`: compact read-only rows;
- `actionStatus`: lightweight success/failure + Undo/action link;
- `error`: scoped copy + targeted retry when available.

Do not embed full Recipe/Shopping editors.

- [ ] **Step 5: Add context-chip behavior**

Before Send, show only likely context sources. Tapping opens a native compact sheet with toggles for the next turn. A disabled source resets after one Send. During an active turn, render actually-used sources as informational and disable editing until the next turn.

- [ ] **Step 6: Add failing History/reactivation UI tests**

Seed pinned, active, and expired conversations. Assert groups `置顶`, `最近`, `已结束`; expired row opens transcript but does not make composer active until `继续此对话`; active row resumes immediately; new blank draft never creates a history row.

- [ ] **Step 7: Implement History and expired reactivation UI**

Use native navigation/sheet, no sidebar. Row content is title + short excerpt + time/state only. Provider/tool/token metadata never appears.

- [ ] **Step 8: Run focused XCUITest + visual/accessibility pass**

Run `AIConversationWorkspaceUITests` using the fake transport. Manually inspect simulator Light/Dark, normal + Accessibility XXXL, VoiceOver labels, 44pt custom targets, keyboard/composer safe area, scrolling last block above composer, stopped generation, error state, and Reduce Motion behavior.

- [ ] **Step 9: Commit**

```bash
git add "ios-native/Kitchen Manager/KitchenManager/AIConversationView.swift" \
        "ios-native/Kitchen Manager/KitchenManager/AIConversationBlocks.swift" \
        "ios-native/Kitchen Manager/KitchenManager/AIConversationHistoryView.swift" \
        "ios-native/Kitchen Manager/KitchenManagerUITests/AIConversationWorkspaceUITests.swift"
git commit -m "feat(ios): build Kitchen AI conversation workspace UI"
```

---

### Task 12: Integrate Home/Planner entry points and pin the four acceptance scenarios

**Files:**
- Modify: `ios-native/Kitchen Manager/KitchenManager/HomeView.swift`
- Modify: `ios-native/Kitchen Manager/KitchenManager/PlannerView.swift`
- Extend: `ios-native/Kitchen Manager/KitchenManagerUITests/AIConversationWorkspaceUITests.swift`
- Modify as required: `ios-native/Kitchen Manager/KitchenManagerUITests/HomeDashboardUITests.swift`
- Modify as required: `ios-native/Kitchen Manager/KitchenManagerUITests/PlannerUITests.swift`

**Interfaces:**
- Home entry identifier: `home.kitchenAI.open`, destination `AIConversationView(entryContext: .home)`.
- Planner entry identifier: `planner.kitchenAI.open`, route carries current `weekStart` and optional Special Plan anchor.
- Existing `home.recommendation.more`, `planner.weekly.open`, Planner create menu, and current IA remain available.

- [ ] **Step 1: Write failing entry-routing UI tests**

Home: tap `home.kitchenAI.open`, assert Kitchen AI contextual Home empty state. Planner: open displayed week, tap `planner.kitchenAI.open`, assert Planner contextual empty state and week context. Back navigation returns to the originating surface without changing bottom tabs.

- [ ] **Step 2: Add the minimal Home entry**

Use a native top-bar utility action with `sparkles`, semantic host tint, accessibility label `问 Kitchen AI`, identifier `home.kitchenAI.open`, and a navigation destination to `.home`. Do not repurpose/remove `更多推荐`; the structured recommendation browser remains its existing focused entry.

- [ ] **Step 3: Add the Planner route and tools-menu entry**

Extend `PlannerRoute`:

```swift
case kitchenAI(Date, UUID?)
```

Add `问 Kitchen AI` to `planner.tools.menu`; pass current `weekStart`. If a future Special Plan detail adds an entry, it uses the same route with that plan id rather than a second chat.

- [ ] **Step 4: Pin acceptance Scenario A with fake transport/domain state**

Script:

1. Home -> Kitchen AI;
2. send `今晚想吃清淡一点，把快过期的先用掉。`;
3. fake provider requests fresh Inventory, then returns two recipe blocks;
4. send `第二个加入今晚。`;
5. fake provider proposes add-to-tonight for the second block;
6. assert exactly one canonical `MealPlanItem` exists, status says `已加入今晚`, Undo exists;
7. leave/reopen and assert same active conversation resumes.

- [ ] **Step 5: Pin acceptance Scenario B**

Seed Wednesday plan. Planner -> Kitchen AI -> send `把周三晚餐换清淡一点。`; fake provider reads canonical week and proposes replacement. Assert preview before/after, no mutation before Apply, mutation after Apply, Planner row displays replacement, and a retry cannot create a second/duplicate change.

- [ ] **Step 6: Pin acceptance Scenario C**

Seed an expired conversation whose old text says an obsolete Inventory value. Open History -> expired transcript -> `继续此对话` -> ask a context-dependent follow-up. Assert fake read tool receives current seeded Inventory and UI does not reuse obsolete snapshot as current truth.

- [ ] **Step 7: Pin acceptance Scenario D**

Seed a 7-person Special Plan with restrictions and dishes. From Planner context, ask to replace two spicy dishes. Assert two-item diff, unchanged people/restrictions before and after, no mutation before confirmation, then exact confirmed menu after Apply.

- [ ] **Step 8: Run routing + acceptance XCUITests**

Run `AIConversationWorkspaceUITests`, then affected `HomeDashboardUITests` and `PlannerUITests`. Expected: existing canonical IA ids remain green and the new AI entries do not create a bottom tab or remove recommendation/weekly-generator paths.

- [ ] **Step 9: Commit**

```bash
git add "ios-native/Kitchen Manager/KitchenManager/HomeView.swift" \
        "ios-native/Kitchen Manager/KitchenManager/PlannerView.swift" \
        "ios-native/Kitchen Manager/KitchenManagerUITests/AIConversationWorkspaceUITests.swift" \
        "ios-native/Kitchen Manager/KitchenManagerUITests/HomeDashboardUITests.swift" \
        "ios-native/Kitchen Manager/KitchenManagerUITests/PlannerUITests.swift"
git commit -m "feat(ios): connect Home and Planner to Kitchen AI"
```

---

### Task 13: Final regression, design-language documentation, and seal

**Files:**
- Modify: `docs/design/KITCHEN_DESIGN_LANGUAGE.md`
- Modify if stable architecture ownership changed: `docs/architecture/OVERVIEW.md`
- Do not edit product docs merely to duplicate the implementation plan.

**Interfaces:**
- Produces only documentation/evidence after implementation is already passing.
- No new product behavior in this task.

- [ ] **Step 1: Run source hygiene before broad tests**

```bash
git diff --check
rg -n 'TODO|TBD|URLSession\.shared|api[_-]?key|Authorization:|service[_-]?role' \
  "ios-native/Kitchen Manager/KitchenManager" src/server server.js test \
  --glob '!**/*.xcresult/**'
```

Review hits manually; `URLSession.shared` in pre-existing centralized setup is not automatically a failure, but conversation code must use `APIClient`.

- [ ] **Step 2: Run focused Node AI/server tests**

```bash
node --test test/ai-conversation-stream.test.mjs
node --test test/ai-server-routes.test.mjs
node --test test/ai-provider-mode.test.mjs
```

Then follow `docs/development/WORKFLOW.md` to decide whether the full `npm test` suite is required by the final diff. If run, record the exact result; do not substitute it for iOS evidence.

- [ ] **Step 3: Run focused iOS unit suites**

Through Xcode MCP where available, run all new conversation test classes plus the affected existing persistence/provider/domain suites named in Tasks 1–10. Any red is investigated before broadening.

- [ ] **Step 4: Build and run the applicable broader iOS regression**

Use Xcode MCP BuildProject and the test selection required by `docs/development/TESTING.md` / `WORKFLOW.md`. CLI fallback build:

```bash
xcodebuild \
  -project "ios-native/Kitchen Manager/Kitchen Manager.xcodeproj" \
  -scheme KitchenManager \
  -configuration Debug \
  -destination "$IOS_DEST" \
  clean build
```

If shared model/persistence/store behavior changed enough to require the full `KitchenManagerTests`, run it serially and record the exact count/result. Do not claim full regression if only focused suites ran.

- [ ] **Step 5: Run focused UI regression and manual simulator matrix**

Run `AIConversationWorkspaceUITests`, Home/Planner affected suites, then manually validate:

- Home and Planner entries;
- context-aware new conversation;
- streaming/Stop;
- two recipe blocks + action status;
- Planner preview confirmation;
- History active/expired/reactivate;
- Light/Dark;
- normal + Accessibility XXXL;
- VoiceOver labels/reading order;
- keyboard/safe-area/last-message reachability;
- provider capability-unavailable copy with explicit Apple selection.

Use the fake transport for deterministic UI acceptance. Do not spend hosted model quota for XCUITest.

- [ ] **Step 6: Physical-device check only for the Apple capability boundary**

Because V1 does not use Apple Foundation Models for full conversation, no general conversation flow requires a physical device. If the implementation touched `AIRecommendationProvider`/Apple availability beyond pure routing, verify on the physical iPhone that explicit Apple still serves only the pre-existing recipe-candidate path and Kitchen AI shows capability unavailable. Otherwise record physical-device validation as not applicable.

- [ ] **Step 7: Update canonical docs**

In `KITCHEN_DESIGN_LANGUAGE.md`, add the accepted Kitchen AI surface rules: AI remains a capability, assistant prose is open, only domain objects get domain cards, user messages are restrained bubbles, composer/history/context chips follow native semantics, no separate AI palette.

In `OVERVIEW.md`, only if warranted by final architecture, add Conversation Orchestrator + local conversation persistence to the iOS architecture section and explicitly state it is excluded from current backup/sync.

- [ ] **Step 8: Final secret/artifact/diff review**

Verify no `.env`, local keys, tokens, DerivedData, `.xcresult`, screenshots, temp exports, or provider response bodies are staged. Inspect the full diff and confirm every changed file belongs to the approved spec.

- [ ] **Step 9: Commit documentation/seal changes**

```bash
git add docs/design/KITCHEN_DESIGN_LANGUAGE.md docs/architecture/OVERVIEW.md
git commit -m "docs: record Kitchen AI conversation architecture"
```

If `OVERVIEW.md` did not require a truthful stable-architecture change, omit it from `git add` rather than making a no-op edit.

---

## Execution Order and Review Gates

Tasks are intentionally ordered so no UI can mutate kitchen state before the durable safety seams exist:

```text
1 models/policy
  -> 2 local persistence
  -> 3 canonical mutation safety
  -> 4 finite domain tools
  -> 5 server streaming protocol
  -> 6 iOS transport/router
  -> 7 context/interpreter/metadata
  -> 8 action safety/idempotency
  -> 9 orchestrator
  -> 10 store/controller/composition
  -> 11 workspace/history UI
  -> 12 Home/Planner acceptance integration
  -> 13 final regression/docs
```

Review after every task. A reviewer may reject one task without forcing unrelated later work to be accepted. Do not batch Tasks 3–9 into a single mega-commit.

## Definition of Done

Implementation is complete only when all of the following are evidenced, not inferred:

1. Home and Planner open the same Kitchen AI workspace with different entry context and no new bottom tab.
2. Local conversation persistence survives relaunch; history expiry/reactivation matches the approved policy and does not delete history.
3. Model input is bounded and live facts are reread from authoritative domain state.
4. Gemini/Groq conversation streaming works through the new additive endpoint; explicit Apple full-conversation selection fails closed with truthful capability copy.
5. The six structured block types render in Quiet Kitchen R3.1 without a separate AI brand.
6. Low-risk action executes exactly once with deterministic Undo; medium/high actions do not mutate before explicit Apply.
7. Retry cannot duplicate a succeeded mutation; Stop keeps partial text; partial success stays visible.
8. Planner/Special Plan/Shopping AI writes are persist-before-publish and failure-tested.
9. Current `/api/ai-chat`, recommendation, weekly generator, Special Plan composer, Home `更多推荐`, Planner weekly generator, backup, auth, and sync contracts remain intact.
10. Acceptance Scenarios A–D pass under deterministic fake transport; relevant simulator accessibility/appearance checks pass; all unrun checks are named explicitly.
