import Foundation

/// Single source of truth for the App Group identifier shared by the main
/// app and `KitchenManagerShareExtension`. Must match the App Groups
/// entitlement on both targets exactly.
public enum SharedImportConfig {
    public static let appGroupIdentifier = "group.com.lianghongjing.kitchenmanager"

    public static func makeQueue(fileManager: FileManager = .default) -> SharedImportQueue? {
        SharedImportQueue.appGroupQueue(appGroupIdentifier: appGroupIdentifier, fileManager: fileManager)
    }
}
