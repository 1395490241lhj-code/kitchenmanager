# Kitchen Manager AI Conversation Workspace — Design Specification

Date: 2026-09-16  
Status: written design for owner review; implementation is not authorized by this document alone  
Baseline reviewed: `main` at `8a3b3f22a4278242622213d7cbe06e4757dd61fb`

## 1. Problem

Kitchen Manager has working AI infrastructure and several structured AI features, but the existing test/chat surface is not the intended product experience. It proves requests can reach providers; it does not provide a durable, context-aware, multi-turn Kitchen AI workspace.

The target is not a generic ChatGPT clone. It is a Kitchen Manager interaction layer that can understand current kitchen state, converse across multiple turns, render native Kitchen Manager objects, and safely execute domain actions.

The design preserves existing product truth boundaries:

- `KitchenStore.plans` remains canonical ordinary-meal schedule truth.
- Special Plan remains its own domain model and workflow.
- Inventory, Planner, Recipe, Shopping, and Special Plan mutations remain owned by their domain layer.
- AI is a capability, not a second visual brand.
- The product remains Guest-first and Local-first.
- Full kitchen data is never uploaded silently as default background context.

## 2. Goals

The first production version MUST:

1. Provide one shared `Kitchen AI` workspace reachable from both Home and Planner without adding a bottom tab.
2. Preserve durable local conversation history with multi-turn continuity.
3. Start from a context-aware empty state that differs by entry surface.
4. Read live Inventory / Planner / Special Plan state only when relevant to the current turn.
5. Render replies as prose plus native structured Kitchen Manager blocks.
6. Support safe domain actions with risk-based confirmation and deterministic execution.
7. Support streaming text, cancellation, retry, partial success, and truthful errors.
8. Keep provider selection/routing outside the conversation UI and reuse app-level AI routing policy.
9. Keep conversation history local in SwiftData for V1.
10. Establish retention/session policy as a capability boundary that can later differ between free and paid tiers without deleting local history.

## 3. Non-goals for V1

V1 MUST NOT include:

- a new bottom navigation tab;
- a separate AI visual brand, gradient theme, glow treatment, or dashboard-like console;
- working image/photo/file input, although the composer architecture must allow attachments later;
- AI-generated images;
- nutrition dashboards or charts;
- an embedded full Shopping editor;
- an embedded full Recipe detail/editor;
- a model/provider selector inside the conversation page;
- visible chain-of-thought, raw tool calls, token counts, provider diagnostics, or developer traces;
- conversation cloud sync or Supabase persistence;
- automatic inclusion of conversation history in the existing kitchen backup contract;
- automatic mutation of kitchen data based solely on model prose.

## 4. Core product decisions

### 4.1 One workspace, multiple entry contexts

Home and Planner open the same `Kitchen AI` workspace. They differ only by `EntryContext`:

- Home biases the empty state and context selection toward tonight, inventory, expiring ingredients, and immediate cooking.
- Planner biases the empty state and context selection toward the opened week, ordinary planned meals, and Special Plans.

No entry owns a separate chat history.

### 4.2 Conversation model

The default model is **current conversation + history**:

- The user normally returns to the most relevant active conversation.
- The user can create a new conversation explicitly.
- Past conversations remain visible in History.
- Expiry never deletes conversation history.
- An expired conversation stops being the default active context.
- Reopening an expired conversation requires explicit reactivation; live context is refreshed on the next relevant turn.

### 4.3 Active period versus history retention

`activeUntil` governs automatic continuity, not storage deletion.

V1 baseline policy:

- `.general`: 48 hours after last activity.
- `.dailyMeal`: 48 hours after last activity.
- `.weeklyPlanning`: the later of 48 hours after last activity or 24 hours after the referenced Planner week's end.
- `.specialPlan`: the later of 48 hours after last activity or 24 hours after the referenced event time.
- pinned conversations: no automatic expiry while pinned.

A weekly/special conversation therefore stores a task anchor (`anchorDate` and, when applicable, `anchorEntityID`) so expiry is deterministic.

