import Foundation
import Supabase
import UIKit

/// The private client has no autonomous refresh or extra initial-session observer.
/// Admission covers its awaited effects AND the consumer's acknowledged reduction.
@MainActor
final class ProviderSessionCoordinator {
    enum Operation: String, Sendable { case bootstrap, restore, signIn, signUp, reauthenticate, refresh, signOut }
    enum Phase: Sendable { case transition, settled, unavailable }
    struct Result: Sendable {
        let session: Session?
        let context: UUID?
        let confirmationEmail: String?
    }
    struct Snapshot: Sendable {
        let phase: Phase
        let session: Session?
        let context: UUID?
        let operation: Operation?
        let operationID: UUID
        let endingContext: UUID?
    }
    private struct Job {
        let operation: Operation
        let email: String
        let password: String
        let expected: UUID?
        let id: UUID
        let ticket: ProviderSessionTicket<Result>
    }
    private let client: AuthClient
    private let storage: ProviderSessionStorage
    private let inbox = ProviderSessionInbox()
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let notifications: NotificationCenter
    private let automaticRefresh: Bool
    private var observers: [NSObjectProtocol] = []
    private var refreshLoop: Task<Void, Never>?
    private var scheduledRefreshID: UUID?
    private var active: Bool
    private var registration: (any AuthStateChangeListenerRegistration)?
    private var callback: (@Sendable (AuthChangeEvent, Session?) -> Void)?
    private var consumer: (@MainActor (Snapshot) async -> Void)?
    private var jobs: [Job] = []
    private var running = false
    private var unavailable = false
    private var committed: Session?
    private(set) var context: UUID?

