import Testing
import Conduit
@testable import MembraneCore
@testable import MembraneConduit

@Suite struct MembraneConduitBootstrapTests {
    @Test func moduleImports() {
        #expect(ConduitTokenAccounting.self is Any.Type)
    }

    @Test func closureBasedTokenAccountingCountsTextAndMessages() async throws {
        let accounting = ConduitTokenAccounting(
            countText: { text in text.count + 10 },
            countMessages: { messages in messages.count * 5 }
        )

        let textCount = try await accounting.countText("abc")
        let messageCount = try await accounting.countMessages([
            .user("hello"),
            .assistant("world"),
        ])

        #expect(textCount == 13)
        #expect(messageCount == 10)
    }

    @Test func tokenCounterBridgeDoesNotLeakAssociatedType() async throws {
        let counter = FakeTokenCounter()
        let model = FakeModelID(rawValue: "fake-model")
        let accounting = ConduitTokenAccounting(counter: counter, model: model)

        let textCount = try await accounting.countText("swift")
        let messageCount = try await accounting.countMessages([
            .system("sys"),
            .user("hello"),
        ])

        #expect(textCount == 5)
        #expect(messageCount == 8)
    }

    @Test func requiresExplicitArchitectureInjection() async throws {
        let accounting = ConduitTokenAccounting(
            countText: { _ in 0 },
            countMessages: { _ in 0 }
        )

        do {
            _ = try ConduitContextWindowRetrier.requireArchitecture(
                tokenAccounting: accounting,
                contextWindowLimit: 4_096,
                architecture: nil,
                distill: { messages, _ in messages }
            )
            #expect(Bool(false), "Expected architectureInfoMissing error")
        } catch let error as ConduitBridgeError {
            #expect(error == .architectureInfoMissing)
        }
    }

    @Test func contextWindowOverflowDistillsAndRetriesOnce() async throws {
        actor Calls {
            private(set) var count = 0
            func increment() { count += 1 }
            func value() -> Int { count }
        }

        let calls = Calls()
        let accounting = ConduitTokenAccounting(
            countText: { _ in 0 },
            countMessages: { messages in
                if messages.count == 4 {
                    return 5_300
                }
                return 3_900
            }
        )
        let retrier = ConduitContextWindowRetrier(
            tokenAccounting: accounting,
            contextWindowLimit: 4_096,
            architecture: ModelArchitectureInfo(
                numLayers: 32,
                numQueryHeads: 32,
                numKVHeads: 8,
                headDim: 128
            ),
            distill: { messages, _ in
                await calls.increment()
                return Array(messages.prefix(2))
            }
        )

        let prepared = try await retrier.prepareMessages([
            .user("u1"),
            .assistant("a1"),
            .user("u2"),
            .assistant("a2"),
        ])

        #expect(prepared.count == 2)
        #expect(await calls.value() == 1)
    }

    @Test func contextWindowOverflowThrowsMeasuredRetryError() async throws {
        actor Calls {
            private(set) var count = 0
            func increment() { count += 1 }
            func value() -> Int { count }
        }

        let calls = Calls()
        let accounting = ConduitTokenAccounting(
            countText: { _ in 0 },
            countMessages: { messages in
                if messages.count == 4 {
                    return 4_700
                }
                return 4_400
            }
        )
        let retrier = ConduitContextWindowRetrier(
            tokenAccounting: accounting,
            contextWindowLimit: 4_096,
            architecture: ModelArchitectureInfo(
                numLayers: 24,
                numQueryHeads: 24,
                numKVHeads: 6,
                headDim: 128
            ),
            distill: { messages, _ in
                await calls.increment()
                return Array(messages.prefix(3))
            }
        )

        do {
            _ = try await retrier.prepareMessages([
                .user("u1"),
                .assistant("a1"),
                .user("u2"),
                .assistant("a2"),
            ])
            #expect(Bool(false), "Expected structured overflow error")
        } catch let error as ConduitBridgeError {
            guard case let .contextWindowOverflow(overflow) = error else {
                #expect(Bool(false), "Expected contextWindowOverflow")
                return
            }

            #expect(await calls.value() == 1)
            #expect(overflow.limit == 4_096)
            #expect(overflow.initialTokens == 4_700)
            #expect(overflow.retriedTokens == 4_400)
            #expect(overflow.initialOverflow == 604)
            #expect(overflow.retriedOverflow == 304)
        }
    }
}

private struct FakeModelID: ModelIdentifying {
    let rawValue: String
    var displayName: String { rawValue }
    var provider: ProviderType { .openAI }
    var description: String { displayName }
}

private struct FakeTokenCounter: TokenCounter {
    typealias ModelID = FakeModelID

    func countTokens(in text: String, for _: FakeModelID) async throws -> TokenCount {
        TokenCount(count: text.count)
    }

    func countTokens(in messages: [Message], for _: FakeModelID) async throws -> TokenCount {
        let totalChars = messages.reduce(0) { partial, message in
            partial + message.content.textValue.count
        }
        return TokenCount(count: totalChars)
    }

    func encode(_: String, for _: FakeModelID) async throws -> [Int] {
        []
    }

    func decode(_: [Int], for _: FakeModelID, skipSpecialTokens _: Bool) async throws -> String {
        ""
    }
}
