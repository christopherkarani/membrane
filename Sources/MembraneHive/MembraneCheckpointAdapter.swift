import Foundation
import MembraneCore

public struct MembraneCheckpointState: Sendable, Codable, Equatable {
    private enum Bounds {
        static let maxBudgetAllocations = 64
        static let maxLoadedToolNames = 128
        static let maxAllowListToolNames = 128
        static let maxUsageCounts = 256
        static let maxCSOSummaries = 256
        static let maxPointerIDs = 512
    }

    public struct BudgetSnapshot: Sendable, Codable, Equatable {
        public struct BucketAllocation: Sendable, Codable, Equatable {
            public let bucketID: String
            public let allocatedTokens: Int

            public init(bucketID: String, allocatedTokens: Int) {
                self.bucketID = bucketID
                self.allocatedTokens = allocatedTokens
            }
        }

        public let totalTokens: Int
        public let allocations: [BucketAllocation]
        public let kvBytesPerToken: Int?
        public let kvMemoryBudgetBytes: Int?
        public let maxSequenceLength: Int?

        public init(
            totalTokens: Int,
            allocations: [BucketAllocation] = [],
            kvBytesPerToken: Int? = nil,
            kvMemoryBudgetBytes: Int? = nil,
            maxSequenceLength: Int? = nil
        ) {
            self.totalTokens = totalTokens
            self.allocations = allocations
            self.kvBytesPerToken = kvBytesPerToken
            self.kvMemoryBudgetBytes = kvMemoryBudgetBytes
            self.maxSequenceLength = maxSequenceLength
        }
    }

    public struct PagingCursor: Sendable, Codable, Equatable {
        public let pageIndex: Int
        public let lastEvictedFrameID: String?

        public init(pageIndex: Int, lastEvictedFrameID: String?) {
            self.pageIndex = pageIndex
            self.lastEvictedFrameID = lastEvictedFrameID
        }
    }

    public struct ToolState: Sendable, Codable, Equatable {
        public enum Mode: String, Sendable, Codable, Equatable {
            case allowAll
            case allowList
            case jit
        }

        public struct UsageCount: Sendable, Codable, Equatable {
            public let toolName: String
            public let count: Int

            public init(toolName: String, count: Int) {
                self.toolName = toolName
                self.count = count
            }
        }

        public let mode: Mode
        public let loadedToolNames: [String]
        public let allowListToolNames: [String]
        public let usageCounts: [UsageCount]

        public init(
            mode: Mode,
            loadedToolNames: [String],
            allowListToolNames: [String],
            usageCounts: [UsageCount]
        ) {
            self.mode = mode
            self.loadedToolNames = loadedToolNames
            self.allowListToolNames = allowListToolNames
            self.usageCounts = usageCounts
        }
    }

    public let budget: BudgetSnapshot
    public let csoSummaries: [String]
    public let pagingCursor: PagingCursor?
    public let toolState: ToolState
    public let pointerIDs: [String]

    public init(
        budget: BudgetSnapshot,
        csoSummaries: [String] = [],
        pagingCursor: PagingCursor? = nil,
        toolState: ToolState,
        pointerIDs: [String] = []
    ) {
        self.budget = budget
        self.csoSummaries = csoSummaries
        self.pagingCursor = pagingCursor
        self.toolState = toolState
        self.pointerIDs = pointerIDs
    }

    public func normalized() -> MembraneCheckpointState {
        let normalizedAllocations = budget.allocations
            .sorted { lhs, rhs in
                if lhs.bucketID != rhs.bucketID {
                    return lhs.bucketID < rhs.bucketID
                }
                return lhs.allocatedTokens < rhs.allocatedTokens
            }
            .prefix(Bounds.maxBudgetAllocations)
            .map { $0 }

        var usageByToolName: [String: Int] = [:]
        usageByToolName.reserveCapacity(toolState.usageCounts.count)
        for usage in toolState.usageCounts {
            usageByToolName[usage.toolName, default: 0] += usage.count
        }

        let normalizedUsageCounts = usageByToolName
            .map { ToolState.UsageCount(toolName: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.toolName != rhs.toolName {
                    return lhs.toolName < rhs.toolName
                }
                return lhs.count < rhs.count
            }
            .prefix(Bounds.maxUsageCounts)
            .map { $0 }

        let normalizedToolState = ToolState(
            mode: toolState.mode,
            loadedToolNames: Self.sortedUnique(toolState.loadedToolNames, limit: Bounds.maxLoadedToolNames),
            allowListToolNames: Self.sortedUnique(toolState.allowListToolNames, limit: Bounds.maxAllowListToolNames),
            usageCounts: normalizedUsageCounts
        )

        return MembraneCheckpointState(
            budget: BudgetSnapshot(
                totalTokens: budget.totalTokens,
                allocations: normalizedAllocations,
                kvBytesPerToken: budget.kvBytesPerToken,
                kvMemoryBudgetBytes: budget.kvMemoryBudgetBytes,
                maxSequenceLength: budget.maxSequenceLength
            ),
            csoSummaries: Self.sortedUnique(csoSummaries, limit: Bounds.maxCSOSummaries),
            pagingCursor: pagingCursor,
            toolState: normalizedToolState,
            pointerIDs: Self.sortedUnique(pointerIDs, limit: Bounds.maxPointerIDs)
        )
    }

    private static func sortedUnique(_ values: [String], limit: Int) -> [String] {
        let unique = Set(values)
        return unique.sorted().prefix(limit).map { $0 }
    }
}

public enum MembraneCheckpointCodec {
    public static func encode(_ state: MembraneCheckpointState?) throws -> Data? {
        guard let state else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state.normalized())
    }

    public static func decode(_ data: Data?) throws -> MembraneCheckpointState? {
        guard let data else {
            return nil
        }
        let decoded = try JSONDecoder().decode(MembraneCheckpointState.self, from: data)
        return decoded.normalized()
    }
}

public actor MembraneCheckpointAdapter {
    private var state: MembraneCheckpointState?

    public init(initialState: MembraneCheckpointState? = nil) {
        state = initialState?.normalized()
    }

    public func restore(from checkpointData: Data?) throws {
        state = try MembraneCheckpointCodec.decode(checkpointData)
    }

    public func replaceState(_ newState: MembraneCheckpointState?) {
        state = newState?.normalized()
    }

    public func currentState() -> MembraneCheckpointState? {
        state
    }

    public func checkpointData() throws -> Data? {
        try MembraneCheckpointCodec.encode(state)
    }
}
