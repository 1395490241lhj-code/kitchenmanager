import Foundation

/// Minimal multipart/form-data builder for `APIClient.upload`.
///
/// Not used by any service today — every current image upload (receipt OCR,
/// recipe photo import) sends a base64 string inside a JSON body through
/// `AIChatService`, so nothing was migrated to this. It exists so a future
/// endpoint that needs true multipart upload doesn't have to reinvent it.
nonisolated struct MultipartFormData: Sendable {
    private let boundary = "Boundary-\(UUID().uuidString)"
    private var parts: [Data] = []

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(name: String, value: String) {
        var part = Data()
        part.append("--\(boundary)\r\n".data(using: .utf8)!)
        part.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        part.append(value.data(using: .utf8)!)
        part.append("\r\n".data(using: .utf8)!)
        parts.append(part)
    }

    mutating func addFile(name: String, filename: String, mimeType: String, data: Data) {
        var part = Data()
        part.append("--\(boundary)\r\n".data(using: .utf8)!)
        part.append(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
                .data(using: .utf8)!
        )
        part.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        part.append(data)
        part.append("\r\n".data(using: .utf8)!)
        parts.append(part)
    }

    func encode() -> Data {
        var full = Data()
        parts.forEach { full.append($0) }
        full.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return full
    }
}
