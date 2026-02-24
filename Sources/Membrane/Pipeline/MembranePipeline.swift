import MembraneCore

public actor MembranePipeline {
    private let baseBudget: ContextBudget
    private let intakeStage: (any IntakeStage)?
    private let budgetStage: (any BudgetStage)?
    private let compressStage: (any CompressStage)?
    private let pageStage: (any PageStage)?
    private let emitStage: (any EmitStage)?
    private let includePageAndEmit: Bool

    public init(
        budget: ContextBudget,
        intake: (any IntakeStage)? = nil,
        budgetStage: (any BudgetStage)? = nil,
        compress: (any CompressStage)? = nil,
        page: (any PageStage)? = nil,
        emit: (any EmitStage)? = nil,
        includePageAndEmit: Bool = true
    ) {
        self.baseBudget = budget
        self.intakeStage = intake
        self.budgetStage = budgetStage
        self.compressStage = compress
        self.pageStage = page
        self.emitStage = emit
        self.includePageAndEmit = includePageAndEmit
    }

    public static func foundationModels(
        budget: ContextBudget = ContextBudget(totalTokens: 4096, profile: .foundationModels4K),
        intake: (any IntakeStage)? = nil,
        budgetStage: (any BudgetStage)? = nil,
        compress: (any CompressStage)? = nil,
        page: (any PageStage)? = nil,
        emit: (any EmitStage)? = nil
    ) -> MembranePipeline {
        MembranePipeline(
            budget: budget,
            intake: intake,
            budgetStage: budgetStage,
            compress: compress,
            page: page,
            emit: emit,
            includePageAndEmit: false
        )
    }

    public static func openModel(
        budget: ContextBudget,
        intake: (any IntakeStage)? = nil,
        budgetStage: (any BudgetStage)? = nil,
        compress: (any CompressStage)? = nil,
        page: (any PageStage)? = nil,
        emit: (any EmitStage)? = nil
    ) -> MembranePipeline {
        MembranePipeline(
            budget: budget,
            intake: intake,
            budgetStage: budgetStage,
            compress: compress,
            page: page,
            emit: emit,
            includePageAndEmit: true
        )
    }

    public func prepare(_ request: ContextRequest) async throws -> PlannedRequest {
        var budget = baseBudget

        var window = ContextWindow(
            systemPrompt: ContextSlice(
                content: "",
                tokenCount: 0,
                importance: 1.0,
                source: .system,
                tier: .full,
                timestamp: .now
            ),
            memory: request.memories,
            tools: request.tools,
            toolPlan: request.toolPlan,
            history: request.history,
            retrieval: request.retrieval,
            pointers: request.pointers,
            metadata: ContextMetadata(modelProfile: .foundationModels4K)
        )

        if let intakeStage {
            window = try await intakeStage.process(request, budget: budget)
        }

        var budgeted = BudgetedContext(window: window, budget: budget)
        if let budgetStage {
            budgeted = try await budgetStage.process(budgeted.window, budget: budgeted.budget)
        }
        budget = budgeted.budget

        var compressed = CompressedContext(
            window: budgeted.window,
            budget: budgeted.budget,
            compressionReport: CompressionReport(
                originalTokens: budgeted.window.totalTokenCount,
                compressedTokens: budgeted.window.totalTokenCount,
                techniquesApplied: []
            )
        )
        if let compressStage {
            compressed = try await compressStage.process(
                BudgetedContext(window: compressed.window, budget: compressed.budget),
                budget: compressed.budget
            )
        }
        budget = compressed.budget

        var paged = PagedContext(window: compressed.window, budget: compressed.budget, pagedOut: [])
        if includePageAndEmit, let pageStage {
            paged = try await pageStage.process(
                CompressedContext(
                    window: paged.window,
                    budget: paged.budget,
                    compressionReport: compressed.compressionReport
                ),
                budget: paged.budget
            )
        }
        budget = paged.budget

        var plannedRequest = PlannedRequest(
            prompt: request.userInput,
            systemPrompt: paged.window.systemPrompt.content,
            toolPlan: paged.window.toolPlan,
            budget: budget,
            metadata: paged.window.metadata
        )
        if includePageAndEmit, let emitStage {
            plannedRequest = try await emitStage.process(paged, budget: budget)
        }

        return plannedRequest
    }
}
