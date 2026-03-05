import CryptoKit
import Foundation
import MembraneCore
import Wax

public actor WaxStorageBackend: PointerStore {
    private enum MetadataKey {
        static let kind = "membrane.kind"
        static let pointerID = "membrane.pointer.id"
        static let pointerSHA256 = "membrane.pointer.sha256"
        static let pointerDataType = "membrane.pointer.dataType"

        static let pointerPayloadKind = "pointerPayload"
    }

    public let session: WaxSession

    private let compressionThresholdBytes: Int
    private let compressionEncoding: CanonicalEncoding
    private var pointerFrameIDByID: [String: UInt64] = [:]

    public init(
        session: WaxSession,
        compressionThresholdBytes: Int = 4_096,
        compressionEncoding: CanonicalEncoding = .deflate
    ) {
        self.session = session
        self.compressionThresholdBytes = max(1, compressionThresholdBytes)
        self.compressionEncoding = compressionEncoding
    }

    public static func create(
        at url: URL,
        sessionConfig: WaxSession.Config = .default,
        compressionThresholdBytes: Int = 4_096,
        compressionEncoding: CanonicalEncoding = .deflate
    ) async throws -> WaxStorageBackend {
        let wax = try await Wax.create(at: url)
        let session = try await WaxSession(
            wax: wax,
            mode: .readWrite(.wait),
            config: sessionConfig
        )
        return WaxStorageBackend(
            session: session,
            compressionThresholdBytes: compressionThresholdBytes,
            compressionEncoding: compressionEncoding
        )
    }

    public func close() async throws {
        await session.close()
        try await session.wax.close()
    }

    public func store(payload: Data, dataType: MemoryPointer.DataType, summary: String) async throws -> MemoryPointer {
        let pointerID = Self.pointerID(for: payload)
        let sha256 = Self.sha256Hex(payload)

        var metadataEntries: [String: String] = [
            MetadataKey.kind: MetadataKey.pointerPayloadKind,
            MetadataKey.pointerID: pointerID,
            MetadataKey.pointerSHA256: sha256,
            MetadataKey.pointerDataType: dataType.rawValue,
        ]
        metadataEntries = metadataEntries.sorted(by: { $0.key < $1.key })
            .reduce(into: [:]) { partial, pair in partial[pair.key] = pair.value }

        let options = FrameMetaSubset(
            kind: "membrane.pointerPayload",
            role: .blob,
            searchText: summary,
            metadata: Metadata(metadataEntries)
        )
        let compression: CanonicalEncoding = payload.count >= compressionThresholdBytes
            ? compressionEncoding
            : .plain
        let frameID = try await session.put(payload, options: options, compression: compression)
        try await session.commit()

        pointerFrameIDByID[pointerID] = frameID
        return MemoryPointer(
            id: pointerID,
            dataType: dataType,
            byteSize: payload.count,
            summary: summary
        )
    }

    public func resolve(pointerID: String) async throws -> Data {
        guard let frameID = try await frameID(forPointerID: pointerID) else {
            throw MembraneError.pointerResolutionFailed(pointerID: pointerID)
        }
        return try await session.wax.frameContent(frameId: frameID)
    }

    public func delete(pointerID: String) async {
        do {
            guard let frameID = try await frameID(forPointerID: pointerID) else {
                return
            }
            try await session.wax.delete(frameId: frameID)
            try await session.commit()
            pointerFrameIDByID[pointerID] = nil
        } catch {
            // Pointer deletion is best-effort to match PointerStore's non-throwing contract.
        }
    }

    public func storeContextFrame(_ text: String) async throws -> UInt64 {
        let options = FrameMetaSubset(
            kind: "membrane.context",
            role: .document,
            searchText: text
        )
        let frameID = try await session.put(Data(text.utf8), options: options, compression: .plain)
        try await session.commit()
        return frameID
    }

    public func searchRAG(
        query: String,
        topK: Int,
        includePointerPayloads: Bool = false
    ) async throws -> SearchResponse {
        let filter = await frameFilterForRAG(includePointerPayloads: includePointerPayloads)
        let request = SearchRequest(
            query: query,
            mode: .textOnly,
            topK: max(1, topK),
            frameFilter: filter,
            allowTimelineFallback: true,
            timelineFallbackLimit: max(10, topK)
        )
        return try await session.search(request)
    }

    public func frameMeta(forPointerID pointerID: String) async -> FrameMeta? {
        do {
            guard let frameID = try await frameID(forPointerID: pointerID) else {
                return nil
            }
            return try await session.wax.frameMeta(frameId: frameID)
        } catch {
            return nil
        }
    }

    public func frameMetas(frameIDs: [UInt64]) async -> [UInt64: FrameMeta] {
        await session.wax.frameMetas(frameIds: frameIDs)
    }

    public func makeRAPTORIndex(
        compressionThresholdBytes: Int = 4_096,
        compressionEncoding: CanonicalEncoding = .deflate
    ) -> RAPTORWaxIndex {
        RAPTORWaxIndex(
            session: session,
            compressionThresholdBytes: compressionThresholdBytes,
            compressionEncoding: compressionEncoding
        )
    }

    public func frameID(forPointerID pointerID: String) async throws -> UInt64? {
        if let frameID = pointerFrameIDByID[pointerID] {
            return frameID
        }

        let metas = await session.wax.frameMetas()
        var newest: UInt64?
        for meta in metas where meta.status == .active {
            guard let entries = meta.metadata?.entries else { continue }
            guard entries[MetadataKey.kind] == MetadataKey.pointerPayloadKind else { continue }
            guard entries[MetadataKey.pointerID] == pointerID else { continue }
            if let current = newest {
                newest = max(current, meta.id)
            } else {
                newest = meta.id
            }
        }

        if let newest {
            pointerFrameIDByID[pointerID] = newest
        }
        return newest
    }

    private func frameFilterForRAG(includePointerPayloads: Bool) async -> FrameFilter {
        let metas = await session.wax.frameMetas()
        var includedFrameIDs: Set<UInt64> = []
        includedFrameIDs.reserveCapacity(metas.count)

        for meta in metas where meta.status == .active && meta.supersededBy == nil {
            let kind = meta.metadata?.entries[MetadataKey.kind]
            if includePointerPayloads || kind != MetadataKey.pointerPayloadKind {
                includedFrameIDs.insert(meta.id)
            }
        }

        return FrameFilter(frameIds: includedFrameIDs)
    }

    private static func pointerID(for payload: Data) -> String {
        let hash = sha256Hex(payload)
        return "ptr_\(hash.prefix(16))"
    }

    private static func sha256Hex(_ payload: Data) -> String {
        SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
}