    init(url: URL, headers: [String: String] = [:], storageKey: String,
         storage: any AuthLocalStorage,
         fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
         notifications: NotificationCenter = .default, initiallyActive: Bool = true,
         automaticRefresh: Bool = true,
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
             try await Task.sleep(for: .seconds($0))
         }) {
        self.storage = ProviderSessionStorage(storage, key: storageKey)
        self.now = now; self.sleep = sleep; self.notifications = notifications
        self.automaticRefresh = automaticRefresh; active = initiallyActive
        client = AuthClient(configuration: .init(url: url, headers: headers,
            storageKey: storageKey, localStorage: self.storage, logger: nil, fetch: fetch,
            autoRefreshToken: false, emitLocalSessionAsInitialSession: false))
        observers = [
            notifications.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setActive(true) }
            },
            notifications.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setActive(false) }
            }
        ]
    }

    deinit {
        refreshLoop?.cancel()
        for observer in observers { notifications.removeObserver(observer) }
    }

    func setConsumer(_ consumer: @escaping @MainActor (Snapshot) async -> Void) {
        precondition(self.consumer == nil)
        self.consumer = consumer
    }

    func perform(_ operation: Operation, email: String = "", password: String = "",
                 expectedContext: UUID? = nil, operationID: UUID = UUID()) async throws -> Result {
        try await submit(operation, email: email, password: password,
                         expectedContext: expectedContext, operationID: operationID).value()
    }

    func submit(_ operation: Operation, email: String = "", password: String = "",
                expectedContext: UUID? = nil, operationID: UUID = UUID()) -> ProviderSessionTicket<Result> {
        let ticket = ProviderSessionTicket<Result>()
        jobs.append(Job(operation: operation, email: email, password: password,
                        expected: expectedContext, id: operationID, ticket: ticket))
        if !running { running = true; Task { await self.pump() } }
        return ticket
    }

    private func pump() async {
        while !jobs.isEmpty {
            if inbox.hasUnknown { await receiveUnknown() }
            let job = jobs.removeFirst()
            defer { if scheduledRefreshID == job.id { scheduledRefreshID = nil } }
            if job.ticket.isCancelled { job.ticket.resolve(.failure(CancellationError())); continue }
            if [.signOut, .reauthenticate, .refresh].contains(job.operation),
               unavailable || job.expected != context {
                job.ticket.resolve(.failure(AuthenticationError.unavailable)); continue
            }
            if unavailable && [.bootstrap, .restore].contains(job.operation) {
                job.ticket.resolve(.failure(AuthenticationError.unavailable)); continue
            }
            let result = await execute(job)
            job.ticket.resolve(result)
        }
        running = false
        startRefreshLoopIfNeeded()
    }

    private func execute(_ job: Job) async -> Swift.Result<Result, Error> {
        let prior = committed; let priorContext = context; let wasUnavailable = unavailable
        let fresh = [.signIn, .signUp, .reauthenticate].contains(job.operation)
        let start = inbox.begin()
        storage.begin(expectingSession: prior == nil ? nil : true, mayReadVerifier: job.operation == .signUp)
        defer { inbox.end(); storage.end() }
        await consumer?(Snapshot(phase: .transition, session: nil,
            context: fresh ? nil : priorContext, operation: job.operation, operationID: job.id,
            endingContext: job.operation == .signOut ? priorContext : nil))
        var returned: Session?
        var confirmationEmail: String?
        var sdkError: Error?
        do {
            if registration == nil {
                let inbox = self.inbox
                let callback: @Sendable (AuthChangeEvent, Session?) -> Void = { [weak self] event, session in
                    if inbox.append(event, session) { Task { @MainActor in await self?.receiveUnknown() } }
                }
                self.callback = callback
                registration = await client.onAuthStateChange(callback)
            }
            switch job.operation {
            case .bootstrap: break
            case .restore:
                do { returned = try await client.session }
                catch let error as AuthError where error.errorCode == .sessionNotFound { returned = nil }
            case .signIn, .reauthenticate:
                returned = try await client.signIn(email: job.email, password: job.password)
            case .signUp:
                let response = try await client.signUp(email: job.email, password: job.password)
                returned = response.session
                if returned == nil { confirmationEmail = response.user.email ?? job.email }
            case .refresh: returned = try await client.refreshSession()
            case .signOut: try await client.signOut() // Existing global logout scope.
            }
        } catch { sdkError = error }
        var actual: Session?
        var verificationFailed = false
        var readSucceeded = false
        do { actual = try storage.readSession(); readSucceeded = true } catch { verificationFailed = true }
        if storage.hasFaults { verificationFailed = true }
        if let returned, returned != actual { verificationFailed = true }
        if job.operation == .signOut, sdkError == nil, actual != nil { verificationFailed = true }
        if [.bootstrap, .restore].contains(job.operation), actual?.isExpired == true { verificationFailed = true }
        if job.operation == .bootstrap {
            if inbox.snapshot(from: start).events.last(where: { $0.0 == .initialSession })?.1 != actual { verificationFailed = true }
        }
        if job.operation == .signUp, sdkError == nil, returned == nil, actual != prior { verificationFailed = true }
        if sdkError != nil, actual != prior, actual != nil { verificationFailed = true }
        if wasUnavailable && !(fresh && returned != nil && sdkError == nil) { verificationFailed = true }
        if inbox.hasUnknown { verificationFailed = true }
        // A failed remove with verified unchanged bytes retains this operation's
        // context so local deletion cleanup can retry without reauthenticating a deleted account.
        if job.operation == .signOut, readSucceeded, actual != nil, actual == prior,
           priorContext != nil, storage.hasOnlyFailedSessionRemovals, !inbox.hasUnknown {
            verificationFailed = false
            sdkError = AuthenticationError.unavailable
        }
        let next: UUID? = actual == nil ? nil : (fresh && returned != nil && sdkError == nil ? UUID() : priorContext ?? UUID())
        let snapshot = inbox.snapshot(from: start)
        if verificationFailed {
            unavailable = true; context = nil; committed = nil
            await consumer?(Snapshot(phase: .unavailable, session: nil, context: nil,
                operation: job.operation, operationID: job.id, endingContext: nil))
        } else {
            await consumer?(Snapshot(phase: .settled, session: actual, context: next,
                operation: job.operation, operationID: job.id,
                endingContext: job.operation == .signOut && actual == nil ? priorContext : nil))
            unavailable = false; context = next; committed = actual
        }
        inbox.acknowledge(snapshot.tail)
        if inbox.hasUnknown { await receiveUnknown(); verificationFailed = true }
        if verificationFailed { return .failure(AuthenticationError.unavailable) }
        if let sdkError { return .failure(sdkError) }
        return .success(Result(session: actual, context: next, confirmationEmail: confirmationEmail))
    }

    private func receiveUnknown() async {
        guard inbox.takeUnknown() else { return }
        unavailable = true; context = nil; committed = nil
        await consumer?(Snapshot(phase: .unavailable, session: nil, context: nil,
            operation: nil, operationID: UUID(), endingContext: nil))
    }

    func setActive(_ active: Bool) {
        self.active = active
        if !active { refreshLoop?.cancel(); refreshLoop = nil }
        else { startRefreshLoopIfNeeded() }
    }

    private func startRefreshLoopIfNeeded() {
        guard automaticRefresh, active, registration != nil, refreshLoop == nil else { return }
        let sleep = self.sleep
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await self?.refreshIfNeeded() } catch { /* Settled failures retry on the next existing-policy tick. */ }
                do { try await sleep(30) } catch { return }
            }
        }
    }

    func refreshIfNeeded() async throws {
        guard active, !unavailable, scheduledRefreshID == nil, let committed, let context,
              Int((committed.expiresAt - now().timeIntervalSince1970) / 30) <= 3 else { return }
        let id = UUID(); scheduledRefreshID = id
        _ = try await perform(.refresh, expectedContext: context, operationID: id)
    }

    #if DEBUG
    func injectUnknownEventForTesting() async {
        precondition(!running && callback != nil)
        callback?(.signedOut, nil)
        await receiveUnknown()
    }
    #endif
}

