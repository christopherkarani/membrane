import Testing
@testable import MembraneHive

@Suite struct MembraneHiveBootstrapTests {
    @Test func moduleImports() {
        #expect(MembraneHiveMarker.moduleName == "MembraneHive")
    }
}
