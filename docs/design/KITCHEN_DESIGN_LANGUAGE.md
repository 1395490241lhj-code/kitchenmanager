# Kitchen Manager Design Language — Quiet Kitchen R3.1

## Current production revision — frozen behavior / IA prototype

Owner-approved at implementation `d9da474`; visual/IA design is frozen. [Engineering seal and evidence](../archive/ios/BEHAVIOR_CONTRACT_SEAL.md) records the final gate and integration status. Existing Quiet Kitchen R3.1 tokens/palette remain; this revision records the accepted structures and controls, not a new global visual redesign.

- Home: ordinary cooking/flexible days show one tappable date row; exceptional state may add one meaningful context line. No redundant hero `今晚`. Presence-only readiness uses `所需食材已在库` / `N/M 食材已在库` over all today's plans. One dish is hero-only; two add `配 …`; three or more use `另有 N 道` with only remaining dishes inside. No aggregate multi-dish duration. At most two named attention rows plus overflow. `开始做饭` enters the shared cooking flow; `查看菜谱` remains secondary beside it. Since the 002 Home IA consolidation (canonical D-042), planning management is the single secondary route `用餐计划` → Planner, discovery is the single control `更多推荐`, and `今天的计划` no longer exists.
- Inventory: permanently discoverable native Search, one filter surface with counts in choices, persistent filter during search and independent clear behavior. Healthy rows suppress redundant expiry metadata; active constraints and no-results remain explicit. Accessibility sizes use the compact native Menu.
- Planner: individually empty days keep only the dated header; no `暂无安排` body row or permanent per-day plus. Existing week navigation, planned/Special Plan rows, toolbar creation and whole-empty-week creation remain. No ordinary-meal CRUD or weekly AI materialization was added.
- AI identity (canonical D-038): AI is a capability, not a second visual brand. Actions normally inherit the host surface's semantic/accent hierarchy; sparkles may identify capability. Independent indigo is no longer prescribed merely for AI. Home's approved action demonstrates this; compatibility tokens and other legacy AI uses were not globally restyled.
- 44pt remains the app target. The sole segmented-control exception (D-039) is this exact unmodified four-choice Inventory Picker. The accepted iPhone 17 Pro probe recorded about 32pt visual/AX height; taps 3pt above and below inside a 44pt wrapper did not select a segment. Do not infer expanded hit testing from layout bounds or claim blanket HIG compliance. Retain native selection/spacing/VoiceOver state and the Accessibility Menu; custom actions still require >=44pt. The bounded test uses Apple's 28pt iOS platform floor; WCAG's 24 CSS-pixel reference does not lower the app target.

Home semantic precedence is mealPrep → dinner eatOut → Special Plan today → Today Plan → quick → recommendation; the Special Plan step was added by 002 (D-042). Ordinary Planner CRUD shipped with D-040 and AI weekly materialization with D-041, so neither is deferred any longer. Quantity-aware sufficiency is still deferred. No AI-provenance label or field was added.

The prior v1 text below is historical wherever it conflicts with this revision. In particular, old indigo references do not instruct future implementations to restore a separate AI brand; old console/empty-day descriptions do not restore removed repetition. Current code and the canonical vault remain authoritative.

## Motion

Motion is restrained and semantic, never decorative. Prefer SwiftUI system spring
presets over custom easing curves. `KitchenMotion` lives beside `KitchenTheme`:

| Token | Preset | Purpose |
|---|---|---|
| quick | `snappy(duration: 0.2)` | Direct selections and small controls. |
| standard | `smooth(duration: 0.28)` | Content or local layout state transitions. |
| emphasis | `smooth(duration: 0.32, extraBounce: 0.05)` | Rare emphasis with a very light spring; unused in this spike. |

Preserve system-native NavigationStack, sheet, tab, picker, toggle and other
platform transitions. Avoid broad implicit animations over large hierarchies;
scope animation to the state, property or component that actually changes.
Read `accessibilityReduceMotion` at the view and pass `nil` for custom motion
when enabled. Preserve existing accessibility labels, traits and feedback.
State changes and actions remain immediate and interruptible; never wait for an
animation to finish before allowing interaction or completing a task.