Future free/paid values MUST come from `ConversationRetentionPolicy`, not UI literals. Paid policy may extend active windows, summary depth, or pin allowance; local history remains readable after expiry or plan changes.

### 4.4 Context freshness

Conversation memory and live kitchen truth are separate systems.

A previous message such as “you have four eggs” is historical text, not current Inventory truth. When a later turn depends on Inventory, Planner, or Special Plan state, the app MUST query the live domain layer again.

Old tool results MUST NOT be reused as current facts without a fresh read.

### 4.5 Local-first persistence

Conversation metadata, messages, summaries, action records, and context-reference metadata are stored locally in SwiftData.

V1 does not sync them to Supabase and does not add them to the existing kitchen backup/restore payload. This is intentional: conversation history is interaction history, not canonical kitchen business state.

Adding backup/export or cross-device conversation sync requires a separate explicit design.

## 5. Architecture

The selected architecture is **Conversation Orchestrator + Domain Tools**.

```text
Home ------------------\
                        > EntryContext
Planner ---------------/
                             |
                             v
                 AI Conversation Workspace
                   |-- ConversationStore
                   |-- ContextAssembler
                   |-- ConversationOrchestrator
                   |-- ResponseInterpreter
                   |-- ActionCoordinator
                             |
              +--------------+---------------+
              |              |               |
              v              v               v
          Inventory        Planner       Special Plan
            tools           tools            tools
              |              |               |
              +--------------+---------------+
                             |
                    Existing domain/data layer
```

### 5.1 ConversationStore

Owns only conversation persistence and retrieval:

- conversations and messages;
- generated/user-edited titles;
- summaries;
- pin/delete state;
- `lastActivityAt` and `activeUntil`;
- action records tied to a turn;
- context-reference metadata.

It MUST NOT become an Inventory/Planner mutation service.

### 5.2 ContextAssembler

Builds the minimum necessary model context for each turn from:

- conversation summary;
- a bounded recent-message window;
- current user message;
- relevant live domain reads;
- entry/task anchor when useful.

It MUST NOT upload the full kitchen dataset by default.

It owns token-budget trimming and MUST distinguish local history retained on device from history actually sent to the model.

### 5.3 ConversationOrchestrator

Owns turn lifecycle:

- prepare context;
- route the AI request;
- receive streaming text/events;
- request domain reads/actions through defined interfaces;
- coordinate structured response interpretation;
- persist final turn state;
- cancel and retry safely.

It MUST NOT directly mutate SwiftData domain records owned by Inventory, Planner, Special Plan, Recipe, or Shopping.

### 5.4 ActionCoordinator

Receives semantic `ActionProposal` values and is the only conversation-side gateway to business mutations.

It MUST:

- validate the target still exists;
- refresh/verify current state when stale data could matter;
- classify risk;
- produce a real preview when confirmation is required;
- execute through an authoritative domain API/store/service;
- create an `ActionRecord`;
- attach an idempotency key;
- expose Undo only when the domain supports a deterministic reversal.

### 5.5 ResponseInterpreter

Provider output is semantic, not SwiftUI-specific.

The model/backend may describe text, recipe references, context results, and action proposals. `ResponseInterpreter` converts validated semantic output into app-owned `ContentBlock` values.

No provider response may name SwiftUI view types or bypass validation by encoding UI directly.

## 6. Provider routing and capabilities

The workspace MUST NOT introduce a second provider preference.

It consumes the same app-level routing policy used by other AI features. Existing cloud/provider fallback behavior remains authoritative unless deliberately consolidated into a shared router.

Implementation MUST expose provider capabilities through one app-owned routing abstraction instead of teaching the conversation UI about Gemini, Groq, or Apple individually.

Minimum capability model:

```text
conversationText
streaming
structuredOutput
domainToolPlanning
visionInput (future)
onDeviceRecipeCandidateOnly
```

The current Apple Foundation Models path is deliberately limited to recipe-candidate generation and has explicit restriction-safety boundaries. V1 MUST NOT silently promote it to a full autonomous conversation/tool provider.

If the globally selected execution mode cannot satisfy a turn, the app surfaces a concise capability-unavailable state rather than silently violating an explicit provider choice.

