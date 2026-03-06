import Testing
@testable import Membrane
@testable import MembraneCore

@Suite struct JITToolLoaderTests {
    @Test func enablesJITWhenToolCountMeetsThreshold() {
        let loader = JITToolLoader(jitMinToolCount: 10)
        let tools = (0..<20).map { ToolManifest(name: "tool_\($0)", description: "Tool \($0)") }

        let plan = loader.plan(tools: tools, existingPlan: .allowAll)

        guard case let .jit(index, loadedToolNames) = plan else {
            #expect(Bool(false), "Expected .jit tool plan")
            return
        }

        #expect(index.count == 20)
        #expect(loadedToolNames.isEmpty)
        #expect(index.map(\.name) == index.map(\.name).sorted())
    }

    @Test func staysAllowAllWhenToolCountIsSmall() {
        let loader = JITToolLoader(jitMinToolCount: 10)
        let tools = (0..<3).map { ToolManifest(name: "tool_\($0)", description: "Tool \($0)") }

        let plan = loader.plan(tools: tools, existingPlan: .allowAll)

        #expect(plan == .allowAll)
    }

    @Test func preservesLoadedToolNamesAcrossTurns() {
        let loader = JITToolLoader(jitMinToolCount: 10)
        let tools = (0..<20).map { ToolManifest(name: "tool_\($0)", description: "Tool \($0)") }
        let existing = ToolPlan.jit(normalized: [], loaded: ["tool_9", "tool_2"])

        let plan = loader.plan(tools: tools, existingPlan: existing)

        guard case let .jit(_, loadedToolNames) = plan else {
            #expect(Bool(false), "Expected .jit tool plan")
            return
        }

        #expect(loadedToolNames == ["tool_2", "tool_9"])
    }

    @Test func strict4kLargeToolSetPlanningIsDeterministic() {
        let loader = JITToolLoader(jitMinToolCount: 10)
        let base = (0..<30).map { index in
            ToolManifest(name: "tool_\(String(index))", description: "Desc \(index)")
        }

        let firstInput = Array(base.enumerated().map(\.element).reversed())
        let secondInput = base.indices.map { base[(($0 * 7) + 3) % base.count] }

        let first = loader.plan(tools: firstInput, existingPlan: .allowAll)
        let second = loader.plan(tools: secondInput, existingPlan: .allowAll)

        guard case let .jit(firstIndex, _) = first,
              case let .jit(secondIndex, _) = second else {
            #expect(Bool(false), "Expected .jit tool plan")
            return
        }

        #expect(firstIndex.count == 30)
        #expect(secondIndex.count == 30)
        #expect(firstIndex == secondIndex)
    }
}
