import CostbarKit
import Foundation

enum CostbarCoreError: Error, LocalizedError {
    case incompatibleABI(expected: UInt32, actual: UInt32)
    case initializationFailed
    case snapshotFailed(costbar_status_t)
    case ingestFailed(provider: String, document: String, status: costbar_status_t)
    case missingPayload

    var errorDescription: String? {
        switch self {
        case let .incompatibleABI(expected, actual):
            "Core ABI mismatch (expected \(expected), found \(actual))."
        case .initializationFailed:
            "The Costbar core could not be initialized."
        case let .snapshotFailed(status):
            "The Costbar core returned status \(status.rawValue)."
        case let .ingestFailed(provider, document, status):
            "Could not ingest \(provider)/\(document) (status \(status.rawValue))."
        case .missingPayload:
            "The Costbar core returned an empty snapshot."
        }
    }
}

final class CostbarCore {
    private let handle: OpaquePointer

    init() throws {
        let actualABI = costbar_abi_version()
        guard actualABI == COSTBAR_ABI_VERSION else {
            throw CostbarCoreError.incompatibleABI(
                expected: COSTBAR_ABI_VERSION,
                actual: actualABI
            )
        }
        guard let handle = costbar_core_create() else {
            throw CostbarCoreError.initializationFailed
        }
        self.handle = handle
    }

    deinit {
        costbar_core_destroy(handle)
    }

    func snapshot(period: Dashboard.Period) throws -> Dashboard {
        var bytes = costbar_bytes_t(ptr: nil, len: 0)
        let status = costbar_core_snapshot_json(
            handle,
            period.startUnix,
            period.endExclusiveUnix,
            &bytes
        )
        guard status == COSTBAR_STATUS_OK else {
            throw CostbarCoreError.snapshotFailed(status)
        }
        defer { costbar_bytes_free(bytes) }

        guard let pointer = bytes.ptr else {
            throw CostbarCoreError.missingPayload
        }
        let data = Data(bytes: pointer, count: bytes.len)
        return try JSONDecoder().decode(Dashboard.self, from: data)
    }

    func ingest(
        providerID: String,
        documentID: String,
        data: Data,
        receivedAt: Date = .now
    ) throws {
        let providerData = Data(providerID.utf8)
        let documentData = Data(documentID.utf8)
        let status = providerData.withUnsafeBytes { providerBuffer in
            documentData.withUnsafeBytes { documentBuffer in
                data.withUnsafeBytes { payloadBuffer in
                    costbar_core_ingest_provider_json(
                        handle,
                        providerBuffer.costbarBytes,
                        documentBuffer.costbarBytes,
                        payloadBuffer.costbarBytes,
                        Int64(receivedAt.timeIntervalSince1970)
                    )
                }
            }
        }
        guard status == COSTBAR_STATUS_OK else {
            throw CostbarCoreError.ingestFailed(
                provider: providerID,
                document: documentID,
                status: status
            )
        }
    }
}

private extension UnsafeRawBufferPointer {
    var costbarBytes: costbar_bytes_t {
        costbar_bytes_t(
            ptr: bindMemory(to: UInt8.self).baseAddress,
            len: count
        )
    }
}
