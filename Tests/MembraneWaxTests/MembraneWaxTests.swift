import Testing
@testable import MembraneWax

@Suite struct MembraneWaxBootstrapTests {
    @Test func moduleImports() {
        #expect(MembraneWaxMarker.moduleName == "MembraneWax")
    }
}
