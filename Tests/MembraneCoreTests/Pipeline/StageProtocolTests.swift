import Testing
@testable import MembraneCore

actor MockIntakeStage: IntakeStage {
    func process(_ input: ContextRequest, budget: ContextBudget) async throws -> ContextWindow {
        ContextWindow(
            systemPrompt: ContextSlice(
                content: "system",
                tokenCount: 10,
                importance: 1.0,
                source: .system,
                tier: .full,
                timestamp: .now
            ),
            memory: [],
            tools: input.tools,
            toolPlan: input.toolPlan,
            history: input.history,
            retrieval: input.retrieval,
            pointers: input.pointers,
            metadata: ContextMetadata()
        )
    }
}

@Suite struct StageProtocolTests {
    @Test func intakeStageConformsToProtocol() async throws {
        let stage = MockIntakeStage()
        let request = ContextRequest(userInput: "Hello", tools: [], history: [], memories: [])
        let budget = ContextBudget(totalTokens: 4096, profile: .foundationModels4K)

        let result = try await stage.process(request, budget: budget)
        #expect(result.systemPrompt.content == "system")
    }

    @Test func contextWindowHasAllSlots() {
        let window = ContextWindow(
            systemPrompt: ContextSlice(
                content: "sys",
                tokenCount: 5,
                importance: 1.0,
                source: .system,
                tier: .full,
                timestamp: .now
            ),
            memory: [],
            tools: [ToolManifest(name: "read_file", description: "Read a file", fullSchema: nil)],
            toolPlan: .allowAll,
            history: [],
            retrieval: [],
            pointers: [],
            metadata: ContextMetadata()
        )

        #expect(window.tools.count == 1)
        #expect(window.tools[0].name == "read_file")
        #expect(window.tools[0].fullSchema == nil)
    }

    @Test func contextWindowTotalTokens() {
        let window = ContextWindow(
            systemPrompt: ContextSlice(
                content: "sys",
                tokenCount: 100,
                importance: 1.0,
                source: .system,
                tier: .full,
                timestamp: .now
            ),
            memory: [ContextSlice(
                content: "mem",
                tokenCount: 50,
                importance: 0.5,
                source: .memory,
                tier: .gist,
                timestamp: .now
            )],
            tools: [],
            toolPlan: .allowAll,
            history: [ContextSlice(
                content: "hist",
                tokenCount: 200,
                importance: 0.7,
                source: .history,
                tier: .full,
                timestamp: .now
            )],
            retrieval: [],
            pointers: [],
            metadata: ContextMetadata()
        )

        #expect(window.totalTokenCount == 350)
    }

    @Test func toolPlanNormalizationIsDeterministic() {
        let allowList = ToolPlan.allowList(normalized: ["zeta", "alpha", "alpha", "beta"])
        if case .allowList(let tools) = allowList {
            #expect(tools == ["alpha", "beta", "zeta"])
        } else {
            #expect(Bool(false))
        }

        let jit = ToolPlan.jit(
            normalized: [
                ToolIndexEntry(name: "b", description: "B"),
                ToolIndexEntry(name: "a", description: "A"),
            ],
            loaded: ["z", "a", "a"]
        )

        if case .jit(let index, let loadedToolNames) = jit {
            #expect(index.map(\.name) == ["a", "b"])
            #expect(loadedToolNames == ["a", "z"])
        } else {
            #expect(Bool(false))
        }
    }
}
