import Testing
@testable import MembraneCore

@Suite struct MembraneCoreBootstrapTests {
    @Test func moduleImports() {
        #expect(MembraneCoreMarker.moduleName == "MembraneCore")
    }
}
