import Testing
@testable import Membrane
@testable import MembraneCore

@Suite struct RAPTORRetrieverTests {
    actor FakeRAPTORIndex: RAPTORIndex {
        let nodes: [RAPTORNode]
        private var requestedTopKs: [Int] = []

        init(nodes: [RAPTORNode]) {
            self.nodes = nodes
        }

        func search(query _: String, topK: Int) async throws -> [RAPTORNode] {
            requestedTopKs.append(topK)
            return Array(nodes.prefix(max(0, topK)))
        }

        func lastRequestedTopK() -> Int? {
            requestedTopKs.last
        }
    }

    @Test func respectsRetrievalBudgetCeiling() async throws {
        let index = FakeRAPTORIndex(nodes: [
            RAPTORNode(id: "n1", parentID: nil, depth: 0, text: "A", tokenCount: 60),
            RAPTORNode(id: "n2", parentID: "n1", depth: 1, text: "B", tokenCount: 60),
        ])
        let retriever = RAPTORRetriever(index: index, topK: 10)
        let budget = ContextBudget(totalTokens: 4_096, profile: .custom(buckets: [
            .retrieval: 90,
        ]))

        let slices = try await retriever.retrieve(query: "q", budget: budget)

        #expect(slices.count == 1)
        #expect(slices[0].content == "A")
        #expect(slices.reduce(0) { $0 + $1.tokenCount } <= 90)
    }

    @Test func deterministicSelectionUsesDepthThenIDOrdering() async throws {
        let firstIndex = FakeRAPTORIndex(nodes: [
            RAPTORNode(id: "b", parentID: nil, depth: 1, text: "B", tokenCount: 20),
            RAPTORNode(id: "c", parentID: nil, depth: 0, text: "C", tokenCount: 20),
            RAPTORNode(id: "a", parentID: nil, depth: 1, text: "A", tokenCount: 20),
        ])
        let secondIndex = FakeRAPTORIndex(nodes: [
            RAPTORNode(id: "a", parentID: nil, depth: 1, text: "A", tokenCount: 20),
            RAPTORNode(id: "b", parentID: nil, depth: 1, text: "B", tokenCount: 20),
            RAPTORNode(id: "c", parentID: nil, depth: 0, text: "C", tokenCount: 20),
        ])
        let budget = ContextBudget(totalTokens: 4_096, profile: .custom(buckets: [
            .retrieval: 120,
        ]))

        let firstRetriever = RAPTORRetriever(index: firstIndex, topK: 10)
        let secondRetriever = RAPTORRetriever(index: secondIndex, topK: 10)

        let first = try await firstRetriever.retrieve(query: "deterministic", budget: budget)
        let second = try await secondRetriever.retrieve(query: "deterministic", budget: budget)

        #expect(first.map(\.content) == ["C", "A", "B"])
        #expect(first.map(\.content) == second.map(\.content))
        #expect(first.map(\.tokenCount) == second.map(\.tokenCount))
    }

    @Test func stopsWhenNextNodeWouldExceedRemainingBudget() async throws {
        let index = FakeRAPTORIndex(nodes: [
            RAPTORNode(id: "a", parentID: nil, depth: 0, text: "first", tokenCount: 40),
            RAPTORNode(id: "b", parentID: "a", depth: 1, text: "too-big", tokenCount: 70),
            RAPTORNode(id: "c", parentID: "a", depth: 2, text: "would-fit-if-skipped", tokenCount: 20),
        ])
        let retriever = RAPTORRetriever(index: index, topK: 10)
        let budget = ContextBudget(totalTokens: 4_096, profile: .custom(buckets: [
            .retrieval: 90,
        ]))

        let slices = try await retriever.retrieve(query: "budget-stop", budget: budget)

        #expect(slices.map(\.content) == ["first"])
        #expect(slices.reduce(0) { $0 + $1.tokenCount } == 40)
    }

    @Test func forwardsTopKToIndexAndHandlesZeroBudget() async throws {
        let index = FakeRAPTORIndex(nodes: [
            RAPTORNode(id: "n1", parentID: nil, depth: 0, text: "A", tokenCount: 10)
        ])
        let retriever = RAPTORRetriever(index: index, topK: 3)
        let budget = ContextBudget(totalTokens: 4_096, profile: .custom(buckets: [
            .retrieval: 0,
        ]))

        let slices = try await retriever.retrieve(query: "no-budget", budget: budget)
        let requestedTopK = await index.lastRequestedTopK()

        #expect(slices.isEmpty)
        #expect(requestedTopK == 3)
    }
}
