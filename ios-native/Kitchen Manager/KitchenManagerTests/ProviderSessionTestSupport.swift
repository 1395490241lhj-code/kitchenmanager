import Supabase
import Foundation
@testable import KitchenManager

// Synthetic, in-memory fixtures only. Unexpected storage keys and HTTP requests throw.
enum ProviderSessionFixtureError: Error { case unexpectedRequest, unexpectedStorageKey, storage, transport }

final class ProviderSessionLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: UUID?
    private var outside = 0
    private var overlaps = 0
    private var operations: [String] = []
    private var writers: [(key: String, owner: UUID?)] = []

    func begin(_ operationID: UUID) {
        lock.withLock { if owner != nil { overlaps += 1 }; owner = operationID }
    }
    func end() { lock.withLock { owner = nil } }
    func record(_ operation: String, key: String) {
        lock.withLock {
            operations.append("\(operation):\(key)")
            if operation == "store" || operation == "remove" {
                writers.append((key, owner))
                if owner == nil { outside += 1 }
            }
        }
    }
    var outsideWrites: Int { lock.withLock { outside } }
    var overlappingTurns: Int { lock.withLock { overlaps } }
    var trace: [String] { lock.withLock { operations } }
    func writerIDs(for key: String) -> [UUID?] {
        lock.withLock { writers.filter { $0.key == key }.map(\.owner) }
    }
}

final class ProviderSessionMemoryStorage: AuthLocalStorage, @unchecked Sendable {
    static let key = "provider-session-tests.auth.session"
    static let codeVerifierKey = key + "-code-verifier"
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var failures: [String: Int] = [:]
    private var unexpected = 0
    let ledger: ProviderSessionLedger

    init(_ ledger: ProviderSessionLedger) { self.ledger = ledger }
    func seed(_ session: Session?, legacy: Bool = false) throws {
        let data = try session.map { try JSONEncoder().encode($0) }
        lock.withLock { values[legacy ? "supabase.session" : Self.key] = data }
    }
    func seedEncodedFixture(_ data: Data) { lock.withLock { values[Self.key] = data } }
    func failNext(_ operation: String) { lock.withLock { failures[operation, default: 0] += 1 } }
    private func check(_ operation: String, key: String) throws {
        guard key == Self.key || key == "supabase.session" || key == Self.codeVerifierKey else {
            lock.withLock { unexpected += 1 }
            throw ProviderSessionFixtureError.unexpectedStorageKey
        }
        ledger.record(operation, key: key)
        let failed = lock.withLock { () -> Bool in
            guard failures[operation, default: 0] > 0 else { return false }
            failures[operation, default: 0] -= 1
            return true
        }
        if failed { throw ProviderSessionFixtureError.storage }
    }
    func store(key: String, value: Data) throws {
        try check("store", key: key)
        lock.withLock { values[key] = value }
    }
    func retrieve(key: String) throws -> Data? {
        try check("read", key: key)
        return lock.withLock { values[key] }
    }
    func remove(key: String) throws {
        try check("remove", key: key)
        _ = lock.withLock { values.removeValue(forKey: key) }
    }
    var bytes: Data? { lock.withLock { values[Self.key] } }
    var allBytes: [String: Data] { lock.withLock { values } }
    var unexpectedKeyCount: Int { lock.withLock { unexpected } }
    var remainingFailures: Int { lock.withLock { failures.values.reduce(0, +) } }
    // Inspect bytes without calling the SDK session getter, which can itself refresh.
    func storedSession() throws -> Session? {
        try bytes.map { try JSONDecoder().decode(Session.self, from: $0) }
    }
}

