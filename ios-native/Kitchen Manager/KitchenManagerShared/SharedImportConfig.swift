import Foundation

/// Single source of truth for the App Group identifier shared by the main
/// app and `KitchenManagerShareExtension`. Must match the App Groups
/// entitlement on both targets exactly.
public enum SharedImportConfig {
    public static let appGroupIdentifier = "group.com.lianghongjing.kitchenmanager"

    public static func makeQueue(fileManager: FileManager = .default) -> SharedImportQueue? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(uiTestQueueArgument),
           let directory = uiTestQueueDirectory(fileManager: fileManager) {
            return SharedImportQueue(directoryURL: directory, fileManager: fileManager)
        }
        #endif
        return SharedImportQueue.appGroupQueue(appGroupIdentifier: appGroupIdentifier, fileManager: fileManager)
    }

    #if DEBUG
    /// Points the main app's queue at a directory inside its **own**
    /// container instead of the App Group. A UI test process cannot write
    /// the app's App Group container, and the queue must survive an
    /// `app.terminate()` + relaunch for the "a deleted import stays
    /// deleted" scenario to mean anything — so the app itself owns the
    /// file and the test only drives it through launch arguments.
    ///
    /// DEBUG-only and opt-in: Release builds always use the real App Group
    /// queue, and no UI test replaces the production coordinator or any of
    /// the production lifecycle logic being verified.
    public static let uiTestQueueArgument = "UITEST_SHARED_IMPORT_QUEUE"
    /// Clears the UI-test queue before seeding, so each test starts clean.
    public static let uiTestResetArgument = "UITEST_SHARED_IMPORT_RESET"
    /// Enqueues exactly one request, as if the Share Extension had run.
    public static let uiTestSeedArgument = "UITEST_SEED_SHARED_IMPORT"
    public static let uiTestSeedURL = "https://example.com/ui-test-shared-import"

    public static func uiTestQueueDirectory(fileManager: FileManager = .default) -> URL? {
        guard let support = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return support.appendingPathComponent("UITestSharedImportQueue", isDirectory: true)
    }

    /// Applies the launch-argument-driven reset/seed to the UI-test queue.
    /// A no-op unless `uiTestQueueArgument` is present.
    public static func applyUITestQueueSeedingIfRequested(fileManager: FileManager = .default) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(uiTestQueueArgument) else { return }
        guard let queue = makeQueue(fileManager: fileManager) else { return }

        if arguments.contains(uiTestResetArgument) {
            queue.removeAll()
        }
        guard arguments.contains(uiTestSeedArgument) else { return }
        try? queue.enqueue(
            SharedImportRequest(
                source: .sharedURL,
                url: URL(string: uiTestSeedURL),
                text: nil,
                originalHostBundleIdentifier: nil
            )
        )
    }
    #endif
}
