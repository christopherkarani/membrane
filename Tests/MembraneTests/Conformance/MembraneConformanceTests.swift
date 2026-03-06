import Foundation
import Testing
@testable import Membrane
@testable import MembraneCore

@Suite("MembraneConformance")
struct MembraneConformanceTests {
    @Test func determinism100Iterations() async throws {
        let timestamp = ContinuousClock().now
        let request = makeConformanceRequest(userInput: "determinism-100", timestamp: timestamp)

        let expected = try await deterministicPipelineSignature(for: request, timestamp: timestamp)

        for _ in 0 ..< 99 {
            let current = try await deterministicPipelineSignature(for: request, timestamp: timestamp)
            #expect(current == expected)
        }
    }

    @Test func checkpointRoundTrip() throws {
        let checkpoint = makeCheckpointEnvelope().normalized()

        let encoded = try encodeCheckpoint(checkpoint)
        let decoded = try decodeCheckpoint(encoded)

        #expect(decoded == checkpoint)
    }

    @Test func checkpointEncodingByteStability() throws {
        let checkpoint = makeCheckpointEnvelope().normalized()

        let first = try encodeCheckpoint(checkpoint)
        let second = try encodeCheckpoint(checkpoint)
        #expect(first == second)

        let roundTripped = try decodeCheckpoint(first)
        let reencoded = try encodeCheckpoint(roundTripped)
        #expect(reencoded == first)
    }

    @Test func budgetInvariantFuzzing() throws {
        var generator = DeterministicLCG(seed: 0xC0FFEE_24)
        let cases = 200

        for _ in 0 ..< cases {
            let totalTokens = generator.nextInt(in: 512 ... 8_192)
            var ceilings: [BucketID: Int] = [:]
            for bucket in BucketID.allCases {
                ceilings[bucket] = generator.nextInt(in: 0 ... max(totalTokens / 2, 1))
            }

            var budget = ContextBudget(totalTokens: totalTokens, profile: .custom(buckets: ceilings))
            let order = rotated(BucketID.allCases, by: generator.nextInt(upperBound: BucketID.allCases.count))

            for bucket in order {
                let availableBefore = min(budget.remaining(for: bucket), budget.totalRemaining)
                let toAllocate = generator.nextInt(in: 0 ... max(availableBefore, 0))
                try budget.allocate(toAllocate, to: bucket)

                #expect(budget.allocated(for: bucket) <= budget.ceiling(for: bucket))

                let availableAfter = min(budget.remaining(for: bucket), budget.totalRemaining)
                let overflowRequest = availableAfter + 1

                do {
                    try budget.allocate(overflowRequest, to: bucket)
                    #expect(Bool(false), "Expected budget overflow to throw for fuzz case")
                } catch let error as MembraneError {
                    guard case let .budgetExceeded(errorBucket, requested, available) = error else {
                        #expect(Bool(false), "Expected budgetExceeded error")
                        return
                    }
                    #expect(errorBucket == bucket)
                    #expect(requested == overflowRequest)
                    #expect(available == availableAfter)
                }
            }

            #expect(budget.totalAllocated <= budget.totalTokens)
            for bucket in BucketID.allCases {
                #expect(budget.allocated(for: bucket) <= budget.ceiling(for: bucket))
                #expect(budget.remaining(for: bucket) == max(budget.ceiling(for: bucket) - budget.allocated(for: bucket), 0))
            }
        }
    }

    @Test func strict4kIntegrationInvariant() async throws {
        let timestamp = ContinuousClock().now
        let request = makeConformanceRequest(userInput: "strict4k", timestamp: timestamp, toolCount: 32)

        let pipeline = MembranePipeline.foundationModel(
            budget: ContextBudget(totalTokens: 4_096, profile: .foundationModels4K),
            intake: ConformanceIntakeStage(timestamp: timestamp, modelProfile: .foundationModels4K),
            allocator: UnifiedBudgetAllocator(),
            compress: CSODistiller(keepRecentTurns: 3),
            page: MemGPTPager(),
            emit: ConformanceEmitStage()
        )

        let planned = try await pipeline.prepare(request)

        #expect(planned.prompt == request.userInput)
        #expect(planned.metadata.modelProfile == .foundationModels4K)
        #expect(planned.budget.totalTokens == 4_096)
        #expect(planned.budget.totalAllocated <= 4_096)
        #expect(planned.budget.ceiling(for: .outputReserve) == 1_000)

        for bucket in BucketID.allCases {
            #expect(planned.budget.allocated(for: bucket) <= planned.budget.ceiling(for: bucket))
        }

        guard case let .jit(index, loadedToolNames) = planned.toolPlan else {
            #expect(Bool(false), "Expected strict4k integration to use JIT tool plan")
            return
        }

        let indexNames = index.map(\.name)
        #expect(indexNames == indexNames.sorted())
        #expect(loadedToolNames.isEmpty)
    }