This spike animates only the Accessibility-size Inventory Menu's current-filter
text with quick (the segmented Picker stays native), and Home's existing
remaining-dishes disclosure with standard. AI result appearance gets no extra
animation: the inspected recommendation flow already uses a native pager, and
initial Home content loading is not an entrance-animation opportunity.

No whole-screen animation, appearance-only animation, staggered entrance,
exaggerated bounce, decorative scale or Dribbble-style motion. Existing motion
outside these two interactions is not globally migrated by this spike.

## Prior v1 specification — historical where superseded above

**Editorial Structure + Tactile Utility + Semantic Restraint**

Status: canonical production design language, visually approved.
Scope: native iOS Home, Inventory, Recipes, Shopping and Meal Plan / Planner. Other destinations retain their existing
semantics and presentation until deliberately brought into this language. The next adoption
boundary is Profile / Settings. No recipe media dependency.

Implementation owners: `KitchenTheme.swift` (geometry/material/color),
`KitchenControls.swift` (controls, labels, metadata and marks), `HomeMealHero.swift`
(meal composition), `InventoryControlStrip.swift` (interactive console),
`RecipeViews.swift` / `RecipeCookingModeView.swift` (recipe reading and cooking),
`MainFeatureViews.swift` (Shopping list and native entry), and `PlannerPresentation.swift`
with `PlannerView.swift` / `SpecialPlanDetailView.swift` (Planner lists and event detail).

## Roles

| Role | Responsibility |
|---|---|
| Hero Card | One dominant decision/task surface. Context, title, support, metadata, readiness, actions, then menu. |
| Module Surface | Groups related actionable states or expandable content. May share its parent material; no obligatory nested card. |
| Compact Control / Status | A short status or operation. Status is not styled as a button. Interactive controls retain press feedback and 44pt minimum targets. |
| Open Row | High-frequency scan information and destinations. No per-row card. |
| Context / Section Label | Names the moment or group, using native text and a structural horizontal mark. |
| Semantic State Rail | Marks object state; never an extra spoken label or decorative flourish. |

Hierarchy comes from spacing, typography and material. Only the hero has restrained
elevation; modules and rows do not accumulate shadows. A container needs a task/grouping
role, not merely a desire to separate two things.

## Geometry

Canonical values live in KitchenTheme:

| Token | Points |
|---|---:|
| pageGutter | 20 |
| heroPadding | 16 |
| modulePadding | 14 |
| rowVerticalInset | 6 per edge |
| sectionSpacing | 24 |
| heroSpacing | 14 |
| railTextGap | 6 |
| contextRailLength / stateRailLength / railThickness | 12 / 28 / 3 |
| iconSize / destinationIconSize / statusIconSize | 26 / 24 / 22 |
| controlHeight | 44 minimum |
| featureRadius / functionalRadius / compactRadius | 24 / 16 / 12 |
| consolePadding / consoleVerticalPadding | 16 / 8 |

Page edges and Inventory section/row markers share the 20pt coordinate. Content
inside a hero is inset a further 16pt. Insets express containment, not exceptions
to the page rail. 食材 and 常备食材 headers use explicit List header insets.
Normal and attention rows use the same row insets. Quantity text aligns to the
trailing rail and receives priority over long names.

## Rails and labels

- Horizontal capsule: structural context, such as 推荐, 今晚, 食材, 常备食材.
- Vertical capsule: an object's expiry, tonight linkage or meaningful stock state.
- Ordinary rows may retain a very quiet neutral mark; colored marks carry information.
- Context already marked horizontally must not acquire a decorative vertical mark.
- Rail and text are separate layout children; never text underlining or an overlay
  crossing glyphs. Rails are hidden from accessibility.
- Context labels use native footnote semibold, section labels subheadline semibold
  with quieter monospaced counts. No serif contextual labels.

## Color and material

