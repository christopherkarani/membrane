import Testing
@testable import Membrane
@testable import MembraneCore

@Suite struct PointerResolverTests {
    @Test func doesNotPointerizeSmallOutput() async throws {
        let store = InMemoryPointerStore()
        let resolver = PointerResolver(store: store, config: .init(pointerThresholdBytes: 32))

        let decision = try await resolver.pointerizeIfNeeded(
            toolName: "tiny_tool",
            output: "small"
        )

        guard case let .inline(text) = decision else {
            #expect(Bool(false), "Expected inline output")
            return
        }

        #expect(text == "small")
    }

    @Test func pointerizesLargeOutputWithStableID() async throws {
        let store = InMemoryPointerStore()
        let resolver = PointerResolver(store: store, config: .init(pointerThresholdBytes: 32))

        let output = String(repeating: "x", count: 128)
        let first = try await resolver.pointerizeIfNeeded(toolName: "big_tool", output: output)
        let second = try await resolver.pointerizeIfNeeded(toolName: "big_tool", output: output)

        guard case let .pointer(pointer1, replacement1) = first else {
            #expect(Bool(false), "Expected pointerized output")
            return
        }

        guard case let .pointer(pointer2, replacement2) = second else {
            #expect(Bool(false), "Expected pointerized output")
            return
        }

        #expect(pointer1.id == pointer2.id)
        #expect(replacement1.contains(pointer1.id))
        #expect(replacement1.contains("resolve_pointer(pointer_id: \"\(pointer1.id)\")"))
        #expect(replacement2.contains(pointer2.id))

        let resolved = try await store.resolve(pointerID: pointer1.id)
        #expect(String(data: resolved, encoding: .utf8) == output)
    }

    @Test func resolveMissingPointerThrowsDeterministicError() async throws {
        let store = InMemoryPointerStore()
        do {
            _ = try await store.resolve(pointerID: "ptr_missing")
            #expect(Bool(false), "Expected pointer resolution failure")
        } catch let error as MembraneError {
            guard case let .pointerResolutionFailed(pointerID) = error else {
                #expect(Bool(false), "Expected pointerResolutionFailed")
                return
            }
            #expect(pointerID == "ptr_missing")
        }
    }
}
