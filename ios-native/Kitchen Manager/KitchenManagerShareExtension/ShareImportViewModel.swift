import Combine
import Foundation

@MainActor
final class ShareImportViewModel: ObservableObject {
    enum State: Equatable {
        case loading
        case ready(preview: Preview)
        case unsupported(message: String)
        case saving(preview: Preview)
        case saved
        case failed(preview: Preview, message: String)
    }

    struct Preview: Equatable {
        let typeDescription: String
        let headline: String
        let detail: String?
    }

    @Published private(set) var state: State = .loading

    private let queue: SharedImportQueue?
    private var pendingRequest: SharedImportRequest?
    private var isSubmitting = false

    init(queue: SharedImportQueue?) {
        self.queue = queue
    }

    func load(from items: [NSExtensionItem]?) async {
        let extracted = await ShareItemExtractor.extract(from: items)
        let result = SharedImportRequestBuilder.build(
            attachmentURL: extracted.url,
            attachmentText: extracted.text,
            originalHostBundleIdentifier: nil
        )

        switch result {
        case .success(let request):
            pendingRequest = request
            state = .ready(preview: Self.makePreview(for: request))
        case .failure(let error):
            pendingRequest = nil
            state = .unsupported(message: error.localizedDescription)
        }
    }

    /// Lets the user edit the shared text before submitting (kept minimal —
    /// no rich editor, just a single-field override).
    func updateText(_ text: String) {
        guard let request = pendingRequest else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = SharedImportRequest(
            id: request.id,
            createdAt: request.createdAt,
            source: request.source,
            url: request.url,
            text: trimmed.isEmpty ? nil : trimmed,
            originalHostBundleIdentifier: request.originalHostBundleIdentifier,
            schemaVersion: request.schemaVersion
        )
        pendingRequest = updated
        if case .ready = state {
            state = .ready(preview: Self.makePreview(for: updated))
        }
    }

    /// Submits the pending request. Idempotent: a second tap while a submit
    /// is already in flight (or after it already succeeded) is a no-op, so
    /// rapid double-taps can't enqueue duplicate requests.
    func submit() {
        guard !isSubmitting, let request = pendingRequest else { return }
        guard case .ready(let preview) = state else { return }

        guard let queue else {
            state = .failed(preview: preview, message: "无法访问共享数据，请重新打开 App 后再试一次。")
            return
        }

        isSubmitting = true
        state = .saving(preview: preview)

        do {
            try queue.enqueue(request)
            state = .saved
        } catch SharedImportQueue.QueueError.queueFull {
            state = .failed(preview: preview, message: "待导入队列已满，请先打开 Kitchen Manager 处理已保存的分享。")
        } catch {
            state = .failed(preview: preview, message: "保存失败，请重试。")
        }
        isSubmitting = false
    }

    private static func makePreview(for request: SharedImportRequest) -> Preview {
        switch request.source {
        case .sharedURL:
            return Preview(
                typeDescription: "网页链接",
                headline: request.url?.host ?? request.url?.absoluteString ?? "",
                detail: request.url?.absoluteString
            )
        case .sharedText:
            // Unreachable in Phase 1: `SharedImportRequestBuilder` never
            // succeeds without a URL, so `pendingRequest` can never hold a
            // `.sharedText` value here. Case kept only because the shared
            // enum must stay exhaustive — see `ShareImportSource`'s doc.
            return Preview(
                typeDescription: "文字",
                headline: firstLine(of: request.text ?? ""),
                detail: request.text
            )
        case .sharedTextAndURL:
            return Preview(
                typeDescription: "链接和文字",
                headline: request.url?.host ?? request.url?.absoluteString ?? "",
                detail: request.text
            )
        }
    }

    private static func firstLine(of text: String, maxLength: Int = 60) -> String {
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? text
        guard line.count > maxLength else { return line }
        return String(line.prefix(maxLength)) + "…"
    }
}
