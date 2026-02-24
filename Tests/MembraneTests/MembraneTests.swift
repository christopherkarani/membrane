import Testing
@testable import Membrane

@Suite struct MembraneBootstrapTests {
    @Test func moduleImports() {
        #expect(MembraneMarker.moduleName == "Membrane")
    }
}
