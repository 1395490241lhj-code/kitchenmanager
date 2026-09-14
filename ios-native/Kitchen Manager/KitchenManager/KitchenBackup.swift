import SwiftUI
import UniformTypeIdentifiers

struct KitchenBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data = Data()) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw KitchenBackupError.invalidFile
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Proving that a file is a supported Kitchen Manager backup is a different
/// result from decoding it, and the two must not be conflated.
///
/// `KitchenBackupPayload` resolves every field with `decodeIfPresent`, so any
/// JSON object decodes successfully: unknown keys are ignored and absent keys
/// become empty. `{}` therefore decodes into a payload whose seven domains are
/// all empty, and restoring that replaces a real kitchen with nothing while
/// reporting success. Identity has to be established on the encoded object
/// itself, before that tolerant decode runs.
///
/// The tolerance is deliberately left intact. Real v1 files omit keys for
/// honest reasons: `weeklyPlan` is optional and the synthesized encoder drops
/// it when nil, `exportedAt` is missing from the earliest files, and
/// `preparedComponents` and `specialPlans` were added to the payload while the
/// version stayed 1. Recognition is therefore based on backup identity plus the
/// keys every v1 file has always carried -- never on how many items they hold,
/// because a kitchen that was empty when it was exported is a legitimate backup.
enum KitchenBackupValidator {
    static let supportedFormat = "kitchen-manager-native-backup"
    static let supportedVersion = 1

    /// Present in every v1 file, including the two legacy fixtures the
    /// repository already pins. Deliberately excludes `exportedAt`,
    /// `weeklyPlan`, `preparedComponents` and `specialPlans`, each of which a
    /// genuine v1 backup may omit.
    static let requiredDomainKeys = ["inventory", "plans", "shoppingItems", "consumptionRecords"]

    /// A file that has been proven to be a supported backup, plus the facts a
    /// member needs in order to decide about it.
    ///
    /// `exportedAt` is deliberately optional and is read from the encoded
    /// object rather than from the decoded payload: the tolerant decoder
    /// substitutes the decode-time date when the key is absent, and the oldest
    /// real v1 files have no such key. Presenting that substitute as the
    /// backup's creation date would be inventing metadata.
    struct Candidate {
        let payload: KitchenBackupPayload
        let exportedAt: Date?
        let version: Int
    }

    /// Returns the payload only when the data is a supported backup. Throwing
    /// here is the whole point: the caller must not be able to reach a
    /// destructive write with an unvalidated payload.
    static func validate(_ data: Data) throws -> KitchenBackupPayload {
        try validateCandidate(data).payload
    }

    static func validateCandidate(_ data: Data) throws -> Candidate {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // Malformed bytes, or valid JSON that is not an object at all.
            throw KitchenBackupError.invalidFile
        }
        guard let format = object["format"] as? String, format == supportedFormat else {
            throw KitchenBackupError.unrecognizedBackup
        }
        guard let version = object["version"] as? Int else {
            throw KitchenBackupError.unrecognizedBackup
        }
        guard version == supportedVersion else {
            // No migration behaviour, and no silent acceptance of an unknown
            // version: a v2 file is refused by a v1 build rather than being
            // partially read through v1 keys that happen to match.
            throw KitchenBackupError.unsupportedVersion(version)
        }
        for key in requiredDomainKeys {
            guard object[key] is [Any] else { throw KitchenBackupError.unrecognizedBackup }
        }
        let payload: KitchenBackupPayload
        do {
            payload = try JSONDecoder().decode(KitchenBackupPayload.self, from: data)
        } catch {
            throw KitchenBackupError.invalidFile
        }
        // Only a key that is actually present counts as a real export date.
        let exportedAt = object["exportedAt"] == nil ? nil : payload.exportedAt
        return Candidate(payload: payload, exportedAt: exportedAt, version: version)
    }
}