actor ProviderSessionGate {
    private var held: Bool
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    init(held: Bool = true) { self.held = held }
    func pass() async {
        arrivals += 1
        let ready = observers.filter { arrivals >= $0.0 }
        observers.removeAll { arrivals >= $0.0 }
        ready.forEach { $0.1.resume() }
        if held { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitForArrival(_ count: Int = 1) async {
        if arrivals >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func open() {
        held = false
        let ready = waiters
        waiters = []
        ready.forEach { $0.resume() }
    }
}

actor ProviderSessionTransport {
    static let url = URL(string: "https://sdk-spike.invalid")!
    static let passwordRoute = "POST /token?grant_type=password"
    static let refreshRoute = "POST /token?grant_type=refresh_token"
    static let logoutRoute = "POST /logout?scope=global"
    struct Response: Sendable {
        let status: Int
        let data: Data
        let hold: ProviderSessionGate?
        let failure: Bool
    }
    private var plans: [String: [Response]] = [:]
    private var requests: [String] = []
    private var unexpected = 0

    func enqueue(_ route: String, data: Data = Data(), status: Int = 200,
                 hold: ProviderSessionGate? = nil, failure: Bool = false) {
        plans[route, default: []].append(Response(status: status, data: data, hold: hold, failure: failure))
    }
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, url.scheme == "https", url.host == "sdk-spike.invalid" else {
            unexpected += 1
            throw ProviderSessionFixtureError.unexpectedRequest
        }
        let route = (request.httpMethod ?? "GET") + " " + url.path + (url.query.map { "?" + $0 } ?? "")
        requests.append(route)
        guard var queue = plans[route], !queue.isEmpty else {
            unexpected += 1
            throw ProviderSessionFixtureError.unexpectedRequest
        }
        let response = queue.removeFirst()
        plans[route] = queue
        if let hold = response.hold { await hold.pass() }
        if response.failure { throw ProviderSessionFixtureError.transport }
        return (response.data, HTTPURLResponse(url: url, statusCode: response.status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01"])!)
    }
    var trace: [String] { requests }
    var unexpectedCount: Int { unexpected }
    var remainingResponses: Int { plans.values.reduce(0) { $0 + $1.count } }
}

final class ProviderSessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init() { value = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }
    func now() -> Date { lock.withLock { value } }
    func advance(by interval: TimeInterval) { lock.withLock { value.addTimeInterval(interval) } }
}

func providerSession(user: UUID, credential: String, now: Date, lifetime: TimeInterval = 3600) -> Session {
    Session(accessToken: "synthetic-access-" + credential, tokenType: "bearer", expiresIn: lifetime,
        expiresAt: now.timeIntervalSince1970 + lifetime, refreshToken: "synthetic-refresh-" + credential,
        user: User(id: user, appMetadata: [:], userMetadata: [:], aud: "authenticated",
                   email: "fixture@example.invalid", createdAt: now, updatedAt: now))
}
func providerResponse(_ session: Session) throws -> Data { try AuthClient.Configuration.jsonEncoder.encode(session) }
func providerError(_ code: String) -> Data { Data("{\"code\":\"\(code)\",\"message\":\"synthetic failure\"}".utf8) }

@MainActor
final class ProviderSessionConsumer {
    private let ledger: ProviderSessionLedger
    private var contexts: [UUID: Int] = [:]
    private(set) var trace: [String] = []
    private(set) var snapshots: [ProviderSessionCoordinator.Snapshot] = []
    private(set) var acknowledgments = 0
    var nextAcknowledgment: ProviderSessionGate?

    init(ledger: ProviderSessionLedger) { self.ledger = ledger }
    func consume(_ snapshot: ProviderSessionCoordinator.Snapshot) async {
        snapshots.append(snapshot)
        switch snapshot.phase {
        case .transition:
            ledger.begin(snapshot.operationID)
            trace.append("transition:" + (snapshot.operation?.rawValue ?? "unknown"))
            return
        case .settled:
            if let session = snapshot.session, let context = snapshot.context {
                if contexts[context] == nil { contexts[context] = contexts.count + 1 }
                trace.append("active:\(contexts[context]!):\(session.user.id.uuidString)")
            } else {
                trace.append("guest")
            }
        case .unavailable:
            trace.append("unavailable")
        }
        let gate = nextAcknowledgment
        nextAcknowledgment = nil
        if let gate { await gate.pass() }
        ledger.end()
        acknowledgments += 1
    }
}

@MainActor
final class ProviderSessionFixture {
    let ledger: ProviderSessionLedger
    let storage: ProviderSessionMemoryStorage
    let transport: ProviderSessionTransport
    let clock: ProviderSessionClock
    let consumer: ProviderSessionConsumer
    let coordinator: ProviderSessionCoordinator

    init(seed: Session? = nil, legacy: Bool = false, initiallyActive: Bool = true,
         automaticRefresh: Bool = false, clock: ProviderSessionClock = ProviderSessionClock(),
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in
             throw ProviderSessionFixtureError.unexpectedRequest
         }) throws {
        let ledger = ProviderSessionLedger()
        let storage = ProviderSessionMemoryStorage(ledger)
        let transport = ProviderSessionTransport()
        let consumer = ProviderSessionConsumer(ledger: ledger)
        try storage.seed(seed, legacy: legacy)
        self.ledger = ledger
        self.storage = storage
        self.transport = transport
        self.clock = clock
        self.consumer = consumer
        coordinator = ProviderSessionCoordinator(url: ProviderSessionTransport.url,
            storageKey: ProviderSessionMemoryStorage.key, storage: storage,
            fetch: { try await transport.fetch($0) }, notifications: NotificationCenter(),
            initiallyActive: initiallyActive, automaticRefresh: automaticRefresh,
            now: { clock.now() }, sleep: sleep)
        coordinator.setConsumer { await consumer.consume($0) }
    }

    func session(_ user: UUID, _ credential: String, lifetime: TimeInterval = 3600) -> Session {
        providerSession(user: user, credential: credential, now: clock.now(), lifetime: lifetime)
    }
    func perform(_ operation: ProviderSessionCoordinator.Operation, expectedContext: UUID? = nil,
                 operationID: UUID = UUID()) async throws -> ProviderSessionCoordinator.Result {
        try await coordinator.perform(operation, email: "fixture@example.invalid", password: "synthetic-only",
                                      expectedContext: expectedContext, operationID: operationID)
    }
    func start(_ operation: ProviderSessionCoordinator.Operation, expectedContext: UUID? = nil,
               operationID: UUID = UUID()) -> Task<ProviderSessionCoordinator.Result, Error> {
        let ticket = coordinator.submit(operation, email: "fixture@example.invalid", password: "synthetic-only",
                                        expectedContext: expectedContext, operationID: operationID)
        return Task { try await ticket.value() }
    }
}

final class ProviderSessionRawTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String] = []
    func append(_ event: AuthChangeEvent, _ session: Session?) {
        lock.withLock { states.append(event.rawValue + ":" + (session?.user.id.uuidString ?? "guest")) }
    }
    var trace: [String] { lock.withLock { states } }
}
