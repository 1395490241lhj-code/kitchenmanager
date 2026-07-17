# iOS Home Dashboard

The iOS home tab is a daily-triage surface, not a catalog of kitchen
features. It uses existing local `KitchenStore`, recipe, navigation, and auth
state; it does not initiate sync, network requests, or Guest-data migration.

## Information order

1. A date-aware greeting and, when useful, the active household name.
2. Today's plan, showing no more than three entries and completion progress.
3. Only actionable inventory counts: expired, expiring soon, and low stock.
4. A compact pending-shopping summary with at most three item names.

The plan card owns the main empty-state action. The toolbar provides
secondary add actions and account/settings access. Full views remain in the
system tab hierarchy and summary routes preserve the selected tab state.

## State and accessibility

`HomeDashboardSummary` is the single pure projection for plan, inventory, and
shopping counts. Each module can surface a safe, generic retry notice without
making the rest of Home unavailable. The dashboard uses system semantic
colors, Dynamic Type-compatible text, and stable identifiers under the
`home.*` namespace for UI tests.

## Preview coverage

`HomeView.swift` includes previews for populated data, an empty dashboard,
dark mode, and an accessibility Dynamic Type size. Preview stores are isolated
and never participate in the production runtime path.