The existing one-shot `AIChatService` remains valid for current import/recommendation/generation callers. Conversation streaming transport may extend it or live beside it, but MUST NOT regress existing request, rate-limit, timeout, diagnostics, or fallback semantics.

## 7. Persistent model

Persistence MAY use separate SwiftData Record types from business structs, following the repository's existing business-model / persistence-record separation. The semantic model is fixed below.

### 7.1 Conversation

```text
id
createdAt
lastActivityAt
title
activeUntil
lifecycleType: general | dailyMeal | weeklyPlanning | specialPlan
isPinned
entryAffinity: general | dailyMeal | weeklyPlanning | specialPlan
anchorDate?
anchorEntityID?
summary
summaryUpdatedAt
retentionPolicyVersion
```

A current subscription/tier name MUST NOT be persisted as truth. Entitlement is evaluated by policy at runtime.

### 7.2 Message

```text
id
conversationID
role: user | assistant | systemStatus
createdAt
state: pending | streaming | completed | cancelled | failed
contentBlocks[]
turnID
```

A message is not one Markdown string. It owns ordered content blocks.

### 7.3 ContentBlock

V1 is intentionally limited to six block kinds:

```text
text
recipe
plannerPreview
contextResult
actionStatus
error
```

Do not create a universal arbitrary-widget schema in V1.

### 7.4 ActionRecord

```text
actionID
conversationID
turnID
actionType
idempotencyKey
status: proposed | awaitingConfirmation | executing | succeeded | failed | undone
createdAt
completedAt?
relatedEntityIDs[]
undoReference?
undoExpiresAt?
```

Undo representation is domain-specific but MUST be deterministic and app-owned, never inferred later by the model.

### 7.5 ContextSnapshot

This is provenance/freshness metadata, not a second source of kitchen truth.

```text
turnID
readAt
contextKinds[]
relatedEntityIDs[]
sourceVersionsOrFingerprints[]
```

It MUST NOT overwrite or replace current Inventory/Planner/Special Plan state.

## 8. Turn state machine

Use one explicit state machine instead of interdependent loading booleans.

```text
idle
  -> preparingContext
  -> requesting
  -> streaming
  -> toolRequested
  -> executing | awaitingConfirmation
  -> streaming
  -> completed

terminal/interrupt states:
  cancelled
  failed
```

A turn may cycle through tool-related states more than once before completion.

## 9. Request flow

For a normal turn:

1. Persist the user message immediately.
2. Clear the composer and render the message without waiting for network work.
3. `ContextAssembler` resolves the smallest relevant live context.
4. `ConversationOrchestrator` begins the provider request.
5. Create an assistant message with `.streaming` state.
6. Stream text into a `text` block.
7. Read-only domain requests return fresh context and may continue the turn.
8. Mutation intent becomes an `ActionProposal`; model prose never mutates domain state directly.
9. Interpret validated semantic output into `ContentBlock` values.
10. Persist the completed assistant message and update conversation activity/summary.

## 10. V1 domain-tool surface

V1 keeps the tool surface finite. Required read tools:

- read current Inventory summary and expiring ingredients;
- read tonight's ordinary plan;
- read the referenced Planner week;
- read a referenced Special Plan;
- resolve canonical Recipe identities/details needed by a response/action.

Required mutation tools:

- add one resolved recipe to tonight;
- replace one ordinary planned meal;
- apply a validated batch of ordinary Planner changes;
- apply a validated Special Plan menu change set;
- add a validated small set of Shopping items.

No other mutation becomes available merely because the model asks for it. New tool types require an explicit domain adapter and risk classification.

## 11. Action safety model

### 11.1 Low risk: execute + Undo

Examples:

- add one recommended recipe to tonight;
- add a small set of Shopping items;
- save/favorite a recipe when a reversible domain operation exists.

The app may execute directly after validation and show an `actionStatus` block with Undo.

### 11.2 Medium risk: preview + confirm

Examples:

- replace one planned meal;
- add several meals to the week;
- apply a generated set of ordinary Planner changes.

The app MUST render the real diff and wait for explicit Apply.

