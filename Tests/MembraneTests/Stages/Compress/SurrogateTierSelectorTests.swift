import Testing
@testable import Membrane
@testable import MembraneCore

@Suite struct SurrogateTierSelectorTests {
    @Test func selectsHighestFidelityTierThatFitsBudget() {
        let selector = SurrogateTierSelector()
        let candidates = [
            makeCandidate(
                id: "a",
                accessFrequency: 10,
                recencyScore: 0.9,
                relevanceScore: 0.9,
                fullTokens: 60,
                gistTokens: 20,
                microTokens: 8
            ),
            makeCandidate(
                id: "b",
                accessFrequency: 1,
                recencyScore: 0.2,
                relevanceScore: 0.3,
                fullTokens: 60,
                gistTokens: 20,
                microTokens: 8
            ),
        ]

        let selected = selector.select(candidates: candidates, retrievalTokenBudget: 80, querySpecificity: 0.9)

        #expect(selected.count == 2)
        #expect(selected[0].tier == .full)
        #expect(selected.reduce(0) { $0 + $1.tokenCount } <= 80)
    }

    @Test func broadQueriesPreferGistWhenFullAlsoFits() {
        let selector = SurrogateTierSelector()
        let candidates = [
            makeCandidate(
                id: "a",
                accessFrequency: 10,
                recencyScore: 0.9,
                relevanceScore: 0.9,
                fullTokens: 60,
                gistTokens: 20,
                microTokens: 8
            )
        ]

        let broad = selector.select(candidates: candidates, retrievalTokenBudget: 60, querySpecificity: 0.2)
        let specific = selector.select(candidates: candidates, retrievalTokenBudget: 60, querySpecificity: 0.9)

        #expect(broad.count == 1)
        #expect(specific.count == 1)
        #expect(broad[0].tier == .gist)
        #expect(specific[0].tier == .full)
    }

    @Test func respectsRetrievalTokenBudgetStrictly() {
        let selector = SurrogateTierSelector()
        let candidates = [
            makeCandidate(id: "a", accessFrequency: 10, recencyScore: 0.9, relevanceScore: 0.9, fullTokens: 50, gistTokens: 30, microTokens: 10),
            makeCandidate(id: "b", accessFrequency: 9, recencyScore: 0.8, relevanceScore: 0.8, fullTokens: 50, gistTokens: 30, microTokens: 10),
            makeCandidate(id: "c", accessFrequency: 8, recencyScore: 0.7, relevanceScore: 0.7, fullTokens: 50, gistTokens: 30, microTokens: 10),
        ]

        let selected = selector.select(candidates: candidates, retrievalTokenBudget: 25, querySpecificity: 0.9)

        #expect(selected.count == 2)
        #expect(selected.allSatisfy { $0.tier == .micro })
        #expect(selected.reduce(0) { $0 + $1.tokenCount } <= 25)
    }

    @Test func deterministicTieBreakUsesCandidateID() {
        let selector = SurrogateTierSelector()
        let a = makeCandidate(id: "a", accessFrequency: 1, recencyScore: 0.5, relevanceScore: 0.5, fullTokens: 40, gistTokens: 12, microTokens: 8)
        let b = makeCandidate(id: "b", accessFrequency: 1, recencyScore: 0.5, relevanceScore: 0.5, fullTokens: 40, gistTokens: 12, microTokens: 8)

        let selected = selector.select(candidates: [b, a], retrievalTokenBudget: 20, querySpecificity: 0.1)

        #expect(selected.map(\.content) == ["a-gist", "b-micro"])
    }

    @Test func outputIsStableAcrossInputOrderings() {
        let selector = SurrogateTierSelector()
        let candidates = [
            makeCandidate(id: "a", accessFrequency: 3, recencyScore: 0.7, relevanceScore: 0.9, fullTokens: 30, gistTokens: 14, microTokens: 8),
            makeCandidate(id: "b", accessFrequency: 2, recencyScore: 0.8, relevanceScore: 0.8, fullTokens: 30, gistTokens: 14, microTokens: 8),
            makeCandidate(id: "c", accessFrequency: 1, recencyScore: 0.9, relevanceScore: 0.7, fullTokens: 30, gistTokens: 14, microTokens: 8),
        ]

        let first = selector.select(candidates: candidates, retrievalTokenBudget: 42, querySpecificity: 0.2)
        let second = selector.select(candidates: Array(candidates.reversed()), retrievalTokenBudget: 42, querySpecificity: 0.2)

        #expect(first.map(\.content) == second.map(\.content))
        #expect(first.map(\.tier) == second.map(\.tier))
    }

    private func makeCandidate(
        id: String,
        accessFrequency: Int,
        recencyScore: Double,
        relevanceScore: Double,
        fullTokens: Int,
        gistTokens: Int,
        microTokens: Int
    ) -> SurrogateCandidate {
        SurrogateCandidate(
            id: id,
            accessFrequency: accessFrequency,
            recencyScore: recencyScore,
            relevanceScore: relevanceScore,
            full: ContextSlice(
                content: "\(id)-full",
                tokenCount: fullTokens,
                importance: relevanceScore,
                source: .retrieval,
                tier: .full,
                timestamp: .now
            ),
            gist: ContextSlice(
                content: "\(id)-gist",
                tokenCount: gistTokens,
                importance: relevanceScore,
                source: .retrieval,
                tier: .gist,
                timestamp: .now
            ),
            micro: ContextSlice(
                content: "\(id)-micro",
                tokenCount: microTokens,
                importance: relevanceScore,
                source: .retrieval,
                tier: .micro,
                timestamp: .now
            )
        )
    }
}
