import XCTest
import Supabase
import CryptoKit
@testable import KitchenManager

@MainActor
final class ProviderKeychainContractProbeTests: XCTestCase {
    func testPinnedKeychainAbsenceAndCoordinatorRestoreContract() async throws {
        let service = "com.lianghongjing.kitchenmanager.auth.tests.probe.\(UUID())"
        let key = "kitchenmanager.auth.session"
        let storage = KeychainLocalStorage(service: service)
        var phases: [String] = []
        var publication: [String] = []
        var unexpectedRequests = 0
        defer {
            try? storage.remove(key: key)
            try? storage.remove(key: key + "-code-verifier")
            let evidence: [String: Any] = ["scope": "unique test-only Keychain service", "phases": phases,
                "publication": publication, "unexpectedRequests": unexpectedRequests]
            let data = try! JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(string: String(decoding: data, as: UTF8.self))
            attachment.name = "isolated-keychain-contract-phases"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let instant = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let expected = providerSession(user: UUID(), credential: "isolated-probe", now: instant)
        let encoded = try JSONEncoder().encode(expected)
        do { try storage.store(key: key, value: encoded); phases.append("seed-store:success") }
        catch { phases.append("seed-store:error:\(String(describing: error))"); XCTFail("isolated seed store failed"); return }
        do {
            let bytes = try storage.retrieve(key: key)
            XCTAssertEqual(bytes, encoded)
            phases.append("seed-read:present:\(bytes?.count ?? 0)-bytes")
        } catch { phases.append("seed-read:error:\(String(describing: error))"); XCTFail("isolated readback failed"); return }
        do {
            let absent = try storage.retrieve(key: "supabase.session")
            XCTAssertNil(absent); phases.append("legacy-absence:nil")
        } catch { phases.append("legacy-absence:error:\(String(describing: error))") }
        let coordinator = ProviderSessionCoordinator(url: ProviderSessionTransport.url, storageKey: key,
            storage: storage, fetch: { _ in throw ProviderSessionFixtureError.unexpectedRequest },
            notifications: NotificationCenter(), automaticRefresh: false)
        coordinator.setConsumer { snapshot in
            switch snapshot.phase {
            case .transition: publication.append("transition")
            case .settled: publication.append(snapshot.session == expected ? "settled:expected-session" : "settled:other")
            case .unavailable: publication.append("unavailable")
            }
        }
        do {
            let result = try await coordinator.perform(.restore)
            XCTAssertEqual(result.session, expected)
            phases.append("coordinator-restore:success")
        } catch {
            phases.append("coordinator-restore:error:\(String(describing: error))")
            XCTFail("healthy seeded Keychain session must restore; inspect phase attachment")
        }
        do {
            let bytes = try storage.retrieve(key: key)
            XCTAssertEqual(bytes, encoded)
            phases.append("final-bytes:\(bytes.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "absent")")
        } catch { phases.append("final-read:error:\(String(describing: error))"); XCTFail("final readback failed") }
        XCTAssertEqual(publication, ["transition", "settled:expected-session"])
        XCTAssertEqual(unexpectedRequests, 0)
    }
}
