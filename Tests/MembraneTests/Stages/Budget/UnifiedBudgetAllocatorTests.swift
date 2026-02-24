import Testing
@testable import Membrane
@testable import MembraneCore

@Suite struct UnifiedBudgetAllocatorTests {
    @Test func allocatesBudgetForFM4K() async throws {
        let allocator = UnifiedBudgetAllocator()
        let window = makeTestWindow(
            systemTokens: 200,
            historyTokens: 500,
            toolCount: 10,
            retrievalTokens: 300,
            memoryTokens: 100
        )
        let budget = ContextBudget(totalTokens: 4096, profile: .foundationModels4K)

        let result = try await allocator.process(window, budget: budget)

        #expect(result.budget.totalAllocated <= 4096)
        #expect(result.budget.allocated(for: .system) == 200)
    }

    @Test func priorityOrderEnforced() async throws {
        let allocator = UnifiedBudgetAllocator()
        let window = makeTestWindow(
            systemTokens: 400,
            historyTokens: 3000,
            toolCount: 30,
            retrievalTokens: 2000,
            memoryTokens: 500
        )
        let budget = ContextBudget(totalTokens: 4096, profile: .foundationModels4K)

        let result = try await allocator.process(window, budget: budget)

        #expect(result.budget.allocated(for: .system) == 400)
        #expect(result.budget.remaining(for: .outputReserve) == result.budget.ceiling(for: .outputReserve))
    }

    @Test func overloadDemandGetsTrimmedToCeilings() async throws {
        let allocator = UnifiedBudgetAllocator()
        let window = makeTestWindow(
            systemTokens: 700,
            historyTokens: 10_000,
            toolCount: 150,
            retrievalTokens: 10_000,
            memoryTokens: 10_000
        )
        let budget = ContextBudget(totalTokens: 4096, profile: .foundationModels4K)

        let result = try await allocator.process(window, budget: budget)

        #expect(result.budget.allocated(for: .system) == result.budget.ceiling(for: .system))
        #expect(result.budget.allocated(for: .history) <= result.budget.ceiling(for: .history))
        #expect(result.budget.allocated(for: .tools) <= result.budget.ceiling(for: .tools))
        #expect(result.budget.allocated(for: .retrieval) <= result.budget.ceiling(for: .retrieval))
        #expect(result.budget.allocated(for: .memory) <= result.budget.ceiling(for: .memory))
    }

    @Test func deterministicTieBreakBehavior() async throws {
        let allocator = UnifiedBudgetAllocator()
        let window = makeTestWindow(
            systemTokens: 250,
            historyTokens: 800,
            toolCount: 18,
            retrievalTokens: 950,
            memoryTokens: 310
        )
        let budget = ContextBudget(totalTokens: 4096, profile: .foundationModels4K)

        let first = try await allocator.process(window, budget: budget)
        let second = try await allocator.process(window, budget: budget)

        #expect(first.budget.totalAllocated == second.budget.totalAllocated)
        #expect(first.budget.allocated(for: .history) == second.budget.allocated(for: .history))
        #expect(first.budget.allocated(for: .tools) == second.budget.allocated(for: .tools))
        #expect(first.budget.allocated(for: .retrieval) == second.budget.allocated(for: .retrieval))
        #expect(first.budget.allocated(for: .memory) == second.budget.allocated(for: .memory))
    }

    private func makeTestWindow(
        systemTokens: Int,
        historyTokens: Int,
        toolCount: Int,
        retrievalTokens: Int,
        memoryTokens: Int
    ) -> ContextWindow {
        ContextWindow(
            systemPrompt: ContextSlice(
                content: "sys",
                tokenCount: systemTokens,
                importance: 1.0,
                source: .system,
                tier: .full,
                timestamp: .now
            ),
            memory: [ContextSlice(
                content: "mem",
                tokenCount: memoryTokens,
                importance: 0.6,
                source: .memory,
                tier: .gist,
                timestamp: .now
            )],
            tools: (0..<toolCount).map { index in
                ToolManifest(name: "tool_\(index)", description: "Tool \(index)")
            },
            toolPlan: .allowAll,
            history: [ContextSlice(
                content: "history",
                tokenCount: historyTokens,
                importance: 0.7,
                source: .history,
                tier: .full,
                timestamp: .now
            )],
            retrieval: [ContextSlice(
                content: "retrieval",
                tokenCount: retrievalTokens,
                importance: 0.7,
                source: .retrieval,
                tier: .full,
                timestamp: .now
            )],
            pointers: [],
            metadata: ContextMetadata()
        )
    }
}
