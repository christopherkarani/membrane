import Foundation
import Testing
@testable import Membrane
@testable import MembraneCore

@Suite("MembraneBenchmarks")
struct MembraneBenchmarks {
    @Test func toolContextReductionWithAndWithoutJIT() {
        let tools = makeTools(count: 48, schemaUnits: 96)
        let usageCountByToolName = Dictionary(
            uniqueKeysWithValues: tools.enumerated().map { offset, tool in
                (tool.name, (offset * 13) % 17)
            }
        )

        let pruner = ToolPruner(pruneAfterTurn: 1, keepTopK: 12)
        let jitLoader = JITToolLoader(jitMinToolCount: 10)
        let seededLoadedNames = tools.prefix(4).map(\.name)

        let withoutJITPlan = pruner.prune(
            availableTools: tools,
            existingPlan: .allowAll,
            usageCountByToolName: usageCountByToolName,
            currentTurn: 100
        )

        let withJITPlan = pruner.prune(
            availableTools: tools,
            existingPlan: jitLoader.plan(
                tools: tools,
                existingPlan: ToolPlan.jit(normalized: [], loaded: seededLoadedNames)
            ),
            usageCountByToolName: usageCountByToolName,
            currentTurn: 100
        )

        let fullTokenLoad = materializedToolTokens(for: tools, under: .allowAll)
        let tokenLoadWithoutJIT = materializedToolTokens(for: tools, under: withoutJITPlan)
        let tokenLoadWithJIT = materializedToolTokens(for: tools, under: withJITPlan)

        #expect(fullTokenLoad > 0)
        #expect(tokenLoadWithoutJIT < fullTokenLoad)
        #expect(tokenLoadWithJIT < fullTokenLoad)
        #expect(tokenLoadWithJIT <= tokenLoadWithoutJIT)

        guard case let .allowList(toolNames) = withoutJITPlan else {
            #expect(Bool(false), "Expected allow-list plan in non-JIT benchmark path")
            return
        }
        #expect(toolNames == toolNames.sorted())

        guard case let .jit(_, loadedToolNames) = withJITPlan else {
            #expect(Bool(false), "Expected JIT plan in JIT benchmark path")
            return
        }
        #expect(loadedToolNames == seededLoadedNames.sorted())
    }

    @Test func csoCompressionRatioOver100Turns() async throws {
        let keepRecentTurns = 3
        let timestamp = ContinuousClock().now
        let history = makeHistoryTurns(count: 100, tokenCount: 64, timestamp: timestamp)
        let window = makeWindow(
            tools: [],
            toolPlan: .allowAll,
            history: history,
            retrieval: [],
            timestamp: timestamp,
            modelProfile: .openModel8K
        )
        let budget = ContextBudget(totalTokens: 8_192, profile: .openModel8K)
        let distiller = CSODistiller(keepRecentTurns: keepRecentTurns)
        let input = BudgetedContext(window: window, budget: budget)

        let (result, elapsed) = try await measure {
            try await distiller.process(input, budget: budget)
        }

        #expect(result.compressionReport.originalTokens == 6_400)
        #expect(result.compressionReport.compressedTokens < result.compressionReport.originalTokens)
        #expect(result.compressionReport.ratio < 1)
        #expect(result.compressionReport.techniquesApplied == ["CSO"])
        #expect(result.window.history.count == keepRecentTurns + 1)
        #expect(elapsed >= .zero)
    }

    @Test func budgetAllocationInvariantPerformance() async throws {
        let allocator = UnifiedBudgetAllocator()
        let timestamp = ContinuousClock().now
        let tools = makeTools(count: 24, schemaUnits: 32)
        let window = makeWindow(
            tools: tools,
            toolPlan: .allowAll,
            history: makeHistoryTurns(count: 18, tokenCount: 70, timestamp: timestamp),
            retrieval: makeSlices(count: 10, tokenCount: 60, source: .retrieval, timestamp: timestamp),
            timestamp: timestamp,
            modelProfile: .foundationModels4K
        )

        let iterations = 120
        var signatures: [[Int]] = []

        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0 ..< iterations {
            let budget = ContextBudget(totalTokens: 4_096, profile: .foundationModels4K)
            let result = try await allocator.process(window, budget: budget)
            let allocated = BucketID.allCases.map { result.budget.allocated(for: $0) }
            signatures.append(allocated)

            #expect(result.budget.totalAllocated <= result.budget.totalTokens)
            for bucket in BucketID.allCases {
                #expect(result.budget.allocated(for: bucket) <= result.budget.ceiling(for: bucket))
                #expect(result.budget.remaining(for: bucket) == max(result.budget.ceiling(for: bucket) - result.budget.allocated(for: bucket), 0))
            }
        }
        let elapsed = start.duration(to: clock.now)

        let first = try #require(signatures.first)
        for signature in signatures.dropFirst() {
            #expect(signature == first)
        }
        #expect(elapsed >= .zero)
    }

