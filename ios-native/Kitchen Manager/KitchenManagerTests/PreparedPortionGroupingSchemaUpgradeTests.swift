import XCTest
import SwiftData
import SQLite3
@testable import KitchenManager

@MainActor
final class PreparedPortionGroupingSchemaUpgradeTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "prepared-pr2-upgrade-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "prepared-pre-pr2", withExtension: "store"))
    }
    private func copyFixture() throws -> URL {
        let url = directory.appending(path: "kitchen.store")
        try FileManager.default.copyItem(at: fixture(), to: url)
        return url
    }
    private func container(_ url: URL) throws -> ModelContainer {
        try KitchenPersistenceFactory.makeContainer(configuration: ModelConfiguration(url: url))
    }
    private func query(_ url: URL, _ sql: String) throws -> [[String]] {
        var db: OpaquePointer?
        let resource = url.lastPathComponent == "prepared-pre-pr2.store"
        let location = resource ? url.absoluteString + "?immutable=1" : url.path
        XCTAssertEqual(sqlite3_open_v2(location, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "fixture-sql", code: 1)
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { n in
                if sqlite3_column_type(statement, n) == SQLITE_NULL { return "NULL" }
                if sqlite3_column_type(statement, n) == SQLITE_BLOB {
                    let count = Int(sqlite3_column_bytes(statement, n))
                    return Data(bytes: sqlite3_column_blob(statement, n)!, count: count).base64EncodedString()
                }
                return String(cString: sqlite3_column_text(statement, n))
            })
        }
        return rows
    }
    private func snapshot(_ url: URL) throws -> [String: [[String]]] {
        let tables = try query(url, "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Z%' ORDER BY name")
            .map { $0[0] }.filter { !["Z_METADATA", "Z_MODELCACHE", "Z_PRIMARYKEY"].contains($0) }
        var result: [String: [[String]]] = [:]
        for table in tables {
            let columns = try query(url, "PRAGMA table_info(\(table))").map { $0[1] }
                .filter { !["Z_PK", "Z_OPT", "Z_ENT", "ZPORTIONGROUPINGDATA"].contains($0) }
            result[table] = try query(url, "SELECT \(columns.joined(separator: ",")) FROM \(table) ORDER BY Z_PK")
        }
        return result
    }

    private func preserveUpgradeEvidence(_ url: URL) throws {
        let snapshot = try JSONSerialization.data(withJSONObject: snapshot(url), options: [.sortedKeys])
        let receipt = XCTAttachment(data: snapshot, uniformTypeIdentifier: "public.json")
        receipt.name = "upgraded-user-columns.json"; receipt.lifetime = .keepAlways; add(receipt)
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) {
                let attachment = XCTAttachment(data: try Data(contentsOf: file), uniformTypeIdentifier: "public.data")
                attachment.name = "upgraded-legacy.store" + suffix
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    func testUpgradedOldStoreAcceptsGroupedWritesAndPreservesUnrelatedDataOnRestart() throws {
        let before = try snapshot(fixture()).filter { $0.key != "ZPREPAREDCOMPONENTRECORD" }
        let url = try copyFixture()
        let source = try PreparedSourceSnapshot(id: UUID(), name: "新鸡肉", initialMassDecigrams: 8_000, initialPortionCount: 4)
        let added = PreparedComponent(name: "新鸡肉", portionsRemaining: 4, state: .prepped, storage: .frozen,
            preparedAt: Date(timeIntervalSince1970: 100), expiryDate: Date(timeIntervalSince1970: 200),
            grouping: try PreparedPortionGrouping(source: source, massPerPortionDecigrams: 2_000))
        var expected: [PreparedComponent] = []
        try autoreleasepool {
            let p = SwiftDataPreparedComponentPersistence(container: try container(url))
            let legacy = try p.loadComponents()
            XCTAssertTrue(legacy.allSatisfy { $0.grouping == nil })
            expected = legacy + [added]
            try p.replaceComponents(with: expected)
        }
        for _ in 0..<2 {
            try autoreleasepool {
                let p = SwiftDataPreparedComponentPersistence(container: try container(url))
                XCTAssertEqual(try p.loadComponents(), expected)
            }
            XCTAssertEqual(try snapshot(url).filter { $0.key != "ZPREPAREDCOMPONENTRECORD" }, before)
        }
        try preserveUpgradeEvidence(url)
    }

    func testGenuineOldStoreUpgradesAndPreservesEverySeededEntityAcrossRepeatOpen() throws {
        let original = try fixture()
        XCTAssertFalse(try query(original, "PRAGMA table_info(ZPREPAREDCOMPONENTRECORD)").contains { $0[1] == "ZPORTIONGROUPINGDATA" })
        let before = try snapshot(original)
        XCTAssertEqual(before.count, 18)
        XCTAssertTrue(before.values.allSatisfy { !$0.isEmpty })
        let url = try copyFixture()
        for _ in 0..<2 {
            try autoreleasepool {
                let c = try container(url)
                XCTAssertEqual(c.schema.entities.count, 18)
                let components = try SwiftDataPreparedComponentPersistence(container: c).loadComponents()
                XCTAssertEqual(components.map(\.id.uuidString), ["10000000-0000-0000-0000-000000000014", "10000000-0000-0000-0000-000000000013"])
                XCTAssertEqual(components.map(\.portionsRemaining), [4, 3])
            }
            XCTAssertTrue(try query(url, "PRAGMA table_info(ZPREPAREDCOMPONENTRECORD)").contains { $0[1] == "ZPORTIONGROUPINGDATA" }, "the additive PR2 column must exist after opening the real old store")
            XCTAssertEqual(try snapshot(url), before, "all 18 populated tables retain user columns/UUIDs/payloads")
        }
        try preserveUpgradeEvidence(url)
    }
}
