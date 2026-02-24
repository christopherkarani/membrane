import Testing
@testable import Membrane
@testable import MembraneCore

actor StageTrace {
    private(set) var names: [String] = []

    func append(_ name: String) {
        names.append(name)
    }

    func snapshot() -> [String] {
        names
    }
}

actor TraceIntakeStage: IntakeStage {
    let trace: StageTrace

    init(trace: StageTrace) {
        self.trace = trace
    }

    func process(_ input: ContextRequest, budget: ContextBudget) async throws -> ContextWindow {
        await trace.append("intake")
        return ContextWindow(
            systemPrompt: ContextSlice(
                content: "system",
                tokenCount: 10,
                importance: 1.0,
                source: .system,
                tier: .full,
                timestamp: .now
            ),
            memory: input.memories,
            tools: input.tools,
            toolPlan: input.toolPlan,
            history: input.history,
            retrieval: input.retrieval,
            pointers: input.pointers,
            metadata: ContextMetadata()
        )
    }
}

actor TraceBudgetStage: BudgetStage {
    let trace: StageTrace

    init(trace: StageTrace) {
        self.trace = trace
    }

    func process(_ input: ContextWindow, budget: ContextBudget) async throws -> BudgetedContext {
        await trace.append("budget")
        return BudgetedContext(window: input, budget: budget)
    }
}

actor TraceCompressStage: CompressStage {
    let trace: StageTrace

    init(trace: StageTrace) {
        self.trace = trace
    }

    func process(_ input: BudgetedContext, budget: ContextBudget) async throws -> CompressedContext {
        await trace.append("compress")
        return CompressedContext(
            window: input.window,
            budget: budget,
            compressionReport: CompressionReport(
                originalTokens: input.window.totalTokenCount,
                compressedTokens: input.window.totalTokenCount,
                techniquesApplied: []
            )
        )
    }
}

actor TracePageStage: PageStage {
    let trace: StageTrace

    init(trace: StageTrace) {
        self.trace = trace
    }

    func process(_ input: CompressedContext, budget: ContextBudget) async throws -> PagedContext {
        await trace.append("page")
        return PagedContext(window: input.window, budget: budget, pagedOut: [])
    }
}

actor TraceEmitStage: EmitStage {
    let trace: StageTrace

    init(trace: StageTrace) {
        self.trace = trace
    }

    func process(_ input: PagedContext, budget: ContextBudget) async throws -> PlannedRequest {
        await trace.append("emit")
        return PlannedRequest(
            prompt: "emitted",
            systemPrompt: input.window.systemPrompt.content,
            toolPlan: input.window.toolPlan,
            budget: budget,
            metadata: input.window.metadata
        )
    }
}

@Suite struct MembranePipelineTests {
    @Test func pipelineRunsCanonicalStageOrder() async throws {
        let trace = StageTrace()
        let pipeline = MembranePipeline(
            budget: ContextBudget(totalTokens: 4096, profile: .foundationModels4K),
            intake: TraceIntakeStage(trace: trace),
            budgetStage: TraceBudgetStage(trace: trace),
            compress: TraceCompressStage(trace: trace),
            page: TracePageStage(trace: trace),
            emit: TraceEmitStage(trace: trace)
        )

        _ = try await pipeline.prepare(ContextRequest(userInput: "Hello"))
        let order = await trace.snapshot()
        #expect(order == ["intake", "budget", "compress", "page", "emit"])
    }

    @Test func foundationModelsProfileSkipsPageAndEmit() async throws {
        let trace = StageTrace()
        let pipeline = MembranePipeline.foundationModels(
            intake: TraceIntakeStage(trace: trace),
            budgetStage: TraceBudgetStage(trace: trace),
            compress: TraceCompressStage(trace: trace),
            page: TracePageStage(trace: trace),
            emit: TraceEmitStage(trace: trace)
        )

        _ = try await pipeline.prepare(ContextRequest(userInput: "Hello"))
        let order = await trace.snapshot()
        #expect(order == ["intake", "budget", "compress"])
    }

    @Test func openModelProfileRunsAllStages() async throws {
        let trace = StageTrace()
        let pipeline = MembranePipeline.openModel(
            budget: ContextBudget(totalTokens: 8192, profile: .openModel8K),
            intake: TraceIntakeStage(trace: trace),
            budgetStage: TraceBudgetStage(trace: trace),
            compress: TraceCompressStage(trace: trace),
            page: TracePageStage(trace: trace),
            emit: TraceEmitStage(trace: trace)
        )

        _ = try await pipeline.prepare(ContextRequest(userInput: "Hello"))
        let order = await trace.snapshot()
        #expect(order == ["intake", "budget", "compress", "page", "emit"])
    }

    @Test func repeatedRunsAreDeterministic() async throws {
        func runOnce() async throws -> [String] {
            let trace = StageTrace()
            let pipeline = MembranePipeline.openModel(
                budget: ContextBudget(totalTokens: 8192, profile: .openModel8K),
                intake: TraceIntakeStage(trace: trace),
                budgetStage: TraceBudgetStage(trace: trace),
                compress: TraceCompressStage(trace: trace),
                page: TracePageStage(trace: trace),
                emit: TraceEmitStage(trace: trace)
            )
            _ = try await pipeline.prepare(ContextRequest(userInput: "Hello"))
            return await trace.snapshot()
        }

        let first = try await runOnce()
        let second = try await runOnce()

        #expect(first == second)
    }
}