    @Test func pointerCreationResolutionOverhead() async throws {
        let store = InMemoryPointerStore()
        let resolver = PointerResolver(store: store, config: .init(pointerThresholdBytes: 64, summaryMaxChars: 120))

        let pointerPayload = String(repeating: "pointer-payload-benchmark ", count: 128)
        let inlinePayload = "ok"
        let iterations = 100

        let clock = ContinuousClock()

        var pointerIDs: [String] = []
        let pointerStart = clock.now
        for _ in 0 ..< iterations {
            let decision = try await resolver.pointerizeIfNeeded(toolName: "bench_tool", output: pointerPayload)
            guard case let .pointer(pointer, replacementText) = decision else {
                #expect(Bool(false), "Expected pointerized output for large payload")
                return
            }
            #expect(replacementText.contains(pointer.id))
            pointerIDs.append(pointer.id)

            let resolved = try await store.resolve(pointerID: pointer.id)
            #expect(String(decoding: resolved, as: UTF8.self) == pointerPayload)
        }
        let pointerElapsed = pointerStart.duration(to: clock.now)

        let inlineStart = clock.now
        for _ in 0 ..< iterations {
            let decision = try await resolver.pointerizeIfNeeded(toolName: "bench_tool", output: inlinePayload)
            guard case .inline(let output) = decision else {
                #expect(Bool(false), "Expected inline output for small payload")
                return
            }
            #expect(output == inlinePayload)
        }
        let inlineElapsed = inlineStart.duration(to: clock.now)

        #expect(Set(pointerIDs).count == 1)
        #expect(pointerElapsed >= .zero)
        #expect(inlineElapsed >= .zero)
    }

    @Test func fullFiveStagePipelineLatencySmoke() async throws {
        let timestamp = ContinuousClock().now
        let request = ContextRequest(
            userInput: "latency smoke",
            tools: makeTools(count: 20, schemaUnits: 24),
            toolPlan: .allowAll,
            history: makeHistoryTurns(count: 24, tokenCount: 80, timestamp: timestamp),
            memories: makeSlices(count: 8, tokenCount: 40, source: .memory, timestamp: timestamp),
            retrieval: makeSlices(count: 6, tokenCount: 50, source: .retrieval, timestamp: timestamp),
            pointers: []
        )

        let (firstPlanned, firstElapsed) = try await measure {
            let pipeline = makeLatencySmokePipeline(timestamp: timestamp)
            return try await pipeline.prepare(request)
        }

        let (secondPlanned, secondElapsed) = try await measure {
            let pipeline = makeLatencySmokePipeline(timestamp: timestamp)
            return try await pipeline.prepare(request)
        }

        #expect(firstPlanned.prompt == "latency-smoke-emit")
        #expect(secondPlanned.prompt == firstPlanned.prompt)
        #expect(secondPlanned.systemPrompt == firstPlanned.systemPrompt)
        #expect(secondPlanned.toolPlan == firstPlanned.toolPlan)
        #expect(secondPlanned.budget.totalAllocated == firstPlanned.budget.totalAllocated)
        #expect(firstPlanned.budget.totalAllocated <= firstPlanned.budget.totalTokens)
        #expect(firstElapsed >= .zero)
        #expect(secondElapsed >= .zero)
    }
}

