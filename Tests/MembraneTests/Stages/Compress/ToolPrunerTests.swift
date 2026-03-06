import Testing
@testable import Membrane
@testable import MembraneCore

@Suite struct ToolPrunerTests {
    @Test func prunesToTopKAfterTurnThreshold() {
        let pruner = ToolPruner(pruneAfterTurn: 3, keepTopK: 2)
        let tools = [
            ToolManifest(name: "a", description: "A"),
            ToolManifest(name: "b", description: "B"),
            ToolManifest(name: "c", description: "C"),
        ]

        let plan = pruner.prune(
            availableTools: tools,
            existingPlan: .allowAll,
            usageCountByToolName: ["a": 10, "c": 5, "b": 0],
            currentTurn: 4
        )

        #expect(plan == ToolPlan.allowList(normalized:["a", "c"]))
    }

    @Test func doesNotPruneBeforeThreshold() {
        let pruner = ToolPruner(pruneAfterTurn: 3, keepTopK: 1)
        let tools = [ToolManifest(name: "a", description: "A")]

        let plan = pruner.prune(
            availableTools: tools,
            existingPlan: .allowAll,
            usageCountByToolName: ["a": 1],
            currentTurn: 2
        )

        #expect(plan == .allowAll)
    }

    @Test func jitModeBypassesPruning() {
        let pruner = ToolPruner(pruneAfterTurn: 1, keepTopK: 0)
        let tools = (0..<20).map { ToolManifest(name: "tool_\($0)", description: "Tool \($0)") }
        let existing = ToolPlan.jit(normalized: [], loaded: ["tool_2"])

        let plan = pruner.prune(
            availableTools: tools,
            existingPlan: existing,
            usageCountByToolName: [:],
            currentTurn: 99
        )

        #expect(plan == existing)
    }

    @Test func deterministicTieBreakUsesToolNameAscending() {
        let pruner = ToolPruner(pruneAfterTurn: 0, keepTopK: 2)
        let tools = [
            ToolManifest(name: "zeta", description: "Z"),
            ToolManifest(name: "alpha", description: "A"),
            ToolManifest(name: "beta", description: "B"),
        ]

        let plan = pruner.prune(
            availableTools: tools,
            existingPlan: .allowAll,
            usageCountByToolName: ["zeta": 5, "alpha": 5, "beta": 5],
            currentTurn: 0
        )

        #expect(plan == ToolPlan.allowList(normalized:["alpha", "beta"]))
    }
}