nonisolated protocol ProviderSessionStorageErrorClassifying {
    func isMissingItemError(_ error: Error) -> Bool
}

extension KeychainLocalStorage: ProviderSessionStorageErrorClassifying {
    nonisolated func isMissingItemError(_ error: Error) -> Bool {
        // shortcut: 2.51.0 hides its status; revalidate this fail-closed identity/text match before an SDK or toolchain change.
        String(reflecting: type(of: error)) == "Auth.KeychainError" &&
            (error as NSError).domain == "Auth.KeychainError" &&
            error.localizedDescription == "errSecItemNotFound: The item cannot be found."
    }
}

nonisolated private final class ProviderSessionStorage: AuthLocalStorage, @unchecked Sendable {
    private enum Access { case read, store, remove }
    private struct Fault { let access: Access; let key: String }
    private let wrapped: any AuthLocalStorage
    private let classifier: (any ProviderSessionStorageErrorClassifying)?
    private let key: String
    private let lock = NSLock()
    private var faults: [Fault] = []
    private var expectedSession: Bool?
    private var mayReadVerifier = false
    private var copiedLegacySession = false
    private var readLegacySession = false
    private var admitted = false

    init(_ wrapped: any AuthLocalStorage, key: String) {
        self.wrapped = wrapped; self.key = key
        classifier = wrapped as? any ProviderSessionStorageErrorClassifying
    }
    func begin(expectingSession: Bool?, mayReadVerifier: Bool) {
        lock.withLock {
            precondition(!admitted)
            admitted = true; faults = []; expectedSession = expectingSession
            self.mayReadVerifier = mayReadVerifier
            copiedLegacySession = false; readLegacySession = false
        }
    }
    func end() { lock.withLock { admitted = false } }
    var hasFaults: Bool { lock.withLock { !faults.isEmpty } }
    var hasOnlyFailedSessionRemovals: Bool {
        lock.withLock { !faults.isEmpty && faults.allSatisfy { $0.access == .remove && $0.key == key } }
    }
    private func permitsAbsence(_ access: Access, _ requestedKey: String) -> Bool {
        guard admitted, access != .store else { return false }
        if requestedKey == key { return expectedSession != true }
        if requestedKey == "supabase.session" { return access == .read || copiedLegacySession }
        return requestedKey == key + "-code-verifier" && mayReadVerifier && access == .read
    }
    private func missing(_ access: Access, _ requestedKey: String) {
        if !permitsAbsence(access, requestedKey) {
            faults.append(Fault(access: access, key: requestedKey))
        } else if requestedKey == key { expectedSession = false }
    }
    private func failed(_ access: Access, _ requestedKey: String, _ error: Error) {
        let isMissing = classifier?.isMissingItemError(error) == true
        lock.withLock {
            if isMissing { missing(access, requestedKey) }
            else { faults.append(Fault(access: access, key: requestedKey)) }
        }
    }
    func store(key: String, value: Data) throws {
        do { try wrapped.store(key: key, value: value) }
        catch { failed(.store, key, error); throw error }
        lock.withLock {
            if key == self.key {
                expectedSession = true
                if readLegacySession { copiedLegacySession = true }
            }
        }
    }
    func retrieve(key: String) throws -> Data? {
        let value: Data?
        do { value = try wrapped.retrieve(key: key) }
        catch { failed(.read, key, error); throw error }
        lock.withLock {
            if value == nil { missing(.read, key) }
            else if key == self.key {
                if expectedSession == false { faults.append(Fault(access: .read, key: key)) }
                expectedSession = true
            } else if key == "supabase.session" { readLegacySession = true }
        }
        return value
    }
    func remove(key: String) throws {
        do { try wrapped.remove(key: key) }
        catch { failed(.remove, key, error); throw error }
        lock.withLock { if key == self.key { expectedSession = false } }
    }
    func readSession() throws -> Session? {
        do { return try retrieve(key: key).map { try JSONDecoder().decode(Session.self, from: $0) } }
        catch {
            // Verification may observe a known absent session;
            // the SDK-facing retrieve above still throws its original error.
            if classifier?.isMissingItemError(error) == true,
               lock.withLock({ permitsAbsence(.read, key) }) { return nil }
            throw error
        }
    }
}