Warm stone canvas: Light #F7F7F4 / Dark #181A17.
Hero surface: #FFFFFD / #222420. Supporting material: #F0F1ED / #2B2D28.

Forest fill identifies primary cooking action; sage identifies cooking/readiness
and tonight linkage. Terracotta identifies freshness urgency, ochre replenishment,
indigo AI. Neutral warm gray supports the hierarchy. Management semantics elsewhere
remain distinct; this language does not redefine product behavior.

Use readable foreground colors independently of surface fills. Non-interactive
readiness has a quieter translucent supporting material, no border or shadow,
and retains its status identity. It is not disabled and not a competing CTA.

## Typography and icons

System Chinese body typography scales with Dynamic Type. Hero display typography
retains the approved system editorial design. Numeric metadata uses monospaced
semibold numbers, quieter units and middot-separated groups; text wraps as a
single attributed paragraph, not disconnected numeric/unit layout fragments.
No invented values or placeholders. Readiness is announced/presented once.

SF Symbols are used for action, destination and special-utility identity.
The shared container uses semibold symbols, optical size 44% of its container,
12% semantic tint fill and a corner radius of 32% of its size. Absence of an icon
is not a defect. Console stats intentionally have no icons. Existing staple-state symbols use an explicit
body font with the chrome size ceiling so inherited large fonts cannot overflow
the shared icon column; ingredient text remains unrestricted.

## Controls and inventory density

Primary: dominant forest fill. Secondary: quieter contained material.
Utility: compact low-mass control, with indigo reserved for AI where relevant.
Navigation: open destination row with chevron. Avoid making every control a pill.

Inventory summary numbers remain real filter buttons with complete VoiceOver
labels and press feedback. Equal flexible columns share number/label baselines
and identical padding in both two-stat and three-stat states. No persistent
selection tile or selection rail in the summary: native filter control is the
single visual selection authority.

Inventory is more open than Home. Names, quantities, status, and tonight linkage
remain visible rather than being removed to shorten the page. Common staples
obey the same gutter as fresh ingredients.

## Recipes application

Recipes uses less semantic color than Inventory: information is primarily typographic,
with forest reserved for the primary cooking action. Do not add decorative vertical
status rails, ingredient cards or repeated utility icons.

- Library uses open editorial rows: dish name first, metadata second, at most two useful
  tag/context lines, and subordinate availability. It is not a wall of cards.
- Detail uses a no-photo typography hero. Title, metadata and context establish hierarchy;
  no fake media placeholder or decorative hero card is required.
- Servings uses a compact Module Surface. Current servings is primary and base servings
  is supporting. Known base servings scale written quantities; an unknown base preserves
  the original amounts. Adjusting the cooking session never changes the stored recipe.
- Ingredients and seasonings use open checklist rows. Quantities align to the trailing
  content rail, with names and long quantities wrapping naturally without collision.
- Static steps use plain numbers and readable, Dynamic Type Chinese body text. Long text
  remains scrollable; the last step must clear the pinned Start Cooking action.
- Cooking Mode groups the current step in a Module Surface. The timer is utility;
  next/finish is the dominant primary action. Large text may place controls below the
  fold, where they must remain reachable.
- The editor retains its native utility Form. Populated fields keep persistent labels;
  the cooking-time input itself communicates its meaning, minutes and current value.
  Form group edges use the 20pt page gutter; native cell content keeps its own inset.
  This native containment is intentional and does not require a second editor theme.

Library, filter controls, detail sections and Cooking Mode share KitchenTheme.pageGutter.
Contained servings/current-step content uses modulePadding inside that coordinate.
Use the existing roles and controls; Recipes does not introduce a new design-system role.

## Accessibility and interaction

- Preserve existing identifiers and destinations; presentation-only menu expansion
  stays local and never persists. Menu heading reports total dishes and completed dishes from the whole plan,
  not from its preview rows.
- Expanded menu keeps dish destinations and overflow reachable. Reduce Motion
  disables the expansion animation.
