import XCTest
import SwiftData
@testable import KitchenManager

@MainActor
final class PreparedLifecycleBackupTests: XCTestCase {
    private let f = PreparedLifecycleBackupFixtures.self
    private var directory: URL!
    private var suite: String!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "pr3-backup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "pr3-backup-\(UUID())"
    }
    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }
    private func store() throws -> KitchenStore {
        let c = try KitchenPersistenceFactory.makeContainer(configuration: ModelConfiguration(url: directory.appending(path: "kitchen.store")))
        return KitchenStore(userDefaults: UserDefaults(suiteName: suite)!, persistence: KitchenPersistenceFactory.bundle(container: c),
            recoverySnapshot: KitchenRecoverySnapshotStore(directoryURL: directory.appending(path: "recovery")))
    }
    private func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func rows() throws -> [PreparedComponent] {
        let source = try PreparedSourceSnapshot(id: UUID(), name: "鸡肉", initialMassDecigrams: 8000, initialPortionCount: 4)
        let grouping = try PreparedPortionGrouping(source: source, massPerPortionDecigrams: 2000)
        var a = f.row(storage: .refrigerated, count: 2); a.grouping = grouping; a.lifecycle = f.thaw
        var b = a; b.id = UUID(); b.portionsRemaining = 1; b.state = .cooked; b.lifecycle = f.cooked
        var c = a; c.id = UUID(); c.portionsRemaining = 1; c.lifecycle = PreparedLifecycle(version: 1,
            thawPhase: .inactive, thawStartedAt: f.at, thawCompletedAt: f.at, cookedAt: nil)
        return [f.row(), a, b, c]
    }
    private func raw(version: Int, prepared: Any?) throws -> Data {
        var root: [String: Any] = ["format": "kitchen-manager-native-backup", "version": version,
            "inventory": [], "plans": [], "shoppingItems": [], "consumptionRecords": []]
        root["preparedComponents"] = prepared
        return try data(root)
    }
    private func assertRefusedBeforeEffects(_ input: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let s = try store(); let before = try s.exportBackupData()
        XCTAssertThrowsError(try KitchenBackupValidator.validateCandidate(input), file: file, line: line)
        XCTAssertThrowsError(try s.restoreBackupData(input), file: file, line: line)
        XCTAssertEqual(s.lastRestoreOutcome, .validationFailed, file: file, line: line)
        XCTAssertFalse(s.recoverySnapshot.hasOutstandingSnapshot, file: file, line: line)
        XCTAssertTrue(try KitchenBackupValidator.validate(s.exportBackupData()).matchesBackupScope(of: KitchenBackupValidator.validate(before)), file: file, line: line)
    }
    func testOriginalVersionShapeCheckedBeforeCanonicalPreview() throws {
        let row = try f.originalRow(f.row(storage: .refrigerated), version: 2)
        for version in [1, 2, 3] {
            for domain in [nil, NSNull(), "wrong", [:], 7] as [Any?] {
                let bytes = try raw(version: version, prepared: domain)
                if version == 1 && (domain == nil || domain is NSNull) {
                    XCTAssertNoThrow(try KitchenBackupValidator.validateCandidate(bytes))
                } else { try assertRefusedBeforeEffects(bytes) }
            }
            XCTAssertNoThrow(try KitchenBackupValidator.validateCandidate(raw(version: version, prepared: [])))
            for lifecycle in [nil, NSNull(), try object(JSONEncoder().encode(f.thaw)), "wrong", [:]] as [Any?] {
                var value = row; value["lifecycle"] = lifecycle
                let allowed = version == 3 ? (lifecycle is NSNull || (lifecycle as? [String: Any])?["thawPhase"] as? String == "thawing") : lifecycle == nil
                if allowed { XCTAssertNoThrow(try KitchenBackupValidator.validateCandidate(raw(version: version, prepared: [value]))) }
                else { try assertRefusedBeforeEffects(raw(version: version, prepared: [value])) }
            }
            try assertRefusedBeforeEffects(raw(version: version, prepared: [NSNull()]))
        }
        var good = row; good["storage"] = "refrigerated"; good["lifecycle"] = try object(JSONEncoder().encode(f.thaw))
        XCTAssertNoThrow(try KitchenBackupValidator.validateCandidate(raw(version: 3, prepared: [good])))
        var incomplete = good; incomplete["id"] = UUID().uuidString; incomplete.removeValue(forKey: "lifecycle")
        try assertRefusedBeforeEffects(raw(version: 3, prepared: [good, incomplete]))
        for mutation in ["version", "thawPhase", "thawStartedAt", "thawCompletedAt", "cookedAt"] {
            var leaf = try object(JSONEncoder().encode(f.thaw)); leaf.removeValue(forKey: mutation)
            var bad = good; bad["lifecycle"] = leaf
            try assertRefusedBeforeEffects(raw(version: 3, prepared: [bad]))
        }
        for version in [0, 4, -1, true, "3", NSNull(), 2.5] as [Any] {
            var root = try object(raw(version: 3, prepared: [])); root["version"] = version
            try assertRefusedBeforeEffects(data(root))
        }
        var missing = try object(raw(version: 3, prepared: [])); missing.removeValue(forKey: "version")
        try assertRefusedBeforeEffects(data(missing))
    }
    func testExplicitNullExportAndMixedLifecycleRoundTrip() throws {
        let original = f.fullPayload(try rows()); let s = try store()
        try s.restoreBackupData(KitchenBackupValidator.encodeV3(original))
        let bytes = try s.exportBackupData(); let root = try object(bytes)
        XCTAssertEqual(root["version"] as? Int, 3)
        let encoded = try XCTUnwrap(root["preparedComponents"] as? [[String: Any]])
        XCTAssertEqual(encoded.count, 4); XCTAssertTrue(encoded[0]["lifecycle"] is NSNull)
        for row in encoded.dropFirst() {
            let leaf = try XCTUnwrap(row["lifecycle"] as? [String: Any])
            XCTAssertEqual(Set(leaf.keys), ["version", "thawPhase", "thawStartedAt", "thawCompletedAt", "cookedAt"])
        }
        let candidate = try KitchenBackupValidator.validateCandidate(bytes)
        XCTAssertTrue(candidate.payload.matchesBackupScope(of: original))
        XCTAssertTrue(s.clearAllLocalData())
        try s.restoreBackupData(KitchenBackupValidator.encodeV3(candidate.payload))
        XCTAssertEqual(try store().preparedComponents, original.preparedComponents)
    }
    func testHistoricalCandidatesNormalizeOnlyAfterValidation() throws {
        for version in [1, 2] {
            let original = f.payload([f.row()])
            for dated in [true, false] {
                let bytes = try f.historical(original, version: version, dated: dated)
                let c = try KitchenBackupValidator.validateCandidate(bytes)
                XCTAssertEqual(c.version, version); XCTAssertEqual(c.payload.version, 3)
                XCTAssertEqual(c.exportedAt, dated ? original.exportedAt : nil)
                let confirmed = try KitchenBackupValidator.encodeV3(c.payload)
                XCTAssertEqual(try object(confirmed)["version"] as? Int, 3)
                let direct = try store(); try direct.restoreBackupData(bytes)
                XCTAssertEqual(direct.preparedComponents, original.preparedComponents)
                try direct.restoreBackupData(confirmed)
                XCTAssertEqual(try store().preparedComponents, original.preparedComponents)
                let rows = try XCTUnwrap(object(confirmed)["preparedComponents"] as? [[String: Any]])
                XCTAssertTrue(rows.allSatisfy { $0["lifecycle"] is NSNull })
            }
        }
        var relabeled = try object(JSONEncoder().encode(f.payload([f.row()])))
        relabeled["version"] = 2
        try assertRefusedBeforeEffects(data(relabeled))
    }
    func testOldRecoveryExportCreatesV3WithoutChangingOriginalBytes() throws {
        for version in [1, 2, 3] {
            let copy = KitchenRecoverySnapshotStore(directoryURL: directory.appending(path: "copy-\(version)"))
            let payload = f.payload(version == 3 ? try rows() : [f.row()])
            let original = try version == 3 ? KitchenBackupValidator.encodeV3(payload) : f.historical(payload, version: version, dated: false)
            try copy.prepare(original)
            let read = try XCTUnwrap(copy.outstandingSnapshot())
            let candidate = try KitchenBackupValidator.validateCandidate(read)
            let exported = try KitchenBackupValidator.encodeV3(candidate.payload)
            XCTAssertEqual(try object(exported)["version"] as? Int, 3)
            XCTAssertTrue(try KitchenBackupValidator.validate(exported).matchesBackupScope(of: payload))
            XCTAssertEqual(try copy.outstandingSnapshot(), original); XCTAssertTrue(copy.hasOutstandingSnapshot)
            XCTAssertThrowsError(try copy.prepare(exported))
            XCTAssertEqual(try copy.outstandingSnapshot(), original)
        }
    }
    func testFrozenPR2ReaderRejectsV3BeforePayloadDecode() throws {
        let bytes = try raw(version: 3, prepared: "deliberately undecodable")
        XCTAssertThrowsError(try FrozenPR2BackupValidator.validate(bytes)) { error in
            guard case KitchenBackupError.unsupportedVersion(3) = error else { return XCTFail("root gate did not reject first: \(error)") }
        }
        for version in [1, 2] { XCTAssertNoThrow(try FrozenPR2BackupValidator.validate(f.historical(f.payload([f.row()]), version: version))) }
    }

    func testV3MalformedLeafAndFailedRecoveryExportPreserveOriginalBytes() throws {
        let row = try f.originalRow(f.row(storage: .refrigerated), version: 2)
        let leaf = try object(JSONEncoder().encode(f.thaw))
        for (key, value) in [("version", 2 as Any), ("version", true as Any),
            ("thawPhase", "future" as Any), ("unknown", true as Any),
            ("thawStartedAt", "bad" as Any), ("cookedAt", 200 as Any)] {
            var malformed = leaf; malformed[key] = value
            var bad = row; bad["lifecycle"] = malformed
            try assertRefusedBeforeEffects(raw(version: 3, prepared: [bad]))
        }
        let copy = KitchenRecoverySnapshotStore(directoryURL: directory.appending(path: "bad-copy"))
        try copy.prepare(KitchenBackupValidator.encodeV3(f.payload()))
        let malformed = try raw(version: 3, prepared: [row])
        try malformed.write(to: XCTUnwrap(copy.snapshotURL), options: .atomic)
        let original = try XCTUnwrap(copy.outstandingSnapshot())
        XCTAssertThrowsError(try KitchenBackupValidator.encodeV3(KitchenBackupValidator.validateCandidate(original).payload))
        XCTAssertEqual(try copy.outstandingSnapshot(), original); XCTAssertTrue(copy.hasOutstandingSnapshot)
    }
    private enum Fault: Error { case injected }
    private final class SpecialFault: SpecialPlanPersistenceProtocol {
        let wrapped: SpecialPlanPersistenceProtocol
        var failNext = false
        init(_ wrapped: SpecialPlanPersistenceProtocol) { self.wrapped = wrapped }
        func loadPlans() throws -> [SpecialPlan] { try wrapped.loadPlans() }
        func replacePlans(with plans: [SpecialPlan]) throws {
            if failNext { failNext = false; throw Fault.injected }
            try wrapped.replacePlans(with: plans)
        }
        func upsert(_ plan: SpecialPlan) throws { try wrapped.upsert(plan) }
        func delete(id: UUID) throws { try wrapped.delete(id: id) }
        func deleteAll() throws { try wrapped.deleteAll() }
    }
    private func probeBundle(_ url: URL) throws -> KitchenPersistenceBundle {
        KitchenPersistenceFactory.bundle(container: try KitchenPersistenceFactory.makeContainer(configuration: ModelConfiguration(url: url)))
    }
    private func probeStore(_ b: KitchenPersistenceBundle, copy: KitchenRecoverySnapshotStore,
                            special: SpecialPlanPersistenceProtocol? = nil) -> KitchenStore {
        KitchenStore(userDefaults: UserDefaults(suiteName: suite)!, inventoryPersistence: b.inventory,
            shoppingListPersistence: b.shoppingList, todayPlanPersistence: b.todayPlan,
            consumptionPersistence: b.consumption, weeklyPlanPersistence: b.weeklyPlan,
            preparedComponentPersistence: b.preparedComponents, specialPlanPersistence: special ?? b.specialPlans,
            recoverySnapshot: copy)
    }
    func testRecoveryAndHistoricalCopiesAcrossProcessProbe() throws {
        let env = ProcessInfo.processInfo.environment
        let mode = env["KM_PR3_BACKUP_PROBE_MODE"] ?? "roundTrip"
        guard ["roundTrip", "write", "read"].contains(mode) else { return XCTFail("unknown probe mode") }
        let root: URL
        if mode == "roundTrip" { root = directory.appending(path: "backup-probe") }
        else {
            let name = try XCTUnwrap(env["KM_PR3_BACKUP_PROBE_NAME"])
            XCTAssertFalse(name.contains("/")); root = URL.documentsDirectory.appending(path: name)
        }
        if mode != "read" {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try autoreleasepool {
                let b = try probeBundle(root.appending(path: "kitchen.store"))
                let copy = KitchenRecoverySnapshotStore(directoryURL: root.appending(path: "recovery"))
                let special = SpecialFault(b.specialPlans)
                let s = probeStore(b, copy: copy, special: special)
                let original = f.fullPayload(try rows())
                try s.restoreBackupData(KitchenBackupValidator.encodeV3(original))
                try KitchenBackupValidator.encodeV3(original).write(to: root.appending(path: "expected.json"))
                let p = try XCTUnwrap(b.preparedComponents as? SwiftDataPreparedComponentPersistence)
                defer { p.afterReplaceSaveForTesting = nil; p.failNextReplaceSaveForTesting = nil }
                p.afterReplaceSaveForTesting = { p.failNextReplaceSaveForTesting = Fault.injected }
                special.failNext = true
                let oldInput = try f.historical(f.payload([f.row()]), version: 2)
                XCTAssertThrowsError(try s.restoreBackupData(oldInput))
                XCTAssertEqual(s.lastRestoreOutcome, .failedUnsafe(.compensationFailed([.preparedComponents])))
                XCTAssertTrue(s.isPreparedComponentUnavailable)
                let originalBytes = try XCTUnwrap(copy.outstandingSnapshot())
                XCTAssertTrue(try KitchenBackupValidator.validate(originalBytes).matchesBackupScope(of: original))
                XCTAssertEqual(try KitchenBackupValidator.validateCandidate(originalBytes).version, 3)
                try originalBytes.write(to: root.appending(path: "recovery-original.json"))
            }
            for version in [1, 2, 3] {
                let payload = f.fullPayload(version == 3 ? try rows() : [f.row()])
                let bytes = try version == 3 ? KitchenBackupValidator.encodeV3(payload) : f.historical(payload, version: version, dated: false)
                let copy = KitchenRecoverySnapshotStore(directoryURL: root.appending(path: "copy-\(version)"))
                try copy.prepare(bytes)
                try bytes.write(to: root.appending(path: "v\(version)-original.json"))
                try KitchenBackupValidator.encodeV3(payload).write(to: root.appending(path: "v\(version)-expected.json"))
            }
            try data(["pid": Int(ProcessInfo.processInfo.processIdentifier)]).write(to: root.appending(path: "writer.json"))
        }
        if mode != "write" {
            let writerPID = try XCTUnwrap(object(Data(contentsOf: root.appending(path: "writer.json")))["pid"] as? Int)
            if mode == "read" { XCTAssertNotEqual(writerPID, Int(ProcessInfo.processInfo.processIdentifier)) }
            let expected = try KitchenBackupValidator.validate(Data(contentsOf: root.appending(path: "expected.json")))
            try autoreleasepool {
                let b = try probeBundle(root.appending(path: "kitchen.store"))
                let copy = KitchenRecoverySnapshotStore(directoryURL: root.appending(path: "recovery"))
                let saved = try Data(contentsOf: root.appending(path: "recovery-original.json"))
                XCTAssertEqual(try copy.outstandingSnapshot(), saved)
                let s = probeStore(b, copy: copy)
                XCTAssertThrowsError(try s.restoreBackupData(KitchenBackupValidator.encodeV3(expected)))
                XCTAssertEqual(try copy.outstandingSnapshot(), saved)
                try s.restoreFromRecoverySnapshot()
                XCTAssertTrue(try KitchenBackupValidator.validate(s.exportBackupData()).matchesBackupScope(of: expected))
                XCTAssertFalse(copy.hasOutstandingSnapshot)
            }
            for _ in 0..<2 {
                let b = try probeBundle(root.appending(path: "kitchen.store"))
                let s = probeStore(b, copy: KitchenRecoverySnapshotStore(directoryURL: root.appending(path: "recovery")))
                XCTAssertTrue(try KitchenBackupValidator.validate(s.exportBackupData()).matchesBackupScope(of: expected))
            }
            for version in [1, 2, 3] {
                let copy = KitchenRecoverySnapshotStore(directoryURL: root.appending(path: "copy-\(version)"))
                let saved = try Data(contentsOf: root.appending(path: "v\(version)-original.json"))
                XCTAssertEqual(try copy.outstandingSnapshot(), saved)
                let candidate = try KitchenBackupValidator.validateCandidate(saved)
                XCTAssertEqual(candidate.version, version)
                let converted = try KitchenBackupValidator.encodeV3(candidate.payload)
                try converted.write(to: root.appending(path: "v\(version)-separate-export.json"))
                XCTAssertEqual(try copy.outstandingSnapshot(), saved)
                let url = root.appending(path: "historical-\(version).store")
                let s = probeStore(try probeBundle(url), copy: copy)
                try s.restoreFromRecoverySnapshot()
                let wanted = try KitchenBackupValidator.validate(Data(contentsOf: root.appending(path: "v\(version)-expected.json")))
                for _ in 0..<2 {
                    let reread = probeStore(try probeBundle(url), copy: copy)
                    XCTAssertTrue(try KitchenBackupValidator.validate(reread.exportBackupData()).matchesBackupScope(of: wanted))
                }
                XCTAssertFalse(copy.hasOutstandingSnapshot)
            }
            try attachProcessIdentity(root, writer: writerPID)
        }
        print("PR3_BACKUP_PROBE=\(root.path) mode=\(mode) pid=\(ProcessInfo.processInfo.processIdentifier)")
    }
    private func attachProcessIdentity(_ root: URL, writer: Int) throws {
        let a = XCTAttachment(data: try data(["writerPID": writer,
            "readerPID": Int(ProcessInfo.processInfo.processIdentifier), "root": root.path]), uniformTypeIdentifier: "public.json")
        a.name = "backup-recovery-process-identity"; a.lifetime = .keepAlways; add(a)
    }
}