    @Test func fallbackInvariantLoopContinuityAndDiagnostics() async throws {
        let timestamp = ContinuousClock().now
        let request = makeConformanceRequest(userInput: "fallback-loop", timestamp: timestamp, toolCount: 18)

        let primary = MembranePipeline.openModel(
            budget: ContextBudget(totalTokens: 8_192, profile: .openModel8K),
            intake: ConformanceIntakeStage(timestamp: timestamp, modelProfile: .openModel8K),
            allocator: UnifiedBudgetAllocator(),
            compress: CSODistiller(keepRecentTurns: 3),
            page: AlwaysFailingPageStage(),
            emit: ConformanceEmitStage()
        )

        let fallback = MembranePipeline.foundationModel(
            budget: ContextBudget(totalTokens: 4_096, profile: .foundationModels4K),
            intake: ConformanceIntakeStage(timestamp: timestamp, modelProfile: .foundationModels4K),
            allocator: UnifiedBudgetAllocator(),
            compress: CSODistiller(keepRecentTurns: 3)
        )

        let result = try await prepareWithFallback(primary: primary, fallback: fallback, request: request)

        #expect(result.planned.prompt == request.userInput)
        #expect(result.planned.systemPrompt == "Conformance system prompt")
        #expect(result.planned.budget.totalAllocated <= result.planned.budget.totalTokens)
        #expect(result.diagnostics.count == 2)
        #expect(result.diagnostics[0] == "fallback.trigger=pagingStorageUnavailable(diagnostic-disk-offline);strategy=fallbackToInMemory")
        #expect(result.diagnostics[1] == "fallback.resumed=true")
    }
}

private actor ConformanceIntakeStage: IntakeStage {
    let timestamp: ContinuousClock.Instant
    let modelProfile: BudgetProfile

    init(timestamp: ContinuousClock.Instant, modelProfile: BudgetProfile) {
        self.timestamp = timestamp
        self.modelProfile = modelProfile
    }

    func process(_ input: ContextRequest, budget _: ContextBudget) async throws -> ContextWindow {
        let loader = JITToolLoader(jitMinToolCount: 10)
        let jitPlan = loader.plan(tools: input.tools, existingPlan: input.toolPlan)

        let usageCountByToolName = Dictionary(
            uniqueKeysWithValues: input.tools.enumerated().map { offset, tool in
                (tool.name, (offset * 7) % 11)
            }
        )

        let toolPlan = ToolPruner(pruneAfterTurn: 1, keepTopK: 8).prune(
            availableTools: input.tools,
            existingPlan: jitPlan,
            usageCountByToolName: usageCountByToolName,
            currentTurn: max(input.history.count, 1)
        )

        return ContextWindow(
            systemPrompt: ContextSlice(
                content: "Conformance system prompt",
                tokenCount: 140,
                importance: 1,
                source: .system,
                tier: .full,
                timestamp: timestamp
            ),
            memory: input.memories,
            tools: input.tools,
            toolPlan: toolPlan,
            history: input.history,
            retrieval: input.retrieval,
            pointers: input.pointers,
            metadata: ContextMetadata(turnNumber: input.history.count, sessionID: "conformance-session", modelProfile: modelProfile)
        )
    }
}

private actor ConformanceEmitStage: EmitStage {
    func process(_ input: PagedContext, budget: ContextBudget) async throws -> PlannedRequest {
        PlannedRequest(
            prompt: "conformance-emit",
            systemPrompt: input.window.systemPrompt.content,
            toolPlan: input.window.toolPlan,
            budget: budget,
            metadata: input.window.metadata
        )
    }
}

private actor AlwaysFailingPageStage: PageStage {
    func process(_ input: CompressedContext, budget: ContextBudget) async throws -> PagedContext {
        _ = input
        _ = budget
        throw MembraneError.pagingStorageUnavailable(reason: "diagnostic-disk-offline")
    }
}

private struct DeterminismSignature: Equatable {
    let prompt: String
    let systemPrompt: String
    let toolPlan: ToolPlan
    let metadataTurn: Int
    let budgetAllocations: [Int]
    let budgetRemaining: [Int]
}

private func deterministicPipelineSignature(
    for request: ContextRequest,
    timestamp: ContinuousClock.Instant
) async throws -> DeterminismSignature {
    let pipeline = MembranePipeline.openModel(
        budget: ContextBudget(totalTokens: 8_192, profile: .openModel8K),
        intake: ConformanceIntakeStage(timestamp: timestamp, modelProfile: .openModel8K),
        allocator: UnifiedBudgetAllocator(),
        compress: CSODistiller(keepRecentTurns: 4),
        page: MemGPTPager(pressureThreshold: 0.82, keepRecentHistoryTurns: 4),
        emit: ConformanceEmitStage()
    )

    let planned = try await pipeline.prepare(request)

    return DeterminismSignature(
        prompt: planned.prompt,
        systemPrompt: planned.systemPrompt,
        toolPlan: planned.toolPlan,
        metadataTurn: planned.metadata.turnNumber,
        budgetAllocations: BucketID.allCases.map { planned.budget.allocated(for: $0) },
        budgetRemaining: BucketID.allCases.map { planned.budget.remaining(for: $0) }
    )
}

