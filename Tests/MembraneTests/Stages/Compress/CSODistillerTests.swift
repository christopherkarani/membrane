import Testing
@testable import Membrane
@testable import MembraneCore

@Suite struct CSODistillerTests {
    @Test func distillsMultiTurnHistory() async throws {
        let distiller = CSODistiller()
        let history = (0..<20).map { index in
            ContextSlice(
                content: "Turn \(index): User asked about topic_\(index % 5). Assistant discussed entity_\(index % 3).",
                tokenCount: 50,
                importance: Double(20 - index) / 20.0,
                source: .history,
                tier: .full,
                timestamp: .now
            )
        }

        let budgeted = BudgetedContext(
            window: ContextWindow(
                systemPrompt: ContextSlice(
                    content: "",
                    tokenCount: 0,
                    importance: 1.0,
                    source: .system,
                    tier: .full,
                    timestamp: .now
                ),
                memory: [],
                tools: [],
                toolPlan: .allowAll,
                history: history,
                retrieval: [],
                pointers: [],
                metadata: ContextMetadata(turnNumber: 20)
            ),
            budget: ContextBudget(totalTokens: 4096, profile: .foundationModels4K)
        )

        let result = try await distiller.process(budgeted, budget: budgeted.budget)
        let csoTokens = result.window.history.reduce(0) { $0 + $1.tokenCount }
        let rawTokens = history.reduce(0) { $0 + $1.tokenCount }

        #expect(csoTokens < rawTokens)
        #expect(result.compressionReport.techniquesApplied.contains("CSO"))
    }

    @Test func preservesRecentTurns() async throws {
        let distiller = CSODistiller(keepRecentTurns: 3)
        let history = (0..<10).map { index in
            ContextSlice(
                content: "Turn \(index) content",
                tokenCount: 50,
                importance: 0.5,
                source: .history,
                tier: .full,
                timestamp: .now
            )
        }

        let budgeted = BudgetedContext(
            window: ContextWindow(
                systemPrompt: ContextSlice(
                    content: "",
                    tokenCount: 0,
                    importance: 1.0,
                    source: .system,
                    tier: .full,
                    timestamp: .now
                ),
                memory: [],
                tools: [],
                toolPlan: .allowAll,
                history: history,
                retrieval: [],
                pointers: [],
                metadata: ContextMetadata(turnNumber: 10)
            ),
            budget: ContextBudget(totalTokens: 4096, profile: .foundationModels4K)
        )

        let result = try await distiller.process(budgeted, budget: budgeted.budget)
        let retained = result.window.history.suffix(3).map(\.content)

        #expect(retained == ["Turn 7 content", "Turn 8 content", "Turn 9 content"])
        #expect(result.window.history.filter { $0.tier == .full }.count >= 3)
    }

    @Test func csoOutputIsBounded() async {
        let distiller = CSODistiller()
        let turns = (0..<250).map { index in
            "User asked Question \(index)? Assistant decided to use Strategy\(index)."
        }

        let cso = await distiller.distill(turns: turns)

        #expect(cso.entities.count <= 50)
        #expect(cso.decisions.count <= 20)
        #expect(cso.openQuestions.count <= 10)
        #expect(cso.keyFacts.count <= 30)
    }

    @Test func distillationIsDeterministicAcrossRuns() async throws {
        let history = (0..<12).map { index in
            ContextSlice(
                content: "Turn \(index): User asked about Paris and NYC? Assistant decided to use weather_api.",
                tokenCount: 60,
                importance: 0.8,
                source: .history,
                tier: .full,
                timestamp: .now
            )
        }

        func runDistillation() async throws -> CompressedContext {
            let distiller = CSODistiller(keepRecentTurns: 2)
            let budgeted = BudgetedContext(
                window: ContextWindow(
                    systemPrompt: ContextSlice(
                        content: "",
                        tokenCount: 0,
                        importance: 1.0,
                        source: .system,
                        tier: .full,
                        timestamp: .now
                    ),
                    memory: [],
                    tools: [],
                    toolPlan: .allowAll,
                    history: history,
                    retrieval: [],
                    pointers: [],
                    metadata: ContextMetadata(turnNumber: 12)
                ),
                budget: ContextBudget(totalTokens: 4096, profile: .foundationModels4K)
            )
            return try await distiller.process(budgeted, budget: budgeted.budget)
        }

        let first = try await runDistillation()
        let second = try await runDistillation()

        #expect(first.window.history.map(\.content) == second.window.history.map(\.content))
        #expect(first.window.history.map(\.tokenCount) == second.window.history.map(\.tokenCount))
        #expect(first.compressionReport.compressedTokens == second.compressionReport.compressedTokens)
    }
}