- Do not shrink dish text to make a hero fit. Metadata/status may wrap; action pairs
  reflow while keeping hit targets.
- Inventory uses an inline title, compact summary reflow and native filter Menu at
  accessibility sizes. The first real ingredient must remain visible on launch.
- Bottom list/scroll clearance must permit last content to rest above the floating
  tab bar. Tests verify tap reachability as well as appearance.
- Validate Light/Dark at normal and Accessibility XXXL, plus small-phone Light.
  Capture actual normal production rendering with only data/appearance fixtures.

No runtime design selection, production experiment route or persistence is needed.

## Shopping application

Shopping is execution/completion-led: identify the grocery item, read its amount and
complete it with a whole-row action. It generally does not require a Hero.

- Open rows are canonical. Names dominate; precise quantity/unit text is subordinate
  and right-aligned at normal sizes. Preserve the complete formatted amount rather than
  splitting or reinterpreting it. Long Chinese names wrap; accessibility sizes stack
  name, amount and source while preserving minimum interaction targets.
- Stored source/context is tertiary. Do not invent richer provenance, show ordinary
  generated items as AI states, or introduce decorative food icons.
- Category and purchased-group headings use contextual horizontal marks. Keep the
  existing grouping, ordering, collapse behavior and truthful whole-list counts;
  each category does not need a large card. No decorative vertical shopping rails.
- Summary, category marks and open rows share the 20pt content coordinate. The native
  List keeps bottom clearance so the final item can scroll above the floating tab bar.
- Keep the native navigation background visible over scrolling content. Category
  headers must not compete with the title or search controls; preserve native search
  geometry rather than adding a compensating top inset.
- Completion uses a clear control state and readable secondary text. Do not stack
  strike-through, low opacity, gray text and a green row fill. Completed rows remain
  actionable so users can restore the pending state.
- Shopping uses less semantic color than Inventory. Forest/sage belongs to completion,
  neutral to ordinary content, and management blue remains the existing toolbar utility
  role. Indigo is reserved for actual AI utility; destructive actions retain their native
  destructive role. Inventory expiry colors do not belong here.
- Search, menus and destructive confirmations stay native. The add sheet retains its
  native Form and existing fields; populated name, quantity and unit keep understandable
  field identity. Native Form containment is appropriate, with its group edges inset
  20pt from the sheet's content area.

Shopping introduces no new canonical role and does not redefine generation, stock-in,
duplicate merging, classification or persistence semantics.

## Planner application

Planner is date-led: understand the arrangements across a week, find the relevant day and
open a dish or event to inspect or adjust it. Home keeps the Today task hero; Planner has
no Hero.

- Week range and date headers are the structure. Every date is a section label with a
  neutral horizontal mark; only today carries a sage mark and one `· 今天` annotation.
  Days are not color-coded and there is no selected-day mode or calendar picker; the
  existing native previous/current/next week menu remains the navigation.
- Ordinary dishes are open rows on the plain canvas: name first, servings or 已完成 as
  subordinate caption, chevron destination. No per-row fork icons and no per-dish card.
  Several dishes on one day remain separate rows; nothing is truncated or previewed.
- Empty dates stay in place with 暂无安排. A fully empty week keeps its single create
  affordance. Planner adds no per-day add, edit, reorder or leftover projection.
- Special Plan events are open rows with a sage icon container and their existing
  people/time/constraint caption. The detail shows the request and essential context in
  one elevated Module Surface, then the saved menu and draft as open rows under
  `KitchenSectionLabel` headings with total counts. Draft save is the forest primary
  action; generation, replacement and discard keep their existing secondary/utility roles.
  Completed dishes use the forest control state.
- AI actions (special composer, draft generation, weekly generation) use indigo only on
  their own controls; the weekly generator keeps its native Form on the canvas.
- Lists use the plain style on the canvas with the 20pt gutter, a visible navigation
  background over scrolling content, and native footers rendered as quiet captions.

Planner introduces no new canonical role and does not change PlannerProjection,
SpecialPlan, weekly-plan models, shopping generation or AI contracts.
