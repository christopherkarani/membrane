import Testing
@testable import MembraneCore

@Suite struct ContextBudgetTests {
    @Test func createsBudgetWithBuckets() {
        let budget = ContextBudget(totalTokens: 4096, profile: .foundationModels4K)
        #expect(budget.totalTokens == 4096)
        #expect(budget.remaining(for: .system) > 0)
        #expect(budget.remaining(for: .outputReserve) > 0)
    }

    @Test func allocateReducesRemaining() throws {
        var budget = ContextBudget(totalTokens: 4096, profile: .foundationModels4K)
        let systemCeiling = budget.ceiling(for: .system)
        try budget.allocate(200, to: .system)
        #expect(budget.remaining(for: .system) == systemCeiling - 200)
    }

    @Test func allocateBeyondCeilingThrows() {
        var budget = ContextBudget(totalTokens: 4096, profile: .foundationModels4K)
        #expect(throws: MembraneError.self) {
            try budget.allocate(10_000, to: .system)
        }
    }

    @Test func totalAllocatedDoesNotExceedTotal() throws {
        var budget = ContextBudget(
            totalTokens: 100,
            profile: .custom(buckets: [.system: 40, .history: 40, .outputReserve: 20])
        )
        try budget.allocate(40, to: .system)
        try budget.allocate(40, to: .history)
        try budget.allocate(20, to: .outputReserve)
        #expect(budget.totalAllocated == 100)
        #expect(budget.totalRemaining == 0)
    }

    @Test func customProfileCannotOverAllocatePastTotal() throws {
        var budget = ContextBudget(
            totalTokens: 100,
            profile: .custom(buckets: [.system: 80, .history: 80])
        )
        try budget.allocate(80, to: .system)
        #expect(throws: MembraneError.self) {
            try budget.allocate(80, to: .history)
        }
    }

    @Test func deterministicAllocationAcrossOrder() throws {
        var first = ContextBudget(totalTokens: 500, profile: .custom(buckets: [.system: 250, .history: 250]))
        var second = ContextBudget(totalTokens: 500, profile: .custom(buckets: [.system: 250, .history: 250]))

        try first.allocate(100, to: .system)
        try first.allocate(140, to: .history)

        try second.allocate(140, to: .history)
        try second.allocate(100, to: .system)

        #expect(first.allocated(for: .system) == second.allocated(for: .system))
        #expect(first.allocated(for: .history) == second.allocated(for: .history))
        #expect(first.totalAllocated == second.totalAllocated)
    }

    @Test func foundationModels4KProfileTotals4096() {
        let budget = ContextBudget(totalTokens: 4096, profile: .foundationModels4K)
        let sum = BucketID.allCases.reduce(0) { partial, bucket in
            partial + budget.ceiling(for: bucket)
        }
        #expect(sum == 4096)
    }

    @Test func customProfileOverridesDefaults() {
        let budget = ContextBudget(
            totalTokens: 300,
            profile: .custom(buckets: [.system: 100, .tools: 100, .history: 100])
        )

        #expect(budget.ceiling(for: .system) == 100)
        #expect(budget.ceiling(for: .tools) == 100)
        #expect(budget.ceiling(for: .history) == 100)
        #expect(budget.ceiling(for: .outputReserve) == 0)
    }
}