### 11.3 High risk: explicit confirmation

Examples:

- overwrite a substantial portion of the week;
- delete multiple planned meals;
- materially rewrite a Special Plan;
- bulk-clear Shopping or another user-owned collection.

High-risk operations MUST never execute from prose alone.

### 11.4 Confirmation is deterministic

When the user taps `Apply`, the app executes the already validated pending action. It does not ask the model to reinterpret the click.

## 12. Idempotency, retry, cancellation, and partial success

### 12.1 Idempotency

Every mutation has an `actionID` and `idempotencyKey`. Retrying a failed turn MUST NOT duplicate an already succeeded mutation.

### 12.2 Retry

Retry restarts only the failed stage when possible:

- generation failure -> retry generation;
- tool failure -> retry that tool/action;
- interpretation failure -> rebuild validated blocks.

Do not replay the entire turn when that can repeat side effects.

### 12.3 Cancel

Stopping generation cancels the active network/model task. Already received text remains visible and the message becomes `.cancelled`.

Cancel does not roll back a completed business action; Undo is separate.

### 12.4 Partial success

Successful blocks/actions remain visible if a later stage fails. A generated recipe remains available even if adding it to tonight fails; the error belongs to the failed operation.

## 13. User interface information architecture

### 13.1 Navigation

Title: `Kitchen AI`.

Top-right overflow menu:

- New Conversation;
- History;
- Rename current conversation;
- Pin / Unpin;
- Delete current conversation.

No persistent provider controls appear here.

After a first successful response, title generation runs without blocking the response. Until then the title is `新对话`. The generated title is short and task-oriented; a user-edited title is never overwritten automatically.

### 13.2 Context-aware empty state

Before the first message in a new conversation, show contextual starters.

Home examples:

- 用快过期的食材做饭
- 今晚想吃清淡一点
- 看看现在能做什么
- 帮我补一道菜

Planner examples:

- 调整这周菜单
- 帮我减少重复菜
- 周六聚餐怎么安排
- 看看哪天准备最轻松

The empty state may state which high-level sources can be consulted, but MUST NOT dump the kitchen dataset on screen.

Once the first user message is sent, starter prompts disappear and the page becomes the conversation stream.

### 13.3 Conversation presentation

- User messages use a restrained trailing bubble.
- Assistant prose is primarily open content, not a wall of large bubbles.
- Recipe, Planner preview, context result, status, and error blocks are embedded directly in the assistant flow.
- `Kitchen AI` attribution may identify assistant content, but AI gets no independent brand palette.

### 13.4 Composer

The persistent bottom composer contains text input, a reserved attachment architecture, Send, and Stop while streaming.

V1 MUST NOT expose a working image/file attachment action. If a leading `+` is rendered, it remains hidden or non-actionable until attachment support exists; no dead affordance may appear tappable.

### 13.5 Context chips

Compact chips above the composer communicate likely context sources for the next turn, for example `库存`, `今晚计划`, `本周计划`, or a named Special Plan.

Before Send, tapping a chip opens a small context sheet. The user may disable a source for the next message only. Those exclusions reset after that message is sent.

During an active turn, chips reflect the context sources actually used and are informational only.

Chips are not permanent decoration and never expose raw payloads.

## 14. History and conversation switching

History is reached from the top-right menu. V1 uses a native navigation destination or sheet, not a persistent sidebar.

Groups:

- 置顶
- 最近
- 已结束

Each row shows only title, a short last-message/summary excerpt, and time + active/ended status. No provider, token, tool-call, or diagnostic metadata is shown.

A new empty draft is not inserted into History. It becomes a persisted Conversation atomically when the first user message is persisted.

Opening an active conversation resumes it directly.

Opening an expired conversation shows its history first and requires explicit `继续此对话` before reactivation. Reactivation recalculates expiry; the next relevant turn rereads live domain state.

## 15. Conversation affinity

Entry surfaces choose the best candidate conversation by affinity rather than blindly reopening the most recent unrelated task.

```text
general
dailyMeal
weeklyPlanning
specialPlan
```

