import XCTest
@testable import KitchenManager

final class SharedImportRequestTests: XCTestCase {

    // MARK: - URL attachment

    func test_urlAttachment_producesSharedURLSource() {
        let result = SharedImportRequestBuilder.build(
            attachmentURL: URL(string: "https://www.xiaohongshu.com/explore/abc123"),
            attachmentText: nil,
            originalHostBundleIdentifier: "com.xingin.discover"
        )
        guard case .success(let request) = result else { return XCTFail("expected success") }
        XCTAssertEqual(request.source, .sharedURL)
        XCTAssertEqual(request.url?.absoluteString, "https://www.xiaohongshu.com/explore/abc123")
        XCTAssertNil(request.text)
        XCTAssertEqual(request.originalHostBundleIdentifier, "com.xingin.discover")
        XCTAssertEqual(request.schemaVersion, SharedImportRequest.currentSchemaVersion)
    }

    // MARK: - URL provided as a String-typed attachment (simulated by passing a URL built from a string)

    func test_urlStringAttachment_isNormalizedTheSameWay() {
        let urlFromString = URL(string: "https://youtu.be/dQw4w9WgXcQ")
        let result = SharedImportRequestBuilder.build(
            attachmentURL: urlFromString,
            attachmentText: nil,
            originalHostBundleIdentifier: nil
        )
        guard case .success(let request) = result else { return XCTFail("expected success") }
        XCTAssertEqual(request.source, .sharedURL)
        XCTAssertEqual(request.url?.host, "youtu.be")
    }

    // MARK: - Plain text, no URL — Phase 1 rejects this outright (Phase 2 scope)

    func test_plainText_noURL_isRejected_notQueued() {
        let result = SharedImportRequestBuilder.build(
            attachmentURL: nil,
            attachmentText: "  番茄炒蛋做法：鸡蛋打散，番茄切块……  ",
            originalHostBundleIdentifier: nil
        )
        guard case .failure(let error) = result else { return XCTFail("expected failure — Phase 1 requires a URL") }
        XCTAssertEqual(error, .unsupportedContent)
        XCTAssertEqual(error.localizedDescription, "暂时只支持包含网页链接的分享内容。")
    }

    // MARK: - Text with an embedded URL

    func test_textWithEmbeddedURL_extractsURLAndKeepsText() {
        let result = SharedImportRequestBuilder.build(
            attachmentURL: nil,
            attachmentText: "这个菜谱不错 https://www.xiaohongshu.com/explore/xyz 分享给你",
            originalHostBundleIdentifier: nil
        )
        guard case .success(let request) = result else { return XCTFail("expected success") }
        XCTAssertEqual(request.source, .sharedTextAndURL)
        XCTAssertEqual(request.url?.absoluteString, "https://www.xiaohongshu.com/explore/xyz")
        XCTAssertEqual(request.text, "这个菜谱不错 https://www.xiaohongshu.com/explore/xyz 分享给你")
    }

    // MARK: - Separate text and URL attachments combined

    func test_textAndURLBothPresent_combinesIntoSharedTextAndURL() {
        let result = SharedImportRequestBuilder.build(
            attachmentURL: URL(string: "https://example.com/recipe"),
            attachmentText: "看这个",
            originalHostBundleIdentifier: nil
        )
        guard case .success(let request) = result else { return XCTFail("expected success") }
        XCTAssertEqual(request.source, .sharedTextAndURL)
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/recipe")
        XCTAssertEqual(request.text, "看这个")
    }

    // MARK: - URL attachment takes priority even when text duplicates the URL

    func test_urlAttachment_withTextEqualToURL_doesNotDuplicateAsCombinedSource() {
        let result = SharedImportRequestBuilder.build(
            attachmentURL: URL(string: "https://example.com/recipe"),
            attachmentText: "https://example.com/recipe",
            originalHostBundleIdentifier: nil
        )
        guard case .success(let request) = result else { return XCTFail("expected success") }
        XCTAssertEqual(request.source, .sharedURL)
        XCTAssertNil(request.text)
    }

    // MARK: - Unsupported scheme

