---
name: km-ios-validation
description: Use for Kitchen Manager iOS/Swift/Xcode validation: build, XCTest/XCUITest, diagnostics/Previews, simulator/device choice, failure classification, and xcodebuild fallback.
---

# Kitchen Manager iOS Validation

Use Xcode as the authoritative build/runtime environment for Swift/SwiftUI/Xcode-facing changes. Source inspection alone is never evidence that an iOS change works.

Test selection remains owned by `docs/development/TESTING.md` §5. This skill controls how to drive and report iOS evidence, not which project tests exist.

## Canonical Xcode context

- Project: `ios-native/Kitchen Manager/Kitchen Manager.xcodeproj`
- Shared scheme: `KitchenManager`

Confirm the active Xcode context points to this project before using project-scoped tools. Treat MCP workspace identifiers, simulator UUIDs and DerivedData paths as session-local values; never hard-code them.

## Prefer Xcode MCP

When Apple's `xcrun mcpbridge` is available, use Xcode MCP for applicable builds, tests, diagnostics and previews.

Minimum evidence by surface:
- Swift implementation: build the `KitchenManager` scheme, inspect diagnostics, and run relevant automated tests where they exist.
- Tests: execute the relevant XCTest/XCUITest scope; compilation is not a passing test.
- SwiftUI/visual UI: build/test plus a usable Preview/render or simulator inspection for the affected states. Inspect the render rather than inferring appearance from source.
- Xcode project/capability/entitlement: validate through Xcode diagnostics/build behavior while respecting `AGENTS.md` hard boundaries.
- Documentation-only/non-iOS: no Xcode validation unless the change can affect the built app.

For visual work, cover only states actually affected: relevant light/dark appearance, Dynamic Type/text expansion, device/orientation, Reduce Motion and accessibility semantics. Do not generate arbitrary state permutations.

## Simulator and device policy

Prefer the simulator for focused unit, UI, routing and provider logic. Use a physical device only when hardware/runtime behavior materially matters, such as Keychain/app lifecycle, real network transitions, lock/background/relaunch, camera/photo/file integration, crash reproduction, performance/memory, or device-only Foundation Models behavior.

Follow `docs/development/TESTING.md` §§6–8 before hosted or physical-device work. Never expose credentials or claim a blocked human/system gesture passed.

## MCP unavailable

If Xcode MCP is unavailable:
1. state that explicitly;
2. use the supported `xcodebuild` workflow in `docs/development/TESTING.md` §4;
3. label evidence as fallback validation rather than MCP-backed validation;
4. never fabricate MCP output.

## Failure classification

When Xcode reports failure, distinguish:
- current-change regression;
- pre-existing baseline failure;
- environment/tool failure.

Do not repair unrelated project/environment problems merely to make the requested task green. Follow retry limits in `docs/development/WORKFLOW.md` §6.

A baseline claim needs comparison evidence on an appropriate pre-change tree/scope, not assumption or an old report.

## Report evidence precisely

For iOS implementation delivery, record:
- Xcode MCP or fallback path;
- project/scheme and actual destination when relevant;
- build outcome and diagnostics inspected;
- exact test scope and result;
- Preview/render/manual inspection for visual work;
- important suites/states not run.

Never infer a broader pass from a focused run.
