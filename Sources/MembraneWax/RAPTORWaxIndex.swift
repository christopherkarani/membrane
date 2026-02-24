import Foundation
import Membrane
import MembraneCore
import Wax

public actor RAPTORWaxIndex: RAPTORIndex {
    private enum MetadataKey {
        static let kind = "membrane.kind"
        static let nodeID = "membrane.raptor.id"
        static let parentID = "membrane.raptor.parent_id"
        static let depth = "membrane.raptor.depth"
        static let tokenCount = "membrane.raptor.tokens"

        static let raptorNodeKind = "raptorNode"
    }

    public let session: WaxSession

    private let compressionThresholdBytes: Int
    private let compressionEncoding: CanonicalEncoding
    private let waxLaneWeight: Float
    private let heuristicLaneWeight: Float

    private var frameIDByNodeID: [String: UInt64] = [:]
    private var nodeByFrameID: [UInt64: RAPTORNode] = [:]

    public init(
        session: WaxSession,
        compressionThresholdBytes: Int = 4_096,
        compressionEncoding: CanonicalEncoding = .deflate,
        waxLaneWeight: Float = 0.7,
        heuristicLaneWeight: Float = 0.3
    ) {
        self.session = session
        self.compressionThresholdBytes = max(1, compressionThresholdBytes)
        self.compressionEncoding = compressionEncoding
        self.waxLaneWeight = max(0, waxLaneWeight)
        self.heuristicLaneWeight = max(0, heuristicLaneWeight)
    }

    @discardableResult
    public func store(node: RAPTORNode) async throws -> UInt64 {
        if let existingFrameID = try await frameID(forNodeID: node.id) {
            return existingFrameID
        }

        var metadataEntries: [String: String] = [
            MetadataKey.kind: MetadataKey.raptorNodeKind,
            MetadataKey.nodeID: node.id,
            MetadataKey.depth: String(node.depth),
            MetadataKey.tokenCount: String(node.tokenCount),
        ]
        if let parentID = node.parentID {
            metadataEntries[MetadataKey.parentID] = parentID
        }
        metadataEntries = metadataEntries.sorted(by: { $0.key < $1.key })
            .reduce(into: [:]) { partial, pair in partial[pair.key] = pair.value }

        let options = FrameMetaSubset(
            kind: "membrane.raptorNode",
            role: .document,
            searchText: node.text,
            metadata: Metadata(metadataEntries)
        )
        let payload = Data(node.text.utf8)
        let compression: CanonicalEncoding = payload.count >= compressionThresholdBytes
            ? compressionEncoding
            : .plain
        let frameID = try await session.put(payload, options: options, compression: compression)
        try await session.commit()

        frameIDByNodeID[node.id] = frameID
        nodeByFrameID[frameID] = node
        return frameID
    }

    public func store(nodes: [RAPTORNode]) async throws -> [UInt64] {
        var frameIDs: [UInt64] = []
        frameIDs.reserveCapacity(nodes.count)
        for node in nodes {
            frameIDs.append(try await store(node: node))
        }
        return frameIDs
    }

    public func frameMeta(forNodeID nodeID: String) async -> FrameMeta? {
        do {
            guard let frameID = try await frameID(forNodeID: nodeID) else {
                return nil
            }
            return try await session.wax.frameMeta(frameId: frameID)
        } catch {
            return nil
        }
    }

    public func search(query: String, topK: Int) async throws -> [RAPTORNode] {
        guard topK > 0 else {
            return []
        }

        let allFrameIDs = try await allRaptorFrameIDs()
        guard !allFrameIDs.isEmpty else {
            return []
        }

        let filter = FrameFilter(frameIds: Set(allFrameIDs))
        let waxResponse = try await session.search(
            SearchRequest(
                query: query,
                mode: .textOnly,
                topK: max(topK * 3, topK),
                frameFilter: filter,
                allowTimelineFallback: true,
                timelineFallbackLimit: max(10, topK * 3)
            )
        )
        let waxRanked = waxResponse.results.map { $0.frameId }
        let heuristicRanked = try await heuristicRankedFrameIDs(query: query, frameIDs: allFrameIDs)

        let fused = HybridSearch.rrfFusion(
            lists: [
                (weight: waxLaneWeight, frameIds: waxRanked),
                (weight: heuristicLaneWeight, frameIds: heuristicRanked),
            ]
        ).map { $0.0 }

        var selected: [UInt64] = []
        selected.reserveCapacity(topK)
        var seen: Set<UInt64> = []
        for frameID in fused where selected.count < topK {
            if seen.insert(frameID).inserted {
                selected.append(frameID)
            }
        }
        for frameID in heuristicRanked where selected.count < topK {
            if seen.insert(frameID).inserted {
                selected.append(frameID)
            }
        }

        var nodes: [RAPTORNode] = []
        nodes.reserveCapacity(selected.count)
        for frameID in selected {
            if let node = try await node(forFrameID: frameID) {
                nodes.append(node)
            }
        }
        return nodes
    }

    private func allRaptorFrameIDs() async throws -> [UInt64] {
        let metas = await session.wax.frameMetas()
        var byNodeID: [String: UInt64] = [:]

        for meta in metas where meta.status == .active && meta.supersededBy == nil {
            guard let entries = meta.metadata?.entries else { continue }
            guard entries[MetadataKey.kind] == MetadataKey.raptorNodeKind else { continue }
            guard let nodeID = entries[MetadataKey.nodeID], !nodeID.isEmpty else { continue }

            if let existing = byNodeID[nodeID] {
                byNodeID[nodeID] = min(existing, meta.id)
            } else {
                byNodeID[nodeID] = meta.id
            }
        }

        frameIDByNodeID = byNodeID
        return byNodeID.values.sorted()
    }

    private func frameID(forNodeID nodeID: String) async throws -> UInt64? {
        if let cached = frameIDByNodeID[nodeID] {
            return cached
        }

        _ = try await allRaptorFrameIDs()
        return frameIDByNodeID[nodeID]
    }

    private func heuristicRankedFrameIDs(query: String, frameIDs: [UInt64]) async throws -> [UInt64] {
        let normalizedQuery = query.lowercased()
        let queryTokens = normalizedQuery
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)

        var scored: [(frameID: UInt64, score: Int, depth: Int, nodeID: String)] = []
        scored.reserveCapacity(frameIDs.count)

        for frameID in frameIDs {
            guard let node = try await node(forFrameID: frameID) else {
                continue
            }
            let text = node.text.lowercased()

            var score = 0
            if !normalizedQuery.isEmpty, text.contains(normalizedQuery) {
                score += 4
            }
            for token in queryTokens where !token.isEmpty {
                if text.contains(token) {
                    score += 1
                }
            }

            scored.append((frameID: frameID, score: score, depth: node.depth, nodeID: node.id))
        }

        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            if lhs.nodeID != rhs.nodeID { return lhs.nodeID < rhs.nodeID }
            return lhs.frameID < rhs.frameID
        }.map { $0.frameID }
    }

    private func node(forFrameID frameID: UInt64) async throws -> RAPTORNode? {
        if let cached = nodeByFrameID[frameID] {
            return cached
        }

        let meta = try await session.wax.frameMeta(frameId: frameID)
        guard meta.status == .active, meta.supersededBy == nil else {
            return nil
        }
        guard let entries = meta.metadata?.entries else {
            return nil
        }
        guard entries[MetadataKey.kind] == MetadataKey.raptorNodeKind else {
            return nil
        }
        guard let nodeID = entries[MetadataKey.nodeID], !nodeID.isEmpty else {
            return nil
        }

        let textData = try await session.wax.frameContent(frameId: frameID)
        let text = String(data: textData, encoding: .utf8) ?? ""
        let depth = Int(entries[MetadataKey.depth] ?? "") ?? 0
        let tokenCount = Int(entries[MetadataKey.tokenCount] ?? "")
            ?? max(1, text.count / 4)
        let parentID = entries[MetadataKey.parentID]

        let node = RAPTORNode(
            id: nodeID,
            parentID: parentID?.isEmpty == false ? parentID : nil,
            depth: depth,
            text: text,
            tokenCount: tokenCount
        )
        nodeByFrameID[frameID] = node
        frameIDByNodeID[nodeID] = frameID
        return node
    }
}
