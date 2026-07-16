import XCTest
@testable import KitchenManager

/// Phase 2C-2: abstraction-level tests for the crash-reporting/nonfatal
/// layer, independent of `GuestMergeController` (those integration tests
/// live in `GuestMergeTests.swift`, reusing its existing mock transports).
final class CrashReportingTests: XCTestCase {

    // MARK: - Provider selection / fail-safe defaults

    func testDisabledConfigurationYieldsNoOpProvider() {
        let configuration = CrashReportingConfiguration(isEnabled: false, environment: "development", dsn: "https://example.test/dsn", sampleRate: 1)
        let provider = CrashReportingFactory.makeProvider(configuration: configuration)
        XCTAssertTrue(provider is NoOpCrashReporter)
    }

    func testMissingConfigurationDefaultsToDisabledNoOp() {
        // Default init (no arguments) mirrors what `.load()` returns when
        // every Info.plist key is absent/empty — never "enabled" by default.
        let configuration = CrashReportingConfiguration()
        XCTAssertFalse(configuration.isEnabled)
        let provider = CrashReportingFactory.makeProvider(configuration: configuration)
        XCTAssertTrue(provider is NoOpCrashReporter)
    }

    func testEnabledWithoutDSNFailsSafeToNoOpRatherThanCrashing() {
        let configuration = CrashReportingConfiguration(isEnabled: true, environment: "development", dsn: "", sampleRate: 1)
        let provider = CrashReportingFactory.makeProvider(configuration: configuration)
        XCTAssertTrue(provider is NoOpCrashReporter, "enabled-but-incomplete config must never crash or silently pretend to report")
    }

    /// Loads from the test target's own real `Bundle` (not a fake
    /// dictionary) — since the test bundle's Info.plist has none of the
    /// `KM_CRASH_REPORTING_*` keys, this exercises the actual
    /// missing-key/fail-safe path with a real `Bundle`, not just a
    /// hand-constructed struct.
    func testLoadFromRealBundleWithoutConfiguredKeysDefaultsToDisabled() {
        let configuration = CrashReportingConfiguration.load(from: Bundle(for: Self.self))
        XCTAssertFalse(configuration.isEnabled)
    }

    func testSampleRateIsClampedToTheSafeZeroToOneRange() {
        XCTAssertEqual(CrashReportingConfiguration(sampleRate: 150).sampleRate, 1)
        XCTAssertEqual(CrashReportingConfiguration(sampleRate: -5).sampleRate, 0)
        XCTAssertEqual(CrashReportingConfiguration(sampleRate: 0.42).sampleRate, 0.42)
    }

    // MARK: - Metadata allowlist safety

    func testMetadataAllowlistDropsAnyKeyNotOnTheList() {
        let metadata = CrashReportingMetadata([
            "errorCode": "transport",
            "email": "user@example.com",
            "token": "opaque-token",
            "householdId": UUID().uuidString,
            "userId": UUID().uuidString,
            "inventoryName": "鸡蛋",
            "receiptText": "收据内容",
            "body": "{}"
        ])
        XCTAssertEqual(metadata.fields, ["errorCode": "transport"])
    }

    func testMetadataNeverContainsEmailTokenOrFullUUID() {
        let email = "user@example.com"
        let uuid = UUID().uuidString
        let metadata = CrashReportingMetadata(["email": email, "accessToken": "secret", "fullUUID": uuid])
        XCTAssertTrue(metadata.fields.isEmpty)
        XCTAssertFalse(metadata.fields.values.contains(email))
        XCTAssertFalse(metadata.fields.values.contains(uuid))
    }

    func testDictionaryLiteralConstructionAlsoGoesThroughTheAllowlist() {
        let metadata: CrashReportingMetadata = ["errorCode": "rate_limited", "email": "user@example.com"]
        XCTAssertEqual(metadata.fields, ["errorCode": "rate_limited"])
    }

    // MARK: - Bucketing (never exact counts/durations)

    func testCountBucketNeverExposesTheExactUnderlyingCount() {
        XCTAssertEqual(CrashReportingMetadata.countBucket(0), "0")
        XCTAssertEqual(CrashReportingMetadata.countBucket(3), "1-5")
        XCTAssertEqual(CrashReportingMetadata.countBucket(15), "6-20")
        XCTAssertEqual(CrashReportingMetadata.countBucket(50), "21-100")
        XCTAssertEqual(CrashReportingMetadata.countBucket(500), "100+")
        // The bucket for two different exact counts in the same range must
        // be identical — the exact number is never recoverable from it.
        XCTAssertEqual(CrashReportingMetadata.countBucket(7), CrashReportingMetadata.countBucket(19))
    }

    func testDurationBucketNeverExposesRawMillisecondValue() {
        XCTAssertEqual(CrashReportingMetadata.durationBucket(0.1), "lt500ms")
        XCTAssertEqual(CrashReportingMetadata.durationBucket(2), "lt3s")
        XCTAssertEqual(CrashReportingMetadata.durationBucket(20), "gte10s")
    }

    // MARK: - No-op provider safety

    func testNoOpProviderMethodsNeverThrowBlockOrCrash() {
        let provider = NoOpCrashReporter.shared
        provider.configure(environment: "development", release: "1.0.0", build: "1")
        provider.captureFatalContext(["environment": "development"])
        provider.captureNonFatal(SyncError.transport, context: ["errorCode": "transport"])
        provider.addBreadcrumb(.appStarted, metadata: [:])
        provider.setOperationalTag(key: "environment", value: "development")
        provider.flushIfNeeded()
        // Reaching this line at all is the assertion — no crash, no hang.
        XCTAssertTrue(true)
    }

    func testNoOpProviderIsASingleSharedInstance() {
        XCTAssertTrue(NoOpCrashReporter.shared === NoOpCrashReporter.shared)
    }

    // MARK: - Event/error code stability

    func testEveryCrashReportingEventHasAStableCategory() {
        for event in CrashReportingEvent.allCases {
            XCTAssertFalse(event.category.isEmpty, "\(event.rawValue) must map to a non-empty category")
        }
    }

    func testSyncErrorCrashReportingCodeIsStableAndNeverTheLocalizedChineseText() {
        let cases: [SyncError] = [
            .disabled, .notAuthenticated, .invalidConfiguration, .transport, .unauthorized,
            .forbidden, .payloadTooLarge, .conflict, .backendUnavailable, .invalidCursor,
            .decoding, .unsupportedEntity, .persistence,
            .clientUpgradeRequired(minimumVersion: "9.0.0", minimumBuild: 42),
            .clientSchemaUnsupported, .rateLimited(retryAfterSeconds: 5)
        ]
        var seenCodes = Set<String>()
        for error in cases {
            let code = error.crashReportingCode
            XCTAssertFalse(code.isEmpty)
            XCTAssertFalse(code.contains("同步"), "crashReportingCode must never be the localized Chinese message")
            XCTAssertNotEqual(code, error.errorDescription)
            seenCodes.insert(code)
        }
        XCTAssertEqual(seenCodes.count, cases.count, "every case must have its own distinct stable code")
    }
}
