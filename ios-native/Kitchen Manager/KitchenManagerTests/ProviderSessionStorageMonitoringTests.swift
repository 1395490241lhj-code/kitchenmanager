import XCTest
import Supabase
import Security
@testable import KitchenManager

@MainActor
final class ProviderSessionStorageMonitoringTests: XCTestCase {
    func testRealKeychainCleanGuestAndExpectedMissingAfterSuccessfulSignOut() async throws {
        let storage = KeychainLocalStorage(service: "com.lianghongjing.kitchenmanager.auth.tests.monitor.\(UUID())")
        let key = "kitchenmanager.auth.session"
        defer { try? storage.remove(key: key) }
        let transport = ProviderSessionTransport()
        let coordinator = ProviderSessionCoordinator(url: ProviderSessionTransport.url, storageKey: key,
            storage: storage, fetch: { try await transport.fetch($0) },
            notifications: NotificationCenter(), automaticRefresh: false)
        var phases: [ProviderSessionCoordinator.Phase] = []
        coordinator.setConsumer { phases.append($0.phase) }
        let guest = try await coordinator.perform(.bootstrap)
        XCTAssertNil(guest.session)
        let instant = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let session = providerSession(user: UUID(), credential: "monitor-real", now: instant)
        await transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(session))
        let signed = try await coordinator.perform(.signIn, email: "fixture@example.invalid", password: "synthetic-only")
        XCTAssertEqual(signed.session, session)
        XCTAssertEqual(try storage.retrieve(key: key).map { try JSONDecoder().decode(Session.self, from: $0) }, session)
        await transport.enqueue(ProviderSessionTransport.logoutRoute)
        let ended = try await coordinator.perform(.signOut, expectedContext: signed.context)
        XCTAssertNil(ended.session)
        XCTAssertThrowsError(try storage.retrieve(key: key)) { error in
            XCTAssertTrue(storage.isMissingItemError(error), "raw SDK error is preserved")
        }
        let restored = try await coordinator.perform(.restore)
        XCTAssertNil(restored.session)
        XCTAssertEqual(phases, [.transition, .settled, .transition, .settled, .transition, .settled, .transition, .settled])
    }

    func testMissingClassifierRejectsForgedNSErrorMetadata() throws {
        let storage = KeychainLocalStorage(service: "com.lianghongjing.kitchenmanager.auth.tests.classifier.\(UUID())")
        do { _ = try storage.retrieve(key: "supabase.session"); XCTFail("expected SDK missing-item error") }
        catch {
            XCTAssertTrue(storage.isMissingItemError(error))
            let forged = NSError(domain: (error as NSError).domain, code: (error as NSError).code,
                userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
            XCTAssertFalse(storage.isMissingItemError(forged), "matching text/domain without the SDK error identity is not evidence of absence")
            XCTAssertFalse(storage.isMissingItemError(NSError(domain: NSOSStatusErrorDomain, code: Int(errSecAuthFailed))))
            XCTAssertFalse(storage.isMissingItemError(NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed))))
        }
    }

    func testActiveSessionDisappearanceIsNotARegularGuestRestore() async throws {
        let f = try ProviderSessionFixture()
        _ = try await f.perform(.bootstrap)
        let a = f.session(UUID(), "missing-active")
        await f.transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(a))
        let signed = try await f.perform(.signIn)
        try f.storage.seed(nil)
        do { _ = try await f.perform(.restore); XCTFail("lost active session must fail closed") } catch { }
        XCTAssertNil(f.coordinator.context)
        XCTAssertEqual(f.consumer.trace.last, "unavailable")
        XCTAssertNil(f.storage.bytes)
        let b = f.session(a.user.id, "fresh-after-loss")
        await f.transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(b))
        let replacement = try await f.perform(.signIn)
        XCTAssertNotEqual(replacement.context, signed.context)
        XCTAssertEqual(try f.storage.storedSession(), b)
    }

    func testAccessDenialOnOptionalLegacyReadIsAGenuineFault() async throws {
        let f = try fixture()
        _ = try await f.coordinator.perform(.bootstrap)
        let a = providerSession(user: UUID(), credential: "denied-legacy", now: f.clock.now())
        await f.transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(a))
        let signed = try await f.coordinator.perform(.signIn, email: "fixture@example.invalid", password: "synthetic-only")
        f.storage.deniedReadKey = "supabase.session"
        do { _ = try await f.coordinator.perform(.restore); XCTFail("legacy access denial is not expected absence") } catch { }
        XCTAssertEqual(try f.raw.storedSession(), a)
        XCTAssertNil(f.coordinator.context)
        XCTAssertEqual(f.consumer.trace.last, "unavailable")
        let b = providerSession(user: a.user.id, credential: "denied-retry", now: f.clock.now())
        await f.transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(b))
        let replacement = try await f.coordinator.perform(.signIn, email: "fixture@example.invalid", password: "synthetic-only")
        XCTAssertNotEqual(replacement.context, signed.context)
        XCTAssertEqual(try f.raw.storedSession(), b)
    }

    func testReadFaultPlusFailedRemoveCannotUseVerifiedUnchangedRecovery() async throws {
        let f = try fixture()
        _ = try await f.coordinator.perform(.bootstrap)
        let a = providerSession(user: UUID(), credential: "mixed-faults", now: f.clock.now())
        await f.transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(a))
        let signed = try await f.coordinator.perform(.signIn, email: "fixture@example.invalid", password: "synthetic-only")
        f.storage.deniedReadKey = "supabase.session"
        f.raw.failNext("remove")
        await f.transport.enqueue(ProviderSessionTransport.logoutRoute)
        do { _ = try await f.coordinator.perform(.signOut, expectedContext: signed.context); XCTFail("mixed faults are not remove-only recovery") } catch { }
        XCTAssertEqual(try f.raw.storedSession(), a)
        XCTAssertNil(f.coordinator.context)
        XCTAssertEqual(f.consumer.trace.last, "unavailable")
    }

    func testInconsistentSuccessfulWriteFailsWholeSessionVerification() async throws {
        let f = try fixture()
        _ = try await f.coordinator.perform(.bootstrap)
        let expected = providerSession(user: UUID(), credential: "expected", now: f.clock.now())
        let actual = providerSession(user: expected.user.id, credential: "unexpected-contents", now: f.clock.now())
        f.storage.corruptNextSessionWrite = try JSONEncoder().encode(actual)
        await f.transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(expected))
        do { _ = try await f.coordinator.perform(.signIn, email: "fixture@example.invalid", password: "synthetic-only"); XCTFail("returned and stored sessions differ") } catch { }
        XCTAssertEqual(try f.raw.storedSession(), actual)
        XCTAssertNil(f.coordinator.context)
        XCTAssertEqual(f.consumer.trace.last, "unavailable")
    }

    private func fixture() throws -> (raw: ProviderSessionMemoryStorage, storage: MonitoringFaultStorage,
        transport: ProviderSessionTransport, coordinator: ProviderSessionCoordinator, consumer: ProviderSessionConsumer, clock: ProviderSessionClock) {
        let ledger = ProviderSessionLedger()
        let raw = ProviderSessionMemoryStorage(ledger)
        let storage = MonitoringFaultStorage(raw)
        let transport = ProviderSessionTransport()
        let coordinator = ProviderSessionCoordinator(url: ProviderSessionTransport.url,
            storageKey: ProviderSessionMemoryStorage.key, storage: storage,
            fetch: { try await transport.fetch($0) }, notifications: NotificationCenter(), automaticRefresh: false)
        let consumer = ProviderSessionConsumer(ledger: ledger)
        coordinator.setConsumer { await consumer.consume($0) }
        return (raw, storage, transport, coordinator, consumer, ProviderSessionClock())
    }
}

private final class MonitoringFaultStorage: AuthLocalStorage, @unchecked Sendable {
    private let wrapped: ProviderSessionMemoryStorage
    var deniedReadKey: String?
    var corruptNextSessionWrite: Data?
    init(_ wrapped: ProviderSessionMemoryStorage) { self.wrapped = wrapped }
    func retrieve(key: String) throws -> Data? {
        if deniedReadKey == key {
            deniedReadKey = nil
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecAuthFailed))
        }
        return try wrapped.retrieve(key: key)
    }
    func store(key: String, value: Data) throws {
        if key == ProviderSessionMemoryStorage.key, let corrupt = corruptNextSessionWrite {
            corruptNextSessionWrite = nil
            try wrapped.store(key: key, value: corrupt)
        } else { try wrapped.store(key: key, value: value) }
    }
    func remove(key: String) throws { try wrapped.remove(key: key) }
}
