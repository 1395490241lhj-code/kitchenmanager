import XCTest
import Supabase
import UIKit
@testable import KitchenManager

@MainActor
final class ProviderSessionIOSStorageTests: XCTestCase {
    func testIsolatedSimulatorKeychainPreservesExistingEncodingAcrossColdAdapterAndLogout() async throws {
        let service = "com.lianghongjing.kitchenmanager.auth.tests.\(UUID())"
        XCTAssertTrue(service.hasPrefix("com.lianghongjing.kitchenmanager.auth.tests."))
        let key = "kitchenmanager.auth.session"
        let storage = KeychainLocalStorage(service: service)
        defer { try? storage.remove(key: key); try? storage.remove(key: key + "-code-verifier") }
        let session = providerSession(user: UUID(), credential: "isolated-keychain", now: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)), lifetime: 3600)
        let encoded = try JSONEncoder().encode(session)
        try storage.store(key: key, value: encoded)
        let transport = ProviderSessionTransport()
        func adapter() -> ProviderSessionCoordinator {
            ProviderSessionCoordinator(url: ProviderSessionTransport.url, storageKey: key,
                storage: storage, fetch: { try await transport.fetch($0) },
                notifications: NotificationCenter(), automaticRefresh: false)
        }
        let first = adapter()
        let restored = try await first.perform(.restore)
        XCTAssertEqual(restored.session, session)
        XCTAssertEqual(try storage.retrieve(key: key), encoded)
        let reopened = adapter()
        let cold = try await reopened.perform(.restore)
        XCTAssertEqual(cold.session, session)
        XCTAssertNotEqual(cold.context, restored.context, "a new process/adapter does not inherit cleanup authority")
        await transport.enqueue(ProviderSessionTransport.logoutRoute)
        _ = try await reopened.perform(.signOut, expectedContext: cold.context)
        XCTAssertThrowsError(try storage.retrieve(key: key)) { error in
            XCTAssertTrue(storage.isMissingItemError(error), "the SDK preserves item-not-found after deletion")
        }
        let guest = try await adapter().perform(.restore)
        XCTAssertNil(guest.session)
        let unexpected = await transport.unexpectedCount
        XCTAssertEqual(unexpected, 0)
    }

    func testExpiredKeychainRestoreRefreshFailureAndSubsequentLogin() async throws {
        let key = "kitchenmanager.auth.session"
        let storage = KeychainLocalStorage(service: "com.lianghongjing.kitchenmanager.auth.tests.\(UUID())")
        defer { try? storage.remove(key: key); try? storage.remove(key: key + "-code-verifier") }
        let user = UUID()
        let expired = providerSession(user: user, credential: "expired-keychain", now: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)), lifetime: -10)
        try storage.store(key: key, value: JSONEncoder().encode(expired))
        let transport = ProviderSessionTransport()
        let fresh = providerSession(user: user, credential: "refreshed-keychain", now: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        await transport.enqueue(ProviderSessionTransport.refreshRoute, data: try providerResponse(fresh))
        let coordinator = ProviderSessionCoordinator(url: ProviderSessionTransport.url, storageKey: key,
            storage: storage, fetch: { try await transport.fetch($0) },
            notifications: NotificationCenter(), automaticRefresh: false)
        let restored = try await coordinator.perform(.restore)
        XCTAssertEqual(restored.session, fresh)
        XCTAssertEqual(try storage.retrieve(key: key).map { try JSONDecoder().decode(Session.self, from: $0) }, fresh)
        await transport.enqueue(ProviderSessionTransport.refreshRoute,
            data: providerError("refresh_token_not_found"), status: 403)
        do { _ = try await coordinator.perform(.refresh, expectedContext: restored.context); XCTFail("expected invalidation") }
        catch { }
        XCTAssertThrowsError(try storage.retrieve(key: key)) { error in
            XCTAssertTrue(storage.isMissingItemError(error), "the SDK preserves item-not-found after deletion")
        }
        let replacement = providerSession(user: UUID(), credential: "new-keychain", now: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        await transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(replacement))
        let result = try await coordinator.perform(.signIn, email: "fixture@example.invalid", password: "synthetic-only")
        XCTAssertEqual(result.session, replacement)
        XCTAssertEqual(try storage.retrieve(key: key).map { try JSONDecoder().decode(Session.self, from: $0) }, replacement)
        let unexpected = await transport.unexpectedCount
        XCTAssertEqual(unexpected, 0)
    }

    func testUIKitNotificationBridgeRefreshesAndCancelsOwnedTimerThenAllowsLogin() async throws {
        let center = NotificationCenter()
        let clock = ProviderSessionClock()
        let ledger = ProviderSessionLedger()
        let storage = ProviderSessionMemoryStorage(ledger)
        let transport = ProviderSessionTransport()
        let sleeper = LifecycleSleeper()
        let a = UUID()
        let initial = providerSession(user: a, credential: "lifecycle-initial", now: clock.now(), lifetime: 90)
        try storage.seed(initial)
        let coordinator = ProviderSessionCoordinator(url: ProviderSessionTransport.url,
            storageKey: ProviderSessionMemoryStorage.key, storage: storage,
            fetch: { try await transport.fetch($0) }, notifications: center,
            initiallyActive: false, now: { clock.now() }, sleep: { interval in
                XCTAssertEqual(interval, 30)
                try await sleeper.wait()
            })
        let consumer = ProviderSessionConsumer(ledger: ledger)
        coordinator.setConsumer { await consumer.consume($0) }
        let restored = try await coordinator.perform(.restore)
        try await coordinator.refreshIfNeeded()
        let none = await transport.trace
        XCTAssertTrue(none.isEmpty)
        let fresh = providerSession(user: a, credential: "lifecycle-foreground", now: clock.now())
        await transport.enqueue(ProviderSessionTransport.refreshRoute, data: try providerResponse(fresh))
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await sleeper.waitForSleep(1)
        XCTAssertEqual(try storage.storedSession(), fresh)
        XCTAssertEqual(coordinator.context, restored.context)
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        await sleeper.waitForCancellation(1)
        clock.advance(by: 3600)
        try await coordinator.refreshIfNeeded()
        let inactive = await transport.trace
        XCTAssertEqual(inactive.count, 1)
        await transport.enqueue(ProviderSessionTransport.refreshRoute, data: providerError("session_expired"), status: 403)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await sleeper.waitForSleep(2)
        XCTAssertNil(storage.bytes)
        let b = providerSession(user: UUID(), credential: "lifecycle-B", now: clock.now())
        await transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(b))
        let signed = try await coordinator.perform(.signIn, email: "fixture@example.invalid", password: "synthetic-only")
        XCTAssertEqual(signed.session, b)
        XCTAssertEqual(try storage.storedSession(), b)
        XCTAssertNotEqual(signed.context, restored.context)
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        await sleeper.waitForCancellation(2)
        XCTAssertEqual(ledger.outsideWrites, 0)
        let unexpected = await transport.unexpectedCount
        XCTAssertEqual(unexpected, 0)
    }
}

private actor LifecycleSleeper {
    private var sleeps = 0
    private var cancellations = 0
    private var sleepers: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelled: Set<UUID> = []
    private var observers: [(Bool, Int, CheckedContinuation<Void, Never>)] = []
    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                sleeps += 1
                if cancelled.remove(id) != nil || Task.isCancelled { c.resume(throwing: CancellationError()) }
                else { sleepers[id] = c }
                signal()
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        cancellations += 1
        if let c = sleepers.removeValue(forKey: id) { c.resume(throwing: CancellationError()) }
        else { cancelled.insert(id) }
        signal()
    }
    func waitForSleep(_ count: Int) async { await observe(false, count) }
    func waitForCancellation(_ count: Int) async { await observe(true, count) }
    private func observe(_ cancellation: Bool, _ count: Int) async {
        if (cancellation ? cancellations : sleeps) >= count { return }
        await withCheckedContinuation { observers.append((cancellation, count, $0)) }
    }
    private func signal() {
        let ready = observers.filter { ($0.0 ? cancellations : sleeps) >= $0.1 }
        observers.removeAll { ($0.0 ? cancellations : sleeps) >= $0.1 }
        ready.forEach { $0.2.resume() }
    }
}
