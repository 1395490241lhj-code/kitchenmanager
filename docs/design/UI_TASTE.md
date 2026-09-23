# Kitchen Manager UI Taste

Status: review heuristics for native UI refinement. This document does not override code, accepted Decisions, canonical project memory, Apple platform requirements, or `KITCHEN_DESIGN_LANGUAGE.md`.

## Purpose

Kitchen Manager already has a design language, tokens, components, accessibility rules, and accepted product/IA decisions. This file covers a different layer: judgment during visual refinement.

Use it when an implementation is already functionally correct and the remaining question is not "can this be built?" but "which visual choice should remain?"

Taste here is not a new style system. It is a compact way to evaluate hierarchy, attention, composition, restraint, and character.

## Core principles

1. Establish a clear visual hierarchy before decorating.
2. Give visual weight according to semantic importance.
3. Do not let every element compete for attention.
4. Prefer typography, spacing, and alignment before introducing containers.
5. Every container must earn its existence through grouping, task, state, or domain meaning.
6. Prefer subtraction before adding visual treatment.
7. Judge a screen as a composition, not as a collection of individually attractive components.
8. Compare alternatives when the right choice is unclear.
9. Change one visual variable at a time during refinement when practical.
10. Review the interface in use, not only as a static screenshot or Preview.
11. Use references to understand principles, not to copy a style.
12. Consistency should preserve product coherence without erasing contextual character.

"Quiet" is not itself the goal. Expressiveness is appropriate when it serves the semantic moment. Success, AI activity, onboarding, imagery, and empty states may carry more energy than utility or management surfaces when that difference is purposeful.

## Taste Pass

After a material UI change, answer these questions before adding more polish:

1. What receives attention first? Should it?
2. What receives attention second? Is the ordering intentional?
3. Are two unrelated elements competing at the same visual level?
4. Which visual treatment carries no information or useful grouping?
5. Would removing a card, border, badge, icon, tint, or effect improve the composition?
6. Is hierarchy carried primarily by typography, spacing, alignment, and content order before decoration?
7. Does the screen still feel like Kitchen Manager without becoming a rigid template?
8. Does the hierarchy survive real use: loading, error, long content, keyboard, Dark Mode, and relevant Dynamic Type sizes?
9. Compared with the previous version, what specifically became better? If the answer is only "it looks different," refinement is not yet justified.

## Comparison method

When judgment is uncertain:

- Keep behavior and data constant.
- Produce or inspect two alternatives.
- Change one meaningful visual variable where practical: hierarchy, grouping, typography, spacing, material, or motion.
- Compare the alternatives side by side or sequentially in the same state.
- Record the concrete reason for keeping one and rejecting the other.
- Stop once the hierarchy is clear; do not continue adding decoration merely because more variation is possible.

Component-level attractiveness does not imply screen-level quality. A card, badge, gradient, material, icon, or animation can be individually well made and still make the whole screen worse when every element asks for attention.

## Reference practice

A useful reference records both the example and the reason it matters. Prefer notes such as:

> Secondary metadata recedes through typography and spacing rather than another container.

over labels such as:

> Apple-like / clean / premium.

References calibrate judgment. They do not authorize copying another product's layout, brand, interaction, or visual identity.

## Relationship to the design system

`KITCHEN_DESIGN_LANGUAGE.md` defines accepted Kitchen Manager visual structure and semantics. This file helps choose among refinements that remain inside those boundaries. If a Taste Pass implies changing an accepted Decision, IA, product behavior, accessibility contract, or canonical design rule, stop and resolve that conflict through the existing project decision process instead of treating taste as authority.
