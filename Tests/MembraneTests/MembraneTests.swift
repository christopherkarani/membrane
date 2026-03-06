import Testing
@testable import Membrane

@Suite struct MembraneBootstrapTests {
    @Test func moduleImports() {
        #expect(MembranePipeline.self is Any.Type)
    }
}