Home prefers `general` / `dailyMeal`. Planner prefers `weeklyPlanning` / `specialPlan` and matches the opened week or Special Plan anchor when available.

If no sufficiently relevant active conversation exists, show a new contextual empty state and a lightweight affordance to continue another active conversation.

## 16. Structured block design

### 16.1 Recipe block

One recipe object per block, with compact useful metadata and at most one primary plus one secondary action.

Typical actions:

- 查看菜谱
- 加入今晚

If a recipe already exists in `RecipeStore`, reference it. If AI creates a transient recipe, the block owns only the transient proposal until an explicit domain operation saves/materializes it.

### 16.2 Planner preview block

Shows actual before -> after diff.

```text
周三 · 晚餐
宫保鸡丁
   ->
清蒸鲈鱼

[换一个] [应用修改]
```

Batch changes list every affected day/meal before `应用 N 项修改`.

### 16.3 Action status block

Use a lightweight system-style row, not a celebratory assistant paragraph.

```text
✓ 已加入今晚    撤销
✓ 已把 4 项加入购物清单    查看购物清单 · 撤销
没有修改周三晚餐    重试操作
```

### 16.4 Context result block

Compact read-only structured data for Inventory / tonight / week / Special Plan summaries. It is not an embedded editor.

## 17. Visual language

The workspace extends Quiet Kitchen R3.1 rather than creating a new theme.

Required rules:

- use existing semantic system/KitchenTheme surfaces and spacing;
- preserve native SwiftUI navigation, sheets, Dynamic Type, VoiceOver, Dark Mode, and safe areas;
- retain the app's 44pt custom-control target;
- use hierarchy from typography, spacing, material, and restrained semantic color;
- no obligatory card around every assistant paragraph;
- no purple/blue AI gradient, glow, decorative sparkle wallpaper, or dashboard chrome;
- recipe blocks look like Recipe objects; Planner blocks look like Planner objects; AI provenance does not replace domain identity.

Motion remains restrained and semantic. Streaming text does not justify whole-screen entrance animation.

## 18. Error model

Errors are scoped to the failing layer.

### Provider/model failure

Show a concise AI-unavailable state with Retry. Preserve already rendered local content.

### Context read failure

Name the context that could not be read and, when safe, allow continuing without it.

Example: `暂时无法读取库存。仍可以不参考库存继续。`

### Tool/action failure

State clearly that the requested mutation did not happen and offer a targeted retry.

### Partial failure

Keep successful content/actions and attach an error only to the failed part.

All user-facing copy MUST remain truthful to what is currently visible and what actually mutated, consistent with the existing AI fallback-copy contract.

## 19. Conversation summary and token budget

The full local transcript is not sent on every request.

Model input is assembled from:

```text
system/product instructions
+ conversation summary
+ relevant live app context
+ bounded recent messages
+ current user message
```

Summary generation/update MUST NOT delay the first visible response. It may run after turn completion or be refreshed before a later request when needed.

Future entitlement policy may vary active period, pin allowance, recent-message window, and summary richness. It MUST NOT make local history disappear merely because a plan changes.

## 20. Suggested module boundaries

Exact filenames may adapt to the existing source layout, but these responsibilities MUST remain independently understandable/testable:

```text
AIConversationModels
ConversationPersistence
ConversationStore
ConversationRetentionPolicy
ConversationContextAssembler
ConversationOrchestrator
ConversationProviderRouter / capability adapter
ConversationResponseInterpreter
ConversationActionCoordinator
ConversationDomainTools
AIConversationView
AIConversationHistoryView
AIConversationBlocks
```

Domain tools are thin adapters over existing authoritative stores/services such as `KitchenStore`, `RecipeStore`, Planner projection/materialization logic, and Special Plan APIs. They MUST NOT fork business truth into an AI-owned schedule/inventory model.

## 21. Migration and data safety

Conversation persistence is additive.

Requirements:

- add new SwiftData records to shared production and in-memory/test schemas together;
- no destructive migration of Inventory, Recipe, Planner, Shopping, or Special Plan data;
- conversation migration failure must not clear unrelated kitchen data;
- deleting a conversation deletes only its local message/action/context-history records;
- deleting conversation history never reverses business actions that already changed canonical kitchen state;
- the current backup/restore version remains unchanged because V1 conversation history is explicitly excluded.

