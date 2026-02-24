import Testing
@testable import MembraneConduit

@Suite struct MembraneConduitBootstrapTests {
    @Test func moduleImports() {
        #expect(MembraneConduitMarker.moduleName == "MembraneConduit")
    }
}
