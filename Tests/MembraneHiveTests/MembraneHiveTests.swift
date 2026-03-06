import Foundation
import Testing
@testable import MembraneHive

@Suite struct MembraneHiveBootstrapTests {
    @Test func moduleImports() {
        #expect(MembraneCheckpointAdapter.self is Any.Type)
    }

    @Test func checkpointEncodingIsByteStableAcrossEncodes() throws {
        let state = makeState()

        let first = try #require(try MembraneCheckpointCodec.encode(state))
        let second = try #require(try MembraneCheckpointCodec.encode(state))

        #expect(first == second)
    }

    @Test func checkpointDecodeRoundTripsToEquivalentNormalizedState() throws {
        let state = makeState()
        let encoded = try #require(try MembraneCheckpointCodec.encode(state))
        let decoded = try #require(try MembraneCheckpointCodec.decode(encoded))

        #expect(decoded == state.normalized())
    }

    @Test func adapterRestoreAndResumePathUsesDecodedState() async throws {
        let adapter = MembraneCheckpointAdapter()
        let state = makeState()
        let encoded = try #require(try MembraneCheckpointCodec.encode(state))

        try await adapter.restore(from: encoded)
        let restored = await adapter.currentState()
        let resumedEncoded = try await adapter.checkpointData()

        #expect(restored == state.normalized())
        #expect(resumedEncoded == encoded)
    }

    @Test func checkpointNormalizationAggregatesUsageCountsAndAppliesBounds() throws {
        let loaded = (0 ..< 300).map { "tool-\($0)" } + ["tool-3", "tool-2", "tool-1"]
        let allowList = (0 ..< 300).map { "allow-\($0)" } + ["allow-3", "allow-2", "allow-1"]
        let cso = (0 ..< 400).map { "cso-\($0)" } + ["cso-1", "cso-2"]
        let pointers = (0 ..< 900).map { "ptr-\($0)" } + ["ptr-1", "ptr-2"]

        let state = MembraneCheckpointState(
            budget: .init(
                totalTokens: 4_096,
                allocations: [
                    .init(bucketID: "history", allocatedTokens: 700),
                    .init(bucketID: "history", allocatedTokens: 300),
                    .init(bucketID: "system", allocatedTokens: 200),
                ]
            ),
            csoSummaries: cso,
            pagingCursor: .init(pageIndex: 1, lastEvictedFrameID: "frame-7"),
            toolState: .init(
                mode: .jit,
                loadedToolNames: loaded,
                allowListToolNames: allowList,
                usageCounts: [
                    .init(toolName: "search", count: 2),
                    .init(toolName: "calc", count: 5),
                    .init(toolName: "search", count: 3),
                    .init(toolName: "calc", count: 1),
                ]
            ),
            pointerIDs: pointers
        )

        let normalized = state.normalized()
        #expect(normalized.toolState.usageCounts == [
            .init(toolName: "calc", count: 6),
            .init(toolName: "search", count: 5),
        ])

        // Bounded deterministic state for checkpoint payload size control.
        #expect(normalized.toolState.loadedToolNames.count == 128)
        #expect(normalized.toolState.allowListToolNames.count == 128)
        #expect(normalized.csoSummaries.count == 256)
        #expect(normalized.pointerIDs.count == 512)
        #expect(normalized.toolState.loadedToolNames == normalized.toolState.loadedToolNames.sorted())
        #expect(normalized.toolState.allowListToolNames == normalized.toolState.allowListToolNames.sorted())
        #expect(normalized.csoSummaries == normalized.csoSummaries.sorted())
        #expect(normalized.pointerIDs == normalized.pointerIDs.sorted())
    }

    @Test func checkpointDecodeRejectsCorruptedPayload() throws {
        let corrupted = Data([0xFF, 0xD8, 0x00, 0x42, 0x13])

        #expect(throws: Error.self) {
            _ = try MembraneCheckpointCodec.decode(corrupted)
        }
    }

    @Test func checkpointDecodeRejectsSchemaMismatchPayload() throws {
        let malformedJSON = """
        {
          "budget": {"totalTokens":"not-a-number","allocations":[]},
          "csoSummaries": [],
          "pagingCursor": null,
          "toolState": {
            "mode":"jit",
            "loadedToolNames": [],
            "allowListToolNames": [],
            "usageCounts":[]
          },
          "pointerIDs":[]
        }
        """.data(using: .utf8)!

        #expect(throws: Error.self) {
            _ = try MembraneCheckpointCodec.decode(malformedJSON)
        }
    }
}

private func makeState() -> MembraneCheckpointState {
    MembraneCheckpointState(
        budget: .init(
            totalTokens: 4_096,
            allocations: [
                .init(bucketID: "history", allocatedTokens: 512),
                .init(bucketID: "system", allocatedTokens: 256),
            ],
            kvBytesPerToken: 4_096,
            kvMemoryBudgetBytes: 128_000_000,
            maxSequenceLength: 2_048
        ),
        csoSummaries: ["decision:B", "decision:A"],
        pagingCursor: .init(pageIndex: 3, lastEvictedFrameID: "frame-9"),
        toolState: .init(
            mode: .jit,
            loadedToolNames: ["weather", "calc", "weather"],
            allowListToolNames: ["weather", "search", "weather"],
            usageCounts: [
                .init(toolName: "search", count: 2),
                .init(toolName: "calc", count: 5),
            ]
        ),
        pointerIDs: ["ptr_b", "ptr_a", "ptr_b"]
    )
}