private actor BenchmarkIntakeStage: IntakeStage {
    let timestamp: ContinuousClock.Instant

    init(timestamp: ContinuousClock.Instant) {
        self.timestamp = timestamp
    }

    func process(_ input: ContextRequest, budget _: ContextBudget) async throws -> ContextWindow {
        let plan = JITToolLoader(jitMinToolCount: 10).plan(tools: input.tools, existingPlan: input.toolPlan)

        return makeWindow(
            tools: input.tools,
            toolPlan: plan,
            history: input.history,
            retrieval: input.retrieval,
            memory: input.memories,
            pointers: input.pointers,
            timestamp: timestamp,
            modelProfile: .openModel8K
        )
    }
}

private actor BenchmarkEmitStage: EmitStage {
    func process(_ input: PagedContext, budget: ContextBudget) async throws -> PlannedRequest {
        PlannedRequest(
            prompt: "latency-smoke-emit",
            systemPrompt: input.window.systemPrompt.content,
            toolPlan: input.window.toolPlan,
            budget: budget,
            metadata: input.window.metadata
        )
    }
}

private func makeLatencySmokePipeline(timestamp: ContinuousClock.Instant) -> MembranePipeline {
    MembranePipeline.openModel(
        budget: ContextBudget(totalTokens: 8_192, profile: .openModel8K),
        intake: BenchmarkIntakeStage(timestamp: timestamp),
        allocator: UnifiedBudgetAllocator(),
        compress: CSODistiller(keepRecentTurns: 4),
        page: MemGPTPager(pressureThreshold: 0.85, keepRecentHistoryTurns: 4),
        emit: BenchmarkEmitStage()
    )
}

private func makeTools(count: Int, schemaUnits: Int) -> [ToolManifest] {
    (0 ..< count).map { index in
        let name = String(format: "tool_%03d", index)
        let schema = String(repeating: "field_\(index):string;", count: max(schemaUnits, 1))
        return ToolManifest(name: name, description: "Benchmark tool \(name)", fullSchema: schema)
    }
}

private func materializedToolTokens(for tools: [ToolManifest], under plan: ToolPlan) -> Int {
    let activeTools: [ToolManifest]
    switch plan {
    case .allowAll:
        activeTools = tools
    case let .allowList(toolNames):
        let allowSet = Set(toolNames)
        activeTools = tools.filter { allowSet.contains($0.name) }
    case let .jit(_, loadedToolNames):
        let loadedSet = Set(loadedToolNames)
        activeTools = tools.filter { loadedSet.contains($0.name) }
    }

    return activeTools.reduce(0) { $0 + $1.estimatedTokens }
}

private func makeWindow(
    tools: [ToolManifest],
    toolPlan: ToolPlan,
    history: [ContextSlice],
    retrieval: [ContextSlice],
    memory: [ContextSlice]? = nil,
    pointers: [MemoryPointer] = [],
    timestamp: ContinuousClock.Instant,
    modelProfile: BudgetProfile
) -> ContextWindow {
    ContextWindow(
        systemPrompt: ContextSlice(
            content: "Benchmark system prompt",
            tokenCount: 160,
            importance: 1,
            source: .system,
            tier: .full,
            timestamp: timestamp
        ),
        memory: memory ?? makeSlices(count: 10, tokenCount: 45, source: .memory, timestamp: timestamp),
        tools: tools,
        toolPlan: toolPlan,
        history: history,
        retrieval: retrieval,
        pointers: pointers,
        metadata: ContextMetadata(turnNumber: history.count, sessionID: "benchmark-session", modelProfile: modelProfile)
    )
}

private func makeHistoryTurns(count: Int, tokenCount: Int, timestamp: ContinuousClock.Instant) -> [ContextSlice] {
    makeSlices(count: count, tokenCount: tokenCount, source: .history, timestamp: timestamp)
}

private func makeSlices(
    count: Int,
    tokenCount: Int,
    source: ContextSource,
    timestamp: ContinuousClock.Instant
) -> [ContextSlice] {
    (0 ..< count).map { index in
        ContextSlice(
            content: "\(source.rawValue)-slice-\(index)",
            tokenCount: tokenCount,
            importance: 0.5 + (Double((index % 5)) * 0.05),
            source: source,
            tier: .full,
            timestamp: timestamp
        )
    }
}

private func measure<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
) async rethrows -> (T, Duration) {
    let clock = ContinuousClock()
    let start = clock.now
    let value = try await operation()
    return (value, start.duration(to: clock.now))
}