    func test_fileURL_isRejectedAsUnsupported() {
        let result = SharedImportRequestBuilder.build(
            attachmentURL: URL(string: "file:///private/var/tmp/x.jpg"),
            attachmentText: nil,
            originalHostBundleIdentifier: nil
        )
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .unsupportedContent)
    }

    func test_customScheme_isRejectedAndDoesNotLeakIntoText() {
        let result = SharedImportRequestBuilder.build(
            attachmentURL: URL(string: "myapp://open?id=1"),
            attachmentText: nil,
            originalHostBundleIdentifier: nil
        )
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .unsupportedContent)
    }

    func test_unsupportedURL_withFallbackTextButNoLink_isRejected_notQueued() {
        let result = SharedImportRequestBuilder.build(
            attachmentURL: URL(string: "file:///private/var/tmp/x.jpg"),
            attachmentText: "备用文字说明，不含链接",
            originalHostBundleIdentifier: nil
        )
        guard case .failure(let error) = result else { return XCTFail("expected failure — no usable URL anywhere") }
        XCTAssertEqual(error, .unsupportedContent)
    }

    func test_unsupportedURLAttachment_withEmbeddedURLInFallbackText_stillSucceeds() {
        // The URL *attachment* itself is unsupported (file://), but the
        // fallback text contains a usable http(s) link — Phase 1 still
        // accepts that, since it resolves to a real URL either way.
        let result = SharedImportRequestBuilder.build(
            attachmentURL: URL(string: "file:///private/var/tmp/x.jpg"),
            attachmentText: "看这个 https://example.com/recipe",
            originalHostBundleIdentifier: nil
        )
        guard case .success(let request) = result else { return XCTFail("expected success") }
        XCTAssertEqual(request.source, .sharedTextAndURL)
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/recipe")
    }

    // MARK: - Blank content

    func test_blankTextOnly_isRejected() {
        let result = SharedImportRequestBuilder.build(
            attachmentURL: nil,
            attachmentText: "   \n\t  ",
            originalHostBundleIdentifier: nil
        )
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .emptyContent)
    }

    func test_noAttachmentsAtAll_isRejected() {
        let result = SharedImportRequestBuilder.build(
            attachmentURL: nil,
            attachmentText: nil,
            originalHostBundleIdentifier: nil
        )
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .emptyContent)
    }

    // MARK: - Normalization

    func test_normalize_rejectsHostlessURL() {
        XCTAssertNil(SharedImportRequestBuilder.normalize(url: URL(string: "https:///no-host")))
    }

    func test_normalize_acceptsHTTPAndHTTPS() {
        XCTAssertNotNil(SharedImportRequestBuilder.normalize(url: URL(string: "http://example.com")))
        XCTAssertNotNil(SharedImportRequestBuilder.normalize(url: URL(string: "https://example.com")))
    }

    // MARK: - Text truncation

    func test_veryLongText_isTruncatedToMaxLength() {
        // Phase 1 requires a URL somewhere in the content, so the filler
        // text is paired with an embedded link (truncation still applies
        // to the stored `text`, independent of the already-parsed `url`).
        let filler = String(repeating: "字", count: SharedImportRequestBuilder.maxTextLength + 500)
        let longText = "https://example.com/recipe " + filler
        let result = SharedImportRequestBuilder.build(
            attachmentURL: nil,
            attachmentText: longText,
            originalHostBundleIdentifier: nil
        )
        guard case .success(let request) = result else { return XCTFail("expected success") }
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/recipe")
        XCTAssertEqual(request.text?.count, SharedImportRequestBuilder.maxTextLength)
    }

    func test_veryLongPlainText_withNoURLAnywhere_isStillRejected() {
        let longText = String(repeating: "字", count: SharedImportRequestBuilder.maxTextLength + 500)
        let result = SharedImportRequestBuilder.build(
            attachmentURL: nil,
            attachmentText: longText,
            originalHostBundleIdentifier: nil
        )
        guard case .failure(let error) = result else {
            return XCTFail("length alone must not make bare text importable in Phase 1")
        }
        XCTAssertEqual(error, .unsupportedContent)
    }

    // MARK: - hasRequiredURL (Phase 1 support gate used by the queue/coordinator)

    func test_hasRequiredURL_trueForURLBackedRequests() {
        let result = SharedImportRequestBuilder.build(
            attachmentURL: URL(string: "https://example.com/recipe"),
            attachmentText: nil,
            originalHostBundleIdentifier: nil
        )
        guard case .success(let request) = result else { return XCTFail("expected success") }
        XCTAssertTrue(request.hasRequiredURL)
    }

    func test_hasRequiredURL_falseForLegacyBareTextValue() {
        // Simulates a request that could only exist as leftover/legacy data
        // from a different build — never produced by this builder.
        let legacy = SharedImportRequest(
            source: .sharedText,
            url: nil,
            text: "旧版本遗留的纯文字请求",
            originalHostBundleIdentifier: nil
        )
        XCTAssertFalse(legacy.hasRequiredURL)
    }

    // MARK: - Codable round-trip (must survive being written to disk and read back)

    func test_codableRoundTrip_preservesAllFields() throws {
        let original = SharedImportRequest(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .sharedTextAndURL,
            url: URL(string: "https://example.com/recipe"),
            text: "看这个",
            originalHostBundleIdentifier: "com.example.host"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(SharedImportRequest.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}
