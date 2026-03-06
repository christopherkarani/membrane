import Testing
@testable import MembraneCore

@Suite struct MembraneCoreBootstrapTests {
    @Test func moduleImports() {
        // Verify core types are accessible from the module.
        #expect(ContextSlice.self is Any.Type)
        #expect(ContextBudget.self is Any.Type)
    }
}
