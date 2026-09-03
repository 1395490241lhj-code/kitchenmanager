import XCTest

/// How a UI test may observe a Special Plan draft menu.
///
/// The draft is a SwiftUI `List`, which mounts only the rows near the
/// viewport. Anything that counts mounted rows, or snapshots "every visible
/// label" and waits for that set to change, is measuring the viewport and not
/// the menu. The live E2E used to do exactly that: it read a six-dish menu as
/// four, then waited 120 s for a replacement it had no way to see because the
/// row it was watching was never the row that changed.
///
/// The rules here:
/// - a *specific* row is addressed by its own dish id. The app keeps that id
///   stable across replacement (`replacement.id = original.id`), so the same
///   identifier names the slot before and after, and success is simply that
///   slot's title changing;
/// - a provider answer is a first-class outcome. `planner.menu.error` is what
///   the app shows when generation or replacement fails, and it is returned
///   the moment it appears rather than waited past;
/// - cardinality is never inferred from the screen. Whether a menu of N
///   dishes is acceptable for a request of M is `SpecialPlanMenuTests`'
///   contract (`assertCardinality`), not something to re-derive by counting
///   whatever happens to be mounted.
enum SpecialPlanDraftObservation {
    static let dishPrefix = "planner.menu.draft.dish."
    static let replacePrefix = "planner.menu.draft.replace."
    static let errorIdentifier = "planner.menu.error"
    static let generatingIdentifier = "planner.menu.generating"

    /// One draft slot, named by the id the app keeps stable across replacement.
    struct Row: Equatable {
        let id: String
        let title: String
    }

    enum Outcome: Equatable {
        /// The row(s) the caller asked about are showing the expected state.
        case accepted
        /// The app surfaced an error. The text is the app's own message; the
        /// caller decides whether that is a live-provider answer or a bug.
        case liveProviderFailure(String)
        /// The loading state came and went with neither rows nor an error.
        /// That is not a provider outcome — the app should always land on one
        /// or the other — so it is reported separately from a timeout.
        case settledWithoutDraft
        case timedOut
    }

    // MARK: - Queries

    /// Every draft title currently mounted. Only ever a *sample* of the menu.
    static func mountedRows(in app: XCUIApplication) -> [Row] {
        app.staticTexts
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", dishPrefix))
            .allElementsBoundByIndex
            .compactMap { element in
                let identifier = element.identifier
                guard identifier.hasPrefix(dishPrefix) else { return nil }
                return Row(id: String(identifier.dropFirst(dishPrefix.count)), title: element.label)
            }
    }

    /// The top of the list: mounted by construction, so it can be tapped and
    /// watched without any scrolling and without guessing which row
    /// `firstMatch` happened to resolve to.
    static func firstMountedRow(in app: XCUIApplication) -> Row? {
        mountedRows(in: app).first
    }

    static func titleElement(for id: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts[dishPrefix + id]
    }

    static func replaceButton(for id: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons[replacePrefix + id]
    }

    // MARK: - Scrolling

    /// Bounded, deterministic scrolling toward one known element. Never an
    /// open-ended "swipe until something turns up".
    @discardableResult
    static func scroll(
        to element: XCUIElement,
        in app: XCUIApplication,
        direction: ScrollDirection = .down,
        maxSwipes: Int = 8
    ) -> Bool {
        var remaining = maxSwipes
        while !(element.exists && element.isHittable) && remaining > 0 {
            switch direction {
            case .down: app.swipeUp()
            case .up: app.swipeDown()
            }
            remaining -= 1
        }
        return element.exists && element.isHittable
    }

    enum ScrollDirection { case down, up }

    /// Finds one draft row by id, scrolling for it if it is not mounted. Used
    /// while polling so that a row that is *off screen* at the moment of
    /// checking is brought back rather than read as absent.
    static func locateTitle(for id: String, in app: XCUIApplication) -> XCUIElement? {
        let element = titleElement(for: id, in: app)
        if element.exists { return element }
        if scroll(to: element, in: app, direction: .up, maxSwipes: 4) { return element }
        if scroll(to: element, in: app, direction: .down, maxSwipes: 8) { return element }
        return element.exists ? element : nil
    }

    // MARK: - Generation

    /// Waits for a generation the user just started. Resolves on the first
    /// mounted draft row, or on the app's own error — whichever the provider
    /// produced. A row count is deliberately not part of the result.
    static func waitForGeneration(in app: XCUIApplication, timeout: TimeInterval) -> Outcome {
        let loading = app.descendants(matching: .any)[generatingIdentifier]
        let errorRow = app.staticTexts[errorIdentifier]
        let deadline = Date().addingTimeInterval(timeout)
        var sawLoading = false
        var settledAt: Date?
        while Date() < deadline {
            if errorRow.exists { return .liveProviderFailure(errorRow.label) }
            if firstMountedRow(in: app) != nil { return .accepted }
            sawLoading = sawLoading || loading.exists
            if sawLoading, !loading.exists {
                settledAt = settledAt ?? Date()
                if Date().timeIntervalSince(settledAt!) >= 3 { return .settledWithoutDraft }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return .timedOut
    }

    // MARK: - Replacement

    /// Taps `row`'s own replace button and watches *that row alone* until its
    /// title changes, the app reports an error, or `timeout` passes.
    ///
    /// The row may be off screen by the time the reply lands: `locateTitle`
    /// scrolls for it on every poll, so an unmounted row is never read as an
    /// unchanged one. Returns the new title on success.
    static func replace(
        _ row: Row,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> (outcome: Outcome, newTitle: String?) {
        let button = replaceButton(for: row.id, in: app)
        guard scroll(to: button, in: app) else { return (.timedOut, nil) }
        button.tap()

        let errorRow = app.staticTexts[errorIdentifier]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if errorRow.exists { return (.liveProviderFailure(errorRow.label), nil) }
            if let title = locateTitle(for: row.id, in: app) {
                let current = title.label
                if current != row.title { return (.accepted, current) }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return (.timedOut, nil)
    }
}