## 22. Testing strategy

### 22.1 Unit tests

At minimum cover:

- retention policy and expiry/reactivation;
- task anchors and affinity selection from Home vs Planner;
- summary + recent-message context budgeting;
- context exclusions for one turn only;
- context freshness / live reread behavior;
- provider capability routing;
- action risk classification;
- idempotency and retry after partial success;
- deterministic confirmation without model reinvocation;
- Undo where supported;
- content-block interpretation;
- truthful error mapping.

### 22.2 Persistence tests

Cover:

- Conversation/Message/Action/Context records round-trip;
- schema included in production and in-memory containers;
- draft-to-first-message atomic persistence;
- deletion cleanup behavior;
- existing kitchen data survives conversation persistence failures/migrations.

### 22.3 UI/routing tests

Cover:

- Home and Planner open the same workspace with different empty-state context;
- first message removes starters;
- generated title does not block first response and does not overwrite a user title;
- active conversation resumes;
- expired conversation requires explicit reactivation;
- History groups pinned/recent/ended correctly;
- streaming Stop preserves partial text;
- Planner preview requires confirmation;
- low-risk action shows status + Undo;
- Dynamic Type, Dark Mode, and VoiceOver basics.

Simulator is the default validation surface for focused unit/UI/routing/provider tests. Physical-device validation is reserved for capabilities that genuinely require it, especially Apple Foundation Models and device/network-specific behavior.

## 23. V1 acceptance scenarios

### Scenario A — Home recommendation to real action

1. Open Kitchen AI from Home.
2. Empty state reflects tonight/inventory context.
3. Ask: `今晚想吃清淡一点，把快过期的先用掉。`
4. AI streams a response and reads current Inventory truth.
5. Two real Recipe blocks appear.
6. User says: `第二个加入今晚。`
7. The system resolves the reference from conversation context.
8. A low-risk validated Planner action executes exactly once.
9. The stream shows `✓ 已加入今晚` with Undo.
10. Exit and reopen; the relevant active conversation resumes.

### Scenario B — Planner diff and confirmed mutation

1. Open Kitchen AI from Planner.
2. Ask: `把周三晚餐换清淡一点。`
3. The system reads current canonical Planner state.
4. AI proposes a replacement.
5. A Planner preview block shows the real before/after diff.
6. No schedule mutation occurs before confirmation.
7. User taps Apply.
8. The validated pending action executes without asking the model again.
9. Planner and conversation show the same resulting truth.
10. Retrying the turn cannot duplicate the mutation.

### Scenario C — Expired conversation with fresh truth

1. A previously active conversation expires.
2. History still contains it.
3. Opening it shows that it has ended and offers `继续此对话`.
4. Reactivating does not treat old Inventory/Planner observations as current facts.
5. The next relevant turn rereads live domain data before answering.

### Scenario D — Special Plan continuity

1. Open Kitchen AI from a Planner week containing a Special Plan.
2. Ask to change two dishes while keeping the existing people count and restrictions.
3. The system rereads the current Special Plan rather than trusting an old transcript snapshot.
4. A multi-item preview shows each before/after menu change.
5. No mutation occurs until explicit confirmation.
6. After confirmation, the Special Plan and conversation show the same resulting menu.

## 24. Deferred extensions

Not part of V1, but the design leaves room for:

- photo / camera / file attachments;
- receipt/menu/image understanding in the same composer;
- cross-device conversation sync;
- conversation export/backup;
- richer free/paid retention tiers;
- more content blocks such as richer Shopping previews or nutrition summaries;
- broader on-device conversation support when Apple model capabilities and safety boundaries are explicitly validated.

These extensions must preserve the same domain-truth, action-safety, and context-freshness boundaries.

## 25. Final invariant

Kitchen AI may decide what to suggest and which capability to request. It does not own kitchen truth.

**Conversation owns dialogue. Domain layers own facts and mutations. Structured previews make changes inspectable. Confirmed domain APIs make them real.**
