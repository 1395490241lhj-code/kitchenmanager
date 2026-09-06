# Kitchen Manager Design Language v1

**Editorial Structure + Tactile Utility + Semantic Restraint**

Status: canonical production design language, visually approved.
Scope: native iOS Home, Inventory and Recipes. Other destinations retain their existing
semantics and presentation until deliberately brought into this language. The next adoption
boundary is Shopping, followed by Meal Plan / Planner and Profile / Settings. No recipe media dependency.

Implementation owners: `KitchenTheme.swift` (geometry/material/color),
`KitchenControls.swift` (controls, labels, metadata and marks), `HomeMealHero.swift`
(meal composition), `InventoryControlStrip.swift` (interactive console), and
`RecipeViews.swift` / `RecipeCookingModeView.swift` (recipe reading and cooking).

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
