import XCTest
import SwiftData
import SQLite3
import CryptoKit
@testable import KitchenManager

@MainActor
final class PreparedLifecycleSchemaUpgradeTests: XCTestCase {
    private var directory: URL!
    private let origins = ["prepared-pre-pr2", "prepared-pr2"]

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "prepared-pr3-upgrade-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func fixture(_ origin: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: origin, withExtension: "store"))
    }
    private func copy(_ origin: String, to target: URL? = nil) throws -> URL {
        let url = target ?? directory.appending(path: origin + ".store")
        try FileManager.default.copyItem(at: fixture(origin), to: url)
        return url
    }
    private func container(_ url: URL) throws -> ModelContainer {
        try KitchenPersistenceFactory.makeContainer(configuration: ModelConfiguration(url: url))
    }
    private func query(_ url: URL, _ sql: String, immutable: Bool = false) throws -> [[String]] {
        var db: OpaquePointer?
        let location = immutable ? url.absoluteString + "?immutable=1" : url.path
        guard sqlite3_open_v2(location, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db); throw NSError(domain: "pr3-sql-open", code: 1)
        }
        defer { sqlite3_close(db) }
        // Core Data can finish a WAL checkpoint after its context is released.
        sqlite3_busy_timeout(db, 5_000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            for suffix in ["", "-wal", "-shm"] {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: url.path + suffix)) {
                    let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.data")
                    evidence.name = "sql-failure-" + url.lastPathComponent + suffix
                    evidence.lifetime = .keepAlways; add(evidence)
                }
            }
            throw NSError(domain: "pr3-sql-prepare", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(message); \(sql); \(url.lastPathComponent)"])
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { n in
                switch sqlite3_column_type(statement, n) {
                case SQLITE_NULL: return "null:"
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, n))
                    let data = count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, n)!, count: count)
                    return "blob:" + data.base64EncodedString()
                default: return "value:" + String(cString: sqlite3_column_text(statement, n))
                }
            })
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw NSError(domain: "pr3-sql-step", code: Int(status)) }
        return rows
    }
    private func columns(_ url: URL, table: String = "ZPREPAREDCOMPONENTRECORD", immutable: Bool = false) throws -> [String] {
        try query(url, "PRAGMA table_info(\(table))", immutable: immutable).map { String($0[1].dropFirst(6)) }
    }
    private func snapshot(_ url: URL, origin: String, immutable: Bool = false) throws -> [String: [[String]]] {
        let tables = try query(url, "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Z%' ORDER BY name", immutable: immutable)
            .map { String($0[0].dropFirst(6)) }.filter { !["Z_METADATA", "Z_MODELCACHE", "Z_PRIMARYKEY"].contains($0) }
        var result: [String: [[String]]] = [:]
        for table in tables {
            let excluded = ["Z_PK", "Z_OPT", "Z_ENT", "ZLIFECYCLEDATA"]
                + (origin == "prepared-pre-pr2" ? ["ZPORTIONGROUPINGDATA"] : [])
            let fields = try columns(url, table: table, immutable: immutable).filter { !excluded.contains($0) }.sorted()
            result[table] = [fields] + (try query(url, "SELECT \(fields.joined(separator: ",")) FROM \(table) ORDER BY Z_PK", immutable: immutable))
        }
        return result
    }
    private func attach(_ value: Any, name: String) throws {
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func qualify(_ origin: String) throws {
        let url = try fixture(origin)
        let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        let resource = origin == "prepared-pre-pr2" ? "provenance" : "prepared-pr2-provenance"
        let provenanceURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: resource, withExtension: "json"))
        let provenance = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: provenanceURL)) as? [String: Any])
        XCTAssertEqual(hash, provenance["fixture_sha256"] as? String)
        let oldColumns = try columns(url, immutable: true)
        XCTAssertEqual(oldColumns, provenance["old_prepared_columns"] as? [String])
        XCTAssertFalse(oldColumns.contains("ZLIFECYCLEDATA"))
        XCTAssertEqual(oldColumns.contains("ZPORTIONGROUPINGDATA"), origin == "prepared-pr2")
        let before = try snapshot(url, origin: origin, immutable: true)
        XCTAssertEqual(before.count, 18)
        XCTAssertTrue(before.values.allSatisfy { $0.count > 1 })
        let counts = before.mapValues { $0.count - 1 }
        XCTAssertEqual(counts, provenance["row_counts"] as? [String: Int])
        let metadataBlob = try XCTUnwrap(query(url, "SELECT Z_PLIST FROM Z_METADATA", immutable: true).first?.first)
        let metadataData = try XCTUnwrap(Data(base64Encoded: String(metadataBlob.dropFirst(5))))
        let metadata = try XCTUnwrap(PropertyListSerialization.propertyList(from: metadataData, format: nil) as? [String: Any])
        let hashes = try XCTUnwrap(metadata["NSStoreModelVersionHashes"] as? [String: Data])
        XCTAssertEqual(hashes.count, 18)
        XCTAssertEqual(hashes.mapValues { $0.map { String(format: "%02x", $0) }.joined() },
                       provenance["entity_hashes"] as? [String: String])
        for suffix in ["-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + suffix))
        }
        try attach(["sha256": hash, "columns": oldColumns, "all18": before], name: origin + "-qualified-original")
    }

    func testPrePR2OriginHasNeitherGroupingNorLifecycleColumn() throws { try qualify(origins[0]) }
    func testPR2OriginHasGroupingButNoLifecycleColumn() throws { try qualify(origins[1]) }

    func testBothOriginsUpgradePreservingAll18UserTables() throws {
        for origin in origins {
            try qualify(origin)
            let originalBytes = try Data(contentsOf: fixture(origin))
            let before = try snapshot(fixture(origin), origin: origin, immutable: true)
            let url = try copy(origin)
            var first: [PreparedComponent]?
            for _ in 0..<2 {
                try autoreleasepool {
                    let c = try container(url)
                    XCTAssertEqual(c.schema.entities.count, 18)
                    let components = try SwiftDataPreparedComponentPersistence(container: c).loadComponents()
                    if let first { XCTAssertEqual(components, first) } else { first = components }
                    let expected = origin == "prepared-pre-pr2" ? [14, 13] : [14, 13, 20, 21, 22, 23]
                    XCTAssertEqual(components.map(\.id.uuidString), expected.map { String(format: "10000000-0000-0000-0000-%012d", $0) })
                    if origin == "prepared-pr2" {
                        XCTAssertEqual(components.compactMap { $0.grouping?.massPerPortionDecigrams }, [2_000, 2_000, 333, 334])
                        XCTAssertEqual(components.compactMap { $0.grouping?.source.id.uuidString }, [100, 100, 101, 101].map { String(format: "10000000-0000-0000-0000-%012d", $0) })
                    }
                }
                let info = try query(url, "PRAGMA table_info(ZPREPAREDCOMPONENTRECORD)")
                XCTAssertTrue(info.contains { $0[1] == "value:ZLIFECYCLEDATA" && $0[2] == "value:BLOB" && $0[3] == "value:0" }, "new nullable Data column must exist")
                if try columns(url).contains("ZLIFECYCLEDATA") {
                    XCTAssertEqual(try query(url, "SELECT COUNT(*) FROM ZPREPAREDCOMPONENTRECORD WHERE ZLIFECYCLEDATA IS NOT NULL"), [["value:0"]])
                }
                XCTAssertEqual(try snapshot(url, origin: origin), before, "including pre-existing PR2 grouping blobs")
            }
            XCTAssertEqual(try Data(contentsOf: fixture(origin)), originalBytes)
            try attach(try snapshot(url, origin: origin), name: origin + "-upgraded-all18")
        }
    }

    func testFreshMemoryAndDiskFactoryParity() throws {
        let memory = try KitchenPersistenceFactory.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let disk = try container(directory.appending(path: "fresh.store"))
        XCTAssertEqual(memory.schema.entities.count, 18)
        XCTAssertEqual(Set(memory.schema.entities.map(\.name)), Set(disk.schema.entities.map(\.name)))
        for c in [memory, disk] {
            let entity = try XCTUnwrap(c.schema.entities.first { $0.name == "PreparedComponentRecord" })
            XCTAssertTrue(entity.properties.contains { $0.name == "lifecycleData" })
        }
    }


    private var validLifecycle: PreparedLifecycle {
        PreparedLifecycle(version: 1, thawPhase: .inactive,
            thawStartedAt: Date(timeIntervalSinceReferenceDate: 100),
            thawCompletedAt: Date(timeIntervalSinceReferenceDate: 200),
            cookedAt: Date(timeIntervalSinceReferenceDate: 50))
    }
    private func firstRow(_ context: ModelContext) throws -> PreparedComponentRecord {
        try XCTUnwrap(context.fetch(FetchDescriptor<PreparedComponentRecord>(sortBy: [SortDescriptor(\.sortIndex)])).first)
    }

    func testStrictLeafValidCorruptFutureAndRawEnumContexts() throws {
        let c = try KitchenPersistenceFactory.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(c)
        let row = try PreparedComponentRecord(component: PreparedComponent(name: "叶值", portionsRemaining: 1,
            state: .cooked, storage: .refrigerated, preparedAt: .distantPast, expiryDate: .distantFuture), sortIndex: 0)
        context.insert(row)
        XCTAssertNil(try row.decodeLifecycle())
        row.stateRawValue = "future-state"; row.storageRawValue = "future-storage"
        XCTAssertNil(try row.decodeLifecycle(), "nil lifecycle keeps legacy enum fallback")
        XCTAssertEqual(try row.decodePreparedComponent().state, .cooked)
        XCTAssertEqual(try row.decodePreparedComponent().storage, .refrigerated)
        row.lifecycleData = try JSONEncoder().encode(validLifecycle)
        XCTAssertThrowsError(try row.decodeLifecycle(), "raw strings must be checked before fallbacks")
        for (state, storage) in [("future", "refrigerated"), ("cooked", "future"), ("prepped", "refrigerated"), ("cooked", "frozen")] {
            row.stateRawValue = state; row.storageRawValue = storage
            XCTAssertThrowsError(try row.decodeLifecycle(), "\(state)/\(storage)")
        }
        row.stateRawValue = "cooked"; row.storageRawValue = "refrigerated"
        XCTAssertEqual(try row.decodeLifecycle(), validLifecycle)
        XCTAssertEqual(try row.decodePreparedComponent().lifecycle, validLifecycle)
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(validLifecycle)) as? [String: Any])
        var malformed: [Data] = [Data("broken".utf8), Data("null".utf8), Data("[]".utf8)]
        for key in valid.keys {
            var missing = valid; missing.removeValue(forKey: key)
            malformed.append(try JSONSerialization.data(withJSONObject: missing))
        }
        for (key, value) in [("version", 2 as Any), ("version", "1" as Any),
                             ("thawPhase", "future" as Any), ("unexpected", true as Any),
                             ("thawCompletedAt", 99 as Any)] {
            var bad = valid; bad[key] = value
            malformed.append(try JSONSerialization.data(withJSONObject: bad))
        }
        for data in malformed {
            row.lifecycleData = data
            XCTAssertThrowsError(try row.decodeLifecycle())
            XCTAssertThrowsError(try row.decodePreparedComponent())
            XCTAssertEqual(row.lifecycleData, data)
        }
    }

    func testActiveLifecycleColumnStrictLeafRoundTripAndRepeatOpen() throws {
        for origin in origins {
            let url = try copy(origin)
            let before = try snapshot(fixture(origin), origin: origin, immutable: true)
            let data = try JSONEncoder().encode(validLifecycle)
            try autoreleasepool {
                let c = try container(url); let context = ModelContext(c); context.autosaveEnabled = false
                let row = try firstRow(context)
                row.lifecycleData = data
                XCTAssertEqual(try row.decodeLifecycle(), validLifecycle)
                try context.save()
            }
            for _ in 0..<2 {
                try autoreleasepool {
                    let c = try container(url); let context = ModelContext(c)
                    let row = try firstRow(context)
                    XCTAssertEqual(row.lifecycleData, data)
                    XCTAssertEqual(try row.decodeLifecycle(), validLifecycle)
                    XCTAssertEqual(try row.decodePreparedComponent().lifecycle, validLifecycle)
                    XCTAssertEqual(try SwiftDataPreparedComponentPersistence(container: c).loadComponents().first?.lifecycle, validLifecycle)
                }
                XCTAssertEqual(try snapshot(url, origin: origin), before)
            }
            try attach(["all18": try snapshot(url, origin: origin), "lifecycle": data.base64EncodedString()], name: origin + "-passive-repeat-open")
        }
    }

    func testInvalidProductionReadsAndMutationsRefuseWithoutLosingBytes() throws {
        let valid = try JSONEncoder().encode(validLifecycle)
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        future["version"] = 2
        let cases: [(Data, String, String)] = [
            (Data("broken".utf8), "cooked", "refrigerated"),
            (try JSONSerialization.data(withJSONObject: future), "cooked", "refrigerated"),
            (valid, "future-state", "refrigerated"), (valid, "cooked", "future-storage")
        ]
        for (data, state, storage) in cases {
            let url = directory.appending(path: UUID().uuidString + ".store")
            _ = try copy("prepared-pr2", to: url)
            let before = try snapshot(fixture("prepared-pr2"), origin: "prepared-pr2", immutable: true)
            try autoreleasepool {
                let c = try container(url); let context = ModelContext(c); context.autosaveEnabled = false
                let row = try firstRow(context)
                row.lifecycleData = data
                row.stateRawValue = state; row.storageRawValue = storage
                try context.save()
            }
            let staged = try snapshot(url, origin: "prepared-pr2")
            try autoreleasepool {
                let c = try container(url)
                let p = SwiftDataPreparedComponentPersistence(container: c)
                XCTAssertThrowsError(try p.loadComponents())
                XCTAssertThrowsError(try p.replaceComponents(with: []))
                XCTAssertThrowsError(try p.deleteAll())
                XCTAssertThrowsError(try p.delete(id: UUID(uuidString: "10000000-0000-0000-0000-000000000014")!))
                let new = PreparedComponent(name: "未提交", portionsRemaining: 1, state: .cooked,
                    storage: .refrigerated, preparedAt: .distantPast, expiryDate: .distantFuture)
                XCTAssertThrowsError(try p.upsert(new))
                let row = try firstRow(ModelContext(c))
                XCTAssertEqual(row.lifecycleData, data)
                XCTAssertEqual(row.stateRawValue, state); XCTAssertEqual(row.storageRawValue, storage)
                if state == "cooked" && storage == "refrigerated" && data == valid {
                    XCTAssertEqual(try row.decodeLifecycle(), validLifecycle)
                } else { XCTAssertThrowsError(try row.decodeLifecycle()) }
            }
            XCTAssertEqual(try snapshot(url, origin: "prepared-pr2"), staged)
            XCTAssertEqual(staged.filter { $0.key != "ZPREPAREDCOMPONENTRECORD" },
                           before.filter { $0.key != "ZPREPAREDCOMPONENTRECORD" })
        }
    }

    /// The default is a local round trip. The retained runner selects write/read
    /// in separate XCTest processes to prove the stronger restart boundary.
    func testPassiveLeafProcessProbe() throws {
        let environment = ProcessInfo.processInfo.environment
        let mode = environment["KM_PR3_LEAF_PROBE_MODE"] ?? "roundTrip"
        XCTAssertTrue(["roundTrip", "write", "read"].contains(mode))
        let root: URL
        if mode == "roundTrip" { root = directory.appending(path: "probe") }
        else {
            let name = try XCTUnwrap(environment["KM_PR3_LEAF_PROBE_NAME"])
            XCTAssertFalse(name.contains("/"))
            root = URL.documentsDirectory.appending(path: name)
        }
        let data = try JSONEncoder().encode(validLifecycle)
        if mode != "read" {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for origin in origins {
                let url = try copy(origin, to: root.appending(path: origin + ".store"))
                try autoreleasepool {
                    let c = try container(url); let context = ModelContext(c); context.autosaveEnabled = false
                    try firstRow(context).lifecycleData = data
                    try context.save()
                }
            }
            try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
                "lifecycle": data.base64EncodedString()]).write(to: root.appending(path: "writer.json"))
        }
        if mode != "write" {
            let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "writer.json"))) as? [String: Any])
            let writerPID = try XCTUnwrap(receipt["pid"] as? Int)
            if mode == "read" { XCTAssertNotEqual(writerPID, Int(ProcessInfo.processInfo.processIdentifier)) }
            let expected = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(receipt["lifecycle"] as? String)))
            XCTAssertEqual(try JSONDecoder().decode(PreparedLifecycle.self, from: expected), validLifecycle)
            for origin in origins {
                let url = root.appending(path: origin + ".store")
                for _ in 0..<2 {
                    try autoreleasepool {
                        let c = try container(url); let context = ModelContext(c)
                        let row = try firstRow(context)
                        XCTAssertEqual(row.lifecycleData, expected)
                        XCTAssertEqual(try row.decodeLifecycle(), validLifecycle)
                        XCTAssertEqual(try SwiftDataPreparedComponentPersistence(container: c).loadComponents().first?.lifecycle, validLifecycle)
                    }
                    XCTAssertEqual(try snapshot(url, origin: origin), try snapshot(fixture(origin), origin: origin, immutable: true))
                }
                try attach(["mode": mode, "writerPID": writerPID,
                    "readerPID": Int(ProcessInfo.processInfo.processIdentifier),
                    "all18": try snapshot(url, origin: origin), "lifecycle": expected.base64EncodedString()], name: origin + "-process-probe")
                for suffix in ["", "-wal", "-shm"] {
                    let path = URL(fileURLWithPath: url.path + suffix)
                    if FileManager.default.fileExists(atPath: path.path) {
                        let a = XCTAttachment(data: try Data(contentsOf: path), uniformTypeIdentifier: "public.data")
                        a.name = origin + "-leaf.store" + suffix; a.lifetime = .keepAlways; add(a)
                    }
                }
            }
        }
        print("PR3_LEAF_PROBE=\(root.path) mode=\(mode) pid=\(ProcessInfo.processInfo.processIdentifier)")
    }

    private func unchangedColumns(_ values: [String: [[String]]], target: UUID) throws -> [String: [[String]]] {
        var result = values
        var rows = try XCTUnwrap(result["ZPREPAREDCOMPONENTRECORD"])
        let fields = rows[0]
        let idIndex = try XCTUnwrap(fields.firstIndex(of: "ZID"))
        let stateIndex = try XCTUnwrap(fields.firstIndex(of: "ZSTATERAWVALUE"))
        let storageIndex = try XCTUnwrap(fields.firstIndex(of: "ZSTORAGERAWVALUE"))
        let uuid = target.uuid
        let encodedID = withUnsafeBytes(of: uuid) { "blob:" + Data($0).base64EncodedString() }
        let rowIndex = try XCTUnwrap(rows.indices.dropFirst().first { rows[$0][idIndex] == encodedID })
        rows[rowIndex][stateIndex] = "explicit-transition"
        rows[rowIndex][storageIndex] = "explicit-transition"
        result["ZPREPAREDCOMPONENTRECORD"] = rows
        return result
    }

    /// Ordinary runs use isolated roundtrip mode; the retained runner explicitly
    /// selects write/read in separate native processes for active A06 evidence.
    func testActiveMappedWriteAfterEachGenuineUpgrade() throws {
        let env = ProcessInfo.processInfo.environment
        let mode = env["KM_PR3_ACTIVE_PROBE_MODE"] ?? "roundTrip"
        guard ["write", "read", "roundTrip"].contains(mode) else { return XCTFail("unknown mode") }
        let root: URL
        if mode == "roundTrip" { root = directory.appending(path: "active-probe") }
        else {
            let name = try XCTUnwrap(env["KM_PR3_ACTIVE_PROBE_NAME"])
            XCTAssertFalse(name.contains("/")); root = URL.documentsDirectory.appending(path: name)
        }
        let eventAt = Date(timeIntervalSince1970: 1_800_000_000)
        if mode != "read" {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for origin in origins {
                try qualify(origin)
                let url = try copy(origin, to: root.appending(path: origin + ".store"))
                try autoreleasepool {
                    let c = try container(url); let b = KitchenPersistenceFactory.bundle(container: c)
                    let defaultsName = "pr3-active-upgrade-\(UUID())"
                    let defaults = UserDefaults(suiteName: defaultsName)!
                    defer { defaults.removePersistentDomain(forName: defaultsName) }
                    let s = KitchenStore(userDefaults: defaults, persistence: b,
                        recoverySnapshot: KitchenRecoverySnapshotStore(directoryURL: root.appending(path: origin + "-recovery")))
                    let original = s.preparedComponents
                    let id = UUID(uuidString: origin == "prepared-pre-pr2"
                        ? "10000000-0000-0000-0000-000000000013" : "10000000-0000-0000-0000-000000000020")!
                    var row = try XCTUnwrap(original.first { $0.id == id })
                    let expectedOriginal = row
                    for (n, action) in [PreparedLifecycleAction.beginThaw, .completeThaw, .markCooked].enumerated() {
                        let intent = try PreparedLifecycleBackupFixtures.intent(action, row: row,
                            eventAt: eventAt.addingTimeInterval(Double(n)))
                        row = try s.transitionPreparedComponent(id: id, expected: row, intent: intent).get()
                        XCTAssertEqual(s.preparedComponents.filter { $0.id != id }, original.filter { $0.id != id })
                        XCTAssertEqual(row.id, expectedOriginal.id); XCTAssertEqual(row.grouping, expectedOriginal.grouping)
                        XCTAssertEqual(row.portionsRemaining, expectedOriginal.portionsRemaining)
                        XCTAssertEqual(row.preparedAt, expectedOriginal.preparedAt)
                        XCTAssertEqual(row.expiryDate, expectedOriginal.expiryDate, "overdue date is never silently extended")
                    }
                    let expected = try JSONEncoder().encode(s.preparedComponents)
                    try expected.write(to: root.appending(path: origin + "-expected.json"))
                }
            }
            try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier])
                .write(to: root.appending(path: "writer.json"))
        }
        if mode != "write" {
            let writer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "writer.json"))) as? [String: Int])
            let pid = try XCTUnwrap(writer["pid"])
            if mode == "read" { XCTAssertNotEqual(pid, Int(ProcessInfo.processInfo.processIdentifier)) }
            for origin in origins {
                let target = UUID(uuidString: origin == "prepared-pre-pr2"
                    ? "10000000-0000-0000-0000-000000000013" : "10000000-0000-0000-0000-000000000020")!
                let expected = try JSONDecoder().decode([PreparedComponent].self,
                    from: Data(contentsOf: root.appending(path: origin + "-expected.json")))
                let url = root.appending(path: origin + ".store")
                for _ in 0..<2 {
                    try autoreleasepool {
                        let b = KitchenPersistenceFactory.bundle(container: try container(url))
                        XCTAssertEqual(try b.preparedComponents.loadComponents(), expected)
                        let selected = try XCTUnwrap(expected.first { $0.id == target })
                        XCTAssertEqual(selected.lifecycle?.thawStartedAt, eventAt)
                        XCTAssertEqual(selected.lifecycle?.thawCompletedAt, eventAt.addingTimeInterval(1))
                        XCTAssertEqual(selected.lifecycle?.cookedAt, eventAt.addingTimeInterval(2))
                        XCTAssertEqual(selected.state, .cooked); XCTAssertEqual(selected.storage, .refrigerated)
                    }
                    XCTAssertEqual(try unchangedColumns(snapshot(url, origin: origin), target: target),
                        try unchangedColumns(snapshot(fixture(origin), origin: origin, immutable: true), target: target),
                        "every original user field in all18 tables survives except selected explicit state/storage")
                }
                try attach(["mode": mode, "writerPID": pid, "readerPID": Int(ProcessInfo.processInfo.processIdentifier),
                    "all18": try snapshot(url, origin: origin)], name: origin + "-active-upgrade")
                for suffix in ["", "-wal", "-shm"] {
                    let file = URL(fileURLWithPath: url.path + suffix)
                    if FileManager.default.fileExists(atPath: file.path) {
                        let a = XCTAttachment(data: try Data(contentsOf: file), uniformTypeIdentifier: "public.data")
                        a.name = origin + "-active.store" + suffix; a.lifetime = .keepAlways; add(a)
                    }
                }
            }
        }
        print("PR3_ACTIVE_PROBE=\(root.path) mode=\(mode) pid=\(ProcessInfo.processInfo.processIdentifier)")
    }
}
