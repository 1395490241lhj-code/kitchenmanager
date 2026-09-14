import Foundation

enum KitchenRecoverySnapshotError: LocalizedError, Equatable {
    /// The private recovery location could not be resolved at all.
    case storageUnavailable
    /// A previous restore left a recovery copy that nothing has resolved yet.
    /// Overwriting it would destroy the only way back from that restore.
    case outstandingSnapshotPresent
    /// The copy could not be written durably.
    case writeFailed
    /// The copy was written but could not be read back as a usable backup, so
    /// it cannot be relied on. The unusable file is removed.
    case unreadableSnapshot

    var errorDescription: String? {
        switch self {
        case .storageUnavailable, .writeFailed, .unreadableSnapshot:
            return "无法先保存导入前的本机数据副本，导入未开始。"
        case .outstandingSnapshotPresent:
            return "上一次导入留下的数据副本还没有处理，导入未开始。"
        }
    }
}

/// The durable copy of the kitchen taken immediately before a restore starts
/// replacing it.
///
/// One slot, one file. The file's presence *is* the state: while it exists the
/// copy is outstanding, meaning some restore's outcome has not been resolved
/// and that copy is still the only way back. `resolve()` is the single
/// authorised removal. There is deliberately no history, no rotation and no
/// unconditional delete for a failure path to call.
///
/// The bytes are whatever `KitchenStore.exportBackupData()` produces — the same
/// file a member could have exported by hand — so this introduces no second
/// serialisation format and no second notion of backup scope. User recipes,
/// favourites and frequent records are outside that payload and stay outside it
/// here.
///
/// Storage is app-private. The app declares no file-sharing entitlement, so
/// this location is not reachable from the Files app; nothing here may promise
/// a member that it is.
@MainActor
final class KitchenRecoverySnapshotStore {
    private static let filename = "pre-restore-recovery.json"

    private let directoryURL: URL?
    private let fileManager: FileManager

    init(directoryURL: URL?, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    /// Production. Application Support is app-private and survives termination,
    /// and unlike the App Group container it is not shared with the Share
    /// Extension, which has no business reading a copy of the kitchen.
    static func applicationSupport(fileManager: FileManager = .default) -> KitchenRecoverySnapshotStore {
        KitchenRecoverySnapshotStore(
            directoryURL: fileManager
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appending(path: "KitchenManagerRecovery"),
            fileManager: fileManager
        )
    }

    /// Previews and tests: a slot of its own per store, so one test's
    /// unresolved copy can never block another's restore. Mirrors the way
    /// `KitchenStore` substitutes an isolated in-memory persistence bundle.
    static func isolated(fileManager: FileManager = .default) -> KitchenRecoverySnapshotStore {
        KitchenRecoverySnapshotStore(
            directoryURL: fileManager.temporaryDirectory
                .appending(path: "KitchenManagerRecovery-\(UUID().uuidString)"),
            fileManager: fileManager
        )
    }

    var snapshotURL: URL? { directoryURL?.appending(path: Self.filename) }

    /// True while a copy is outstanding — written, and not yet resolved.
    var hasOutstandingSnapshot: Bool {
        guard let snapshotURL else { return false }
        return fileManager.fileExists(atPath: snapshotURL.path)
    }

    /// Writes the copy and proves it is usable before returning. Throwing here
    /// means no copy exists and the caller must not begin a destructive write.
    func prepare(_ backup: Data) throws {
        guard let directoryURL, let snapshotURL else {
            throw KitchenRecoverySnapshotError.storageUnavailable
        }
        guard !hasOutstandingSnapshot else {
            throw KitchenRecoverySnapshotError.outstandingSnapshotPresent
        }
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            // Atomic: a half-written file must never be mistaken for a copy.
            try backup.write(to: snapshotURL, options: .atomic)
        } catch {
            throw KitchenRecoverySnapshotError.writeFailed
        }
        do {
            // "No write error" is not proof. Read the bytes back off disk and
            // put them through the same gate a restore candidate goes through,
            // so a copy that could not be restored is never counted as one.
            _ = try KitchenBackupValidator.validate(try Data(contentsOf: snapshotURL))
        } catch {
            try? fileManager.removeItem(at: snapshotURL)
            throw KitchenRecoverySnapshotError.unreadableSnapshot
        }
    }

    /// The outstanding copy, if there is one.
    func outstandingSnapshot() throws -> Data? {
        guard let snapshotURL, hasOutstandingSnapshot else { return nil }
        return try Data(contentsOf: snapshotURL)
    }

    /// Marks the outstanding copy as no longer needed and removes it. The only
    /// way the slot is ever cleared, and always an explicit decision by the
    /// caller — never something a failure path does on its own.
    func resolve() throws {
        guard let snapshotURL, hasOutstandingSnapshot else { return }
        try fileManager.removeItem(at: snapshotURL)
    }
}
