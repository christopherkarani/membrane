import Foundation
import Testing
@testable import MembraneWax
@testable import MembraneCore

@Suite struct MembraneWaxBootstrapTests {
    @Test func moduleImports() {
        #expect(WaxStorageBackend.self is Any.Type)
    }

    @Test func pointerPayloadStoredAsBlobWithMembraneMetadata() async throws {
        let url = makeTempWaxURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = try await WaxStorageBackend.create(at: url)
        defer { Task { try? await backend.close() } }

        let payloadText = String(repeating: "payload-", count: 900)
        let payload = Data(payloadText.utf8)
        let pointer = try await backend.store(
            payload: payload,
            dataType: .binary,
            summary: "oversized payload"
        )

        let resolved = try await backend.resolve(pointerID: pointer.id)
        let meta = try #require(await backend.frameMeta(forPointerID: pointer.id))

        #expect(resolved == payload)
        #expect(meta.role == .blob)
        #expect(meta.metadata?.entries["membrane.kind"] == "pointerPayload")
        #expect(meta.metadata?.entries["membrane.pointer.id"] == pointer.id)
        #expect(meta.metadata?.entries["membrane.pointer.sha256"]?.isEmpty == false)
    }

    @Test func ragSearchExcludesPointerPayloadFramesByDefault() async throws {
        let url = makeTempWaxURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = try await WaxStorageBackend.create(at: url)
        defer { Task { try? await backend.close() } }

        _ = try await backend.storeContextFrame("shared query normal document")
        _ = try await backend.store(
            payload: Data(String(repeating: "shared query pointer payload ", count: 128).utf8),
            dataType: .document,
            summary: "shared query pointer payload"
        )

        let normalOnly = try await backend.searchRAG(
            query: "shared query",
            topK: 20,
            includePointerPayloads: false
        )
        let withPointers = try await backend.searchRAG(
            query: "shared query",
            topK: 20,
            includePointerPayloads: true
        )

        let normalMetas = await backend.frameMetas(frameIDs: normalOnly.results.map(\.frameId))
        let withPointerMetas = await backend.frameMetas(frameIDs: withPointers.results.map(\.frameId))

        #expect(normalMetas.values.allSatisfy { $0.metadata?.entries["membrane.kind"] != "pointerPayload" })
        #expect(withPointerMetas.values.contains { $0.metadata?.entries["membrane.kind"] == "pointerPayload" })
    }

    @Test func raptorNodesPersistAsSyntheticFramesWithStableNodeIDs() async throws {
        let url = makeTempWaxURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = try await WaxStorageBackend.create(at: url)
        defer { Task { try? await backend.close() } }

        let index = await backend.makeRAPTORIndex()
        let node = RAPTORNode(
            id: "node-A",
            parentID: nil,
            depth: 0,
            text: "Alpha node content",
            tokenCount: 32
        )

        let firstFrame = try await index.store(node: node)
        let secondFrame = try await index.store(node: node)
        let meta = try #require(await index.frameMeta(forNodeID: "node-A"))

        #expect(firstFrame == secondFrame)
        #expect(meta.metadata?.entries["membrane.kind"] == "raptorNode")
        #expect(meta.metadata?.entries["membrane.raptor.id"] == "node-A")
    }

    @Test func raptorSearchUsesFusionAndReturnsDeterministicOrder() async throws {
        let url = makeTempWaxURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = try await WaxStorageBackend.create(at: url)
        defer { Task { try? await backend.close() } }

        let index = await backend.makeRAPTORIndex()
        _ = try await index.store(nodes: [
            RAPTORNode(id: "node-2", parentID: nil, depth: 1, text: "query shared beta", tokenCount: 20),
            RAPTORNode(id: "node-1", parentID: nil, depth: 0, text: "query shared alpha", tokenCount: 20),
            RAPTORNode(id: "node-3", parentID: "node-1", depth: 2, text: "query shared gamma", tokenCount: 20),
        ])

        let first = try await index.search(query: "query shared", topK: 3)
        let second = try await index.search(query: "query shared", topK: 3)

        #expect(first.map(\.id) == second.map(\.id))
        #expect(Set(first.map(\.id)) == Set(["node-1", "node-2", "node-3"]))
    }
}

private func makeTempWaxURL() -> URL {
    let filename = "membrane-wax-\(UUID().uuidString).wax"
    return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
}
