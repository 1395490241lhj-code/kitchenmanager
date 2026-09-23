---
name: km-ui
description: Use for Kitchen Manager native iOS/SwiftUI visual, interaction, motion, or accessibility work; preserve canonical design and load only the needed Apple/SwiftUI/accessibility guide.
---

# Kitchen Manager UI Router

Treat Kitchen Manager's canonical `UI Design System.md`, relevant accepted Decisions, and `docs/design/KITCHEN_DESIGN_LANGUAGE.md` as product-specific design authority.

Use external UI skills only as implementation/platform guidance. They never override Kitchen Manager product or IA decisions.

For material visual refinement, read `docs/design/UI_TASTE.md` as a judgment layer within those boundaries. After the change, run its Taste Pass on the affected screen in relevant use states and state what improved. Skip it for nonvisual work and minor mechanical UI changes; it does not define new tokens, components, or IA.

## Load only what the task needs

When the relevant external Skill is installed, read it only for the guidance the task needs:

- HIG, native component choice, platform convention, materials, navigation, interaction pattern, or Apple design intent:
  read `.agents/skills/apple-design-skill/SKILL.md`, then only the reference files it routes to.
- SwiftUI implementation, state/view composition, current APIs, performance, animation implementation, lists/navigation/sheets, or Instruments:
  read `.agents/skills/swiftui-expert-skill/SKILL.md`, then only relevant references.
- VoiceOver, Dynamic Type, accessibility semantics/testing, Switch Control, Voice Control, keyboard access, or inclusive interaction:
  read `.agents/skills/ios-accessibility/SKILL.md`, then only relevant references.

Do not load all three guides by default.

Missing external Skills do not block ordinary Kitchen Manager UI work. Continue with canonical project design authority and current implementation/platform evidence; do not invent missing guidance. If a missing guide materially limits a requested specialist review, report that limitation.

For material visual changes, pair this router with `km-ios-validation` and the visual acceptance rows in `docs/development/AI_CODING_ACCEPTANCE_MATRIX.md`.

Preserve existing Kitchen tokens/components before introducing new visual primitives. Prefer Apple public APIs; third-party visual helpers are capability references, not a new design system.