nonisolated private final class ProviderSessionInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var unknown = false
    private var events: [(AuthChangeEvent, Session?)] = []
    private var offset = 0
    var hasUnknown: Bool { lock.withLock { unknown } }
    func takeUnknown() -> Bool { lock.withLock { defer { unknown = false }; return unknown } }
    func begin() -> Int { lock.withLock { precondition(!active); active = true; return offset + events.count } }
    func end() { lock.withLock { active = false } }
    func append(_ event: AuthChangeEvent, _ session: Session?) -> Bool {
        lock.withLock { events.append((event, session)); if !active { unknown = true }; return !active }
    }
    func snapshot(from index: Int) -> (events: [(AuthChangeEvent, Session?)], tail: Int) {
        lock.withLock { (Array(events.dropFirst(max(0, index - offset))), offset + events.count) }
    }
    func acknowledge(_ tail: Int) {
        lock.withLock { let count = min(events.count, max(0, tail - offset)); events.removeFirst(count); offset += count }
    }
}

nonisolated final class ProviderSessionTicket<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Swift.Result<Value, Error>?
    private var waiter: CheckedContinuation<Value, Error>?
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func resolve(_ value: Swift.Result<Value, Error>) {
        let waiter = lock.withLock { () -> CheckedContinuation<Value, Error>? in
            guard result == nil else { return nil }; result = value
            defer { self.waiter = nil }; return self.waiter
        }
        waiter?.resume(with: value)
    }
    func value() async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter in
                let saved = lock.withLock { () -> Swift.Result<Value, Error>? in
                    if let result { return result }; self.waiter = waiter; return nil
                }
                if let saved { waiter.resume(with: saved) }
            }
        } onCancel: {
            self.lock.withLock { self.cancelled = true }
            self.resolve(.failure(CancellationError()))
        }
    }
}
