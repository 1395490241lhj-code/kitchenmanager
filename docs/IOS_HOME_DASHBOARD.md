# iOS Home Dashboard

> [!warning] Historical / Superseded — retained for provenance
> **This document describes the pre-recommendation-first Home design and no longer
> describes current behavior.** It was last updated on 2026-07-17 (`c1beee8`);
> `HomeView.swift` has been substantially rewritten since, most significantly by
> `4992f68` (Home became a Today surface).
>
> Specifically superseded: the "Information order" section below states that
> Today's plan carries **the page's only prominent action**. That was first
> superseded by `4992f68`, which gave Today's Recommendation first-screen
> priority, made the plan card render only when a plan exists, and started an
> empty plan with the inline recommendation rather than an empty-plan message.
>
> It was superseded again by Home V2 (`0f0404a`), which is the current design:
> Home is a stateful Today surface ordered `Today Context → one Primary Task →
> Needs Attention`. Recommendation is the primary task only while nothing is
> decided; once a Today Plan exists, the plan becomes the primary task and
> recommendation is demoted to a secondary `想再加一道` link. Current Home
> behaviour lives in canonical project memory (`Product & IA.md`, `Decisions.md`),
> not in this file.
>
> **Current Home IA is defined by the implementation and its tests**, not by this
> file — see `ios-native/Kitchen Manager/KitchenManager/HomeView.swift` and
> `ios-native/Kitchen Manager/KitchenManagerUITests/HomeDashboardUITests.swift`,
> which assert the section order directly. Canonical project memory records the
> same hierarchy and the reasoning behind it.
>
> The body below is unchanged and kept as the record of the earlier design.

The iOS home tab is a daily-triage surface, not a catalog of kitchen
features. It uses existing local `KitchenStore`, recipe, navigation, and auth
state; it does not initiate sync, network requests, or Guest-data migration.

## Information order

1. A date-aware greeting and, when useful, the active household name.
2. Today's plan, showing no more than three entries, completion progress, and
   the page's only prominent action.
3. At most one highest-priority reminder: purchased items awaiting stock-in,
   expired inventory, expiring inventory, pending shopping, then low stock.
4. Safe local persistence notices, only when a module reports a problem.

The prominent action is derived from existing capability and navigation:
purchased items open Shopping's existing stock-in confirmation; an empty plan
opens recipe recommendations; an unfinished plan opens its detail; and a
completed plan opens the Recipes tab. The toolbar preserves add and
account/settings access. The five-tab hierarchy, sheets, back navigation,
SwiftData write paths, and explicit inventory-consumption flow are unchanged.

Local data renders immediately. Auth restoration is a quiet inline status,
not a loading gate. Home never starts sync, retries sync, enables a feature
flag, or describes Guest mode as an error.

## State and accessibility

`HomeDashboardSummary` is the single pure projection for plan state, the
dynamic primary action, aggregated inventory/shopping counts, and the one
highest-priority reminder. Navigation side effects stay in `HomeView`. Each
module can surface a safe, generic notice without making the rest of Home
unavailable or exposing storage/backend details.

The dashboard uses system semantic colors, text plus SF Symbols for reminders,
Dynamic Type-compatible layouts without fixed content heights, and stable
identifiers under the `home.*` namespace. Pending plan rows retain stronger
visual weight; completed rows and the all-complete container become quieter.
Toast replacement uses a restrained fade when Reduce Motion is enabled and no
celebration animation is introduced.

## Preview coverage

`HomeView.swift` includes previews for populated data, an empty dashboard,
dark mode, and an accessibility Dynamic Type size. Preview stores are isolated
and never participate in the production runtime path.