private struct FallbackResult {
    let planned: PlannedRequest
    let diagnostics: [String]
}

private func prepareWithFallback(
    primary: MembranePipeline,
    fallback: MembranePipeline,
    request: ContextRequest
) async throws -> FallbackResult {
    var diagnostics: [String] = []

    do {
        let planned = try await primary.prepare(request)
        diagnostics.append("fallback.trigger=none;strategy=none")
        diagnostics.append("fallback.resumed=false")
        return FallbackResult(planned: planned, diagnostics: diagnostics)
    } catch let error as MembraneError {
        switch error {
        case .pagingStorageUnavailable(let reason):
            diagnostics.append("fallback.trigger=pagingStorageUnavailable(\(reason));strategy=fallbackToInMemory")
        default:
            diagnostics.append("fallback.trigger=\(String(describing: error));strategy=fail")
        }

        guard case .fallbackToInMemory = error.recoveryStrategy else {
            throw error
        }

        let planned = try await fallback.prepare(request)
        diagnostics.append("fallback.resumed=true")
        return FallbackResult(planned: planned, diagnostics: diagnostics)
    }
}

private struct DeterministicCheckpointEnvelope: Codable, Equatable {
    struct BudgetSnapshot: Codable, Equatable {
        struct BucketSnapshot: Codable, Equatable {
            let bucketID: BucketID
            let allocatedTokens: Int
            let ceilingTokens: Int
        }

        let totalTokens: Int
        let allocations: [BucketSnapshot]
        let kvBytesPerToken: Int?
        let kvMemoryBudgetBytes: Int?
        let maxSequenceLength: Int?

        func normalized() -> BudgetSnapshot {
            BudgetSnapshot(
                totalTokens: totalTokens,
                allocations: allocations.sorted { lhs, rhs in
                    lhs.bucketID.rawValue < rhs.bucketID.rawValue
                },
                kvBytesPerToken: kvBytesPerToken,
                kvMemoryBudgetBytes: kvMemoryBudgetBytes,
                maxSequenceLength: maxSequenceLength
            )
        }
    }

    let budget: BudgetSnapshot
    let toolPlan: ToolPlan
    let cso: ContextStateObject
    let pointers: [MemoryPointer]
    let diagnostics: [String]

    static func == (lhs: DeterministicCheckpointEnvelope, rhs: DeterministicCheckpointEnvelope) -> Bool {
        lhs.budget == rhs.budget
            && lhs.toolPlan == rhs.toolPlan
            && lhs.cso.entities == rhs.cso.entities
            && lhs.cso.decisions == rhs.cso.decisions
            && lhs.cso.openQuestions == rhs.cso.openQuestions
            && lhs.cso.keyFacts == rhs.cso.keyFacts
            && lhs.cso.turnCount == rhs.cso.turnCount
            && lhs.pointers == rhs.pointers
            && lhs.diagnostics == rhs.diagnostics
    }

    func normalized() -> DeterministicCheckpointEnvelope {
        let normalizedCSO = ContextStateObject(
            entities: cso.entities.sorted(),
            decisions: Array(Set(cso.decisions)).sorted(),
            openQuestions: Array(Set(cso.openQuestions)).sorted(),
            keyFacts: Array(Set(cso.keyFacts)).sorted(),
            turnCount: cso.turnCount
        )

        let normalizedToolPlan: ToolPlan
        switch toolPlan {
        case .allowAll:
            normalizedToolPlan = .allowAll
        case let .allowList(toolNames):
            normalizedToolPlan = .allowList(normalized: toolNames)
        case let .jit(index, loadedToolNames):
            normalizedToolPlan = .jit(normalized: index, loaded: loadedToolNames)
        }

        let normalizedPointers = Array(Set(pointers)).sorted { lhs, rhs in
            if lhs.id != rhs.id {
                return lhs.id < rhs.id
            }
            return lhs.summary < rhs.summary
        }

        return DeterministicCheckpointEnvelope(
            budget: budget.normalized(),
            toolPlan: normalizedToolPlan,
            cso: normalizedCSO,
            pointers: normalizedPointers,
            diagnostics: Array(Set(diagnostics)).sorted()
        )
    }
}

