import Foundation

/// A small, file-backed FIFO queue that lets the Share Extension hand
/// `SharedImportRequest` values to the main app across process boundaries.
///
/// Deliberately not `UserDefaults.standard` (that's per-process/per-container
/// and isn't intended for this): this writes a JSON array into the shared
/// App Group container, coordinated with `NSFileCoordinator` so the
/// extension process and the host app process don't tear each other's writes.
public final class SharedImportQueue {
    public enum QueueError: Error, Equatable, Sendable {
        case containerUnavailable
        case queueFull
        case encodingFailed
        case writeFailed
    }

    /// Keeps the queue from growing without bound if the host app is never
    /// launched to drain it (e.g. repeated shares while offline).
    public static let maxQueueSize = 20

    /// Re-sharing the same normalized URL inside this window is treated as
    /// "already queued" rather than piling up a second identical request.
    public static let duplicateWindow: TimeInterval = 300

    private let fileURL: URL
    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = directoryURL.appendingPathComponent("shared_import_queue.json")
        // `.iso8601` truncates to whole seconds, which breaks equality/dedup
        // logic that compares `createdAt` after a disk round trip.
        // `.secondsSince1970` (a `Double`) preserves sub-second precision.
        decoder.dateDecodingStrategy = .secondsSince1970
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder = encoder
    }

    /// Convenience initializer for the App Group container. Returns `nil`
    /// (rather than a queue that will fail on every call) when the group
    /// entitlement/container isn't available, e.g. missing signing config.
    public static func appGroupQueue(
        appGroupIdentifier: String,
        fileManager: FileManager = .default
    ) -> SharedImportQueue? {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        return SharedImportQueue(directoryURL: containerURL, fileManager: fileManager)
    }

    /// Adds a request to the tail of the queue.
    ///
    /// - Returns: `true` if a new entry was written, `false` if this was a
    ///   duplicate of a recently-queued request for the same URL (a no-op,
    ///   not an error — the content is already pending import).
    @discardableResult
    public func enqueue(_ request: SharedImportRequest) throws -> Bool {
        try ensureDirectoryExists()
        var current = readAll()

        if let url = request.url {
            let isDuplicate = current.contains { existing in
                guard let existingURL = existing.url else { return false }
                guard existingURL == url else { return false }
                return request.createdAt.timeIntervalSince(existing.createdAt) < Self.duplicateWindow
            }
            if isDuplicate {
                return false
            }
        }

        guard current.count < Self.maxQueueSize else {
            throw QueueError.queueFull
        }

        current.append(request)
        try writeAll(current)
        return true
    }

    /// All pending requests, oldest first. Never throws: a corrupted file is
    /// treated as an empty queue (and reset on disk) rather than crashing
    /// the host app or the extension.
    public func peekAll() -> [SharedImportRequest] {
        readAll()
    }

    /// Removes a single request by id, e.g. once the main app has handed it
    /// off to Smart Import successfully. Missing ids are ignored.
    public func remove(id: UUID) {
        var current = readAll()
        guard current.contains(where: { $0.id == id }) else { return }
        current.removeAll { $0.id == id }
        try? writeAll(current)
    }

    public func removeAll() {
        try? writeAll([])
    }

    // MARK: - Disk I/O

    private func ensureDirectoryExists() throws {
        let directory = fileURL.deletingLastPathComponent()
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func readAll() -> [SharedImportRequest] {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: [SharedImportRequest] = []

        coordinator.coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { url in
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
            if let decoded = try? decoder.decode([SharedImportRequest].self, from: data) {
                result = decoded.filter { $0.schemaVersion == SharedImportRequest.currentSchemaVersion }
            } else {
                // Corrupted or unreadable file: reset rather than propagate a
                // crash into either process. Any not-yet-decoded requests
                // are unfortunately lost here, but a wedged queue that keeps
                // failing every future share is worse.
                try? fileManager.removeItem(at: url)
            }
        }
        return result
    }

    private func writeAll(_ requests: [SharedImportRequest]) throws {
        guard let data = try? encoder.encode(requests) else {
            throw QueueError.encodingFailed
        }

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var writeError: Error?

        coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinationError) { url in
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if coordinationError != nil || writeError != nil {
            throw QueueError.writeFailed
        }
    }
}
