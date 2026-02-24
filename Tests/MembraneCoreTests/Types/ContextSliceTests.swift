import Testing
@testable import MembraneCore

@Suite struct ContextSliceTests {
    @Test func sliceTracksTokenCount() {
        let slice = ContextSlice(
            content: "Hello world",
            tokenCount: 3,
            importance: 0.8,
            source: .history,
            tier: .full,
            timestamp: .now
        )
        #expect(slice.tokenCount == 3)
        #expect(slice.importance == 0.8)
        #expect(slice.source == .history)
        #expect(slice.tier == .full)
    }

    @Test func sliceComparableByImportance() {
        let high = ContextSlice(
            content: "important",
            tokenCount: 5,
            importance: 0.9,
            source: .memory,
            tier: .full,
            timestamp: .now
        )
        let low = ContextSlice(
            content: "trivial",
            tokenCount: 3,
            importance: 0.2,
            source: .history,
            tier: .micro,
            timestamp: .now
        )

        #expect(high.importance > low.importance)
    }

    @Test func memoryPointerIdentityHashing() {
        let first = MemoryPointer(
            id: "ptr_a1b2c3",
            dataType: .document,
            byteSize: 250_000,
            summary: "250KB code listing, 3400 lines"
        )
        let second = MemoryPointer(
            id: "ptr_a1b2c3",
            dataType: .document,
            byteSize: 250_000,
            summary: "250KB code listing, 3400 lines"
        )

        #expect(first == second)
        #expect(Set([first, second]).count == 1)
    }

    @Test func compressionTiersOrdered() {
        #expect(CompressionTier.full.tokenBudgetMultiplier > CompressionTier.gist.tokenBudgetMultiplier)
        #expect(CompressionTier.gist.tokenBudgetMultiplier > CompressionTier.micro.tokenBudgetMultiplier)
    }
}