private func makeCheckpointEnvelope() -> DeterministicCheckpointEnvelope {
    var budget = ContextBudget(
        totalTokens: 4_096,
        profile: .foundationModels4K,
        kvBytesPerToken: 3_072,
        kvMemoryBudgetBytes: 96_000_000
    )

    try? budget.allocate(220, to: .system)
    try? budget.allocate(700, to: .history)
    try? budget.allocate(300, to: .memory)

    let allocations = BucketID.allCases.map { bucket in
        DeterministicCheckpointEnvelope.BudgetSnapshot.BucketSnapshot(
            bucketID: bucket,
            allocatedTokens: budget.allocated(for: bucket),
            ceilingTokens: budget.ceiling(for: bucket)
        )
    }

    let budgetSnapshot = DeterministicCheckpointEnvelope.BudgetSnapshot(
        totalTokens: budget.totalTokens,
        allocations: allocations,
        kvBytesPerToken: budget.kvBytesPerToken,
        kvMemoryBudgetBytes: budget.kvMemoryBudgetBytes,
        maxSequenceLength: budget.maxSequenceLength
    )

    let cso = ContextStateObject(
        entities: ["Membrane", "Swift", "Membrane"],
        decisions: ["Use deterministic checkpoints", "Use deterministic checkpoints", "Preserve bounds"],
        openQuestions: ["Can fallback remain continuous", "Can fallback remain continuous"],
        keyFacts: ["Budget total is 4096", "Tool plan is JIT", "Budget total is 4096"],
        turnCount: 42
    )

    let pointers = [
        MemoryPointer(id: "ptr_b", dataType: .document, byteSize: 512, summary: "Second"),
        MemoryPointer(id: "ptr_a", dataType: .document, byteSize: 256, summary: "First"),
        MemoryPointer(id: "ptr_b", dataType: .document, byteSize: 512, summary: "Second"),
    ]

    return DeterministicCheckpointEnvelope(
        budget: budgetSnapshot,
        toolPlan: .jit(
            normalized: [
                .init(name: "search", description: "Search web"),
                .init(name: "calc", description: "Calculator"),
            ],
            loaded: ["calc", "search", "calc"]
        ),
        cso: cso,
        pointers: pointers,
        diagnostics: ["resumed=true", "resumed=true", "fallback=fm4k"]
    )
}

private func encodeCheckpoint(_ checkpoint: DeterministicCheckpointEnvelope) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(checkpoint.normalized())
}

private func decodeCheckpoint(_ data: Data) throws -> DeterministicCheckpointEnvelope {
    let decoded = try JSONDecoder().decode(DeterministicCheckpointEnvelope.self, from: data)
    return decoded.normalized()
}

private func makeConformanceRequest(
    userInput: String,
    timestamp: ContinuousClock.Instant,
    toolCount: Int = 20
) -> ContextRequest {
    ContextRequest(
        userInput: userInput,
        tools: (0 ..< toolCount).map { index in
            let name = String(format: "tool_%03d", index)
            let schema = String(repeating: "parameter_\(index): string;", count: 16)
            return ToolManifest(name: name, description: "Conformance tool \(name)", fullSchema: schema)
        },
        toolPlan: .allowAll,
        history: (0 ..< 22).map { index in
            ContextSlice(
                content: "history-turn-\(index)",
                tokenCount: 72,
                importance: 0.45 + (Double(index % 5) * 0.05),
                source: .history,
                tier: .full,
                timestamp: timestamp
            )
        },
        memories: (0 ..< 8).map { index in
            ContextSlice(
                content: "memory-item-\(index)",
                tokenCount: 36,
                importance: 0.5,
                source: .memory,
                tier: .full,
                timestamp: timestamp
            )
        },
        retrieval: (0 ..< 6).map { index in
            ContextSlice(
                content: "retrieval-item-\(index)",
                tokenCount: 48,
                importance: 0.4,
                source: .retrieval,
                tier: .gist,
                timestamp: timestamp
            )
        },
        pointers: [
            MemoryPointer(id: "ptr_z", dataType: .document, byteSize: 1_024, summary: "z"),
            MemoryPointer(id: "ptr_a", dataType: .document, byteSize: 1_024, summary: "a"),
        ]
    )
}

private struct DeterministicLCG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextUInt64() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func nextInt(upperBound: Int) -> Int {
        guard upperBound > 0 else {
            return 0
        }
        return Int(nextUInt64() % UInt64(upperBound))
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        guard range.lowerBound <= range.upperBound else {
            return range.lowerBound
        }

        let width = range.upperBound - range.lowerBound + 1
        return range.lowerBound + nextInt(upperBound: width)
    }
}

private func rotated<T>(_ values: [T], by offset: Int) -> [T] {
    guard !values.isEmpty else {
        return values
    }

    let normalized = ((offset % values.count) + values.count) % values.count
    guard normalized > 0 else {
        return values
    }

    return Array(values[normalized...]) + Array(values[..<normalized])
}
