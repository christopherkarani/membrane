import Conduit
import MembraneCore

/// Type-erased token accounting wrapper for Conduit-backed counting.
///
/// This keeps Conduit `TokenCounter` associated types inside `MembraneConduit`
/// and exposes a stable closure-driven surface to the rest of Membrane.
public struct ConduitTokenAccounting: Sendable {
    public typealias TextCounter = @Sendable (String) async throws -> Int
    public typealias MessageCounter = @Sendable ([Message]) async throws -> Int

    private let textCounter: TextCounter
    private let messageCounter: MessageCounter

    public init(
        countText: @escaping TextCounter,
        countMessages: @escaping MessageCounter
    ) {
        textCounter = countText
        messageCounter = countMessages
    }

    public init<Counter: TokenCounter>(counter: Counter, model: Counter.ModelID) {
        textCounter = { text in
            let count = try await counter.countTokens(in: text, for: model)
            return count.count
        }
        messageCounter = { messages in
            let count = try await counter.countTokens(in: messages, for: model)
            return count.count
        }
    }

    public func countText(_ text: String) async throws -> Int {
        try await textCounter(text)
    }

    public func countMessages(_ messages: [Message]) async throws -> Int {
        try await messageCounter(messages)
    }
}

public struct ConduitContextWindowOverflow: Sendable, Equatable {
    public let limit: Int
    public let initialTokens: Int
    public let retriedTokens: Int

    public var initialOverflow: Int {
        max(0, initialTokens - limit)
    }

    public var retriedOverflow: Int {
        max(0, retriedTokens - limit)
    }

    public init(limit: Int, initialTokens: Int, retriedTokens: Int) {
        self.limit = limit
        self.initialTokens = initialTokens
        self.retriedTokens = retriedTokens
    }
}

public enum ConduitBridgeError: Error, Sendable, Equatable {
    case architectureInfoMissing
    case contextWindowOverflow(ConduitContextWindowOverflow)
}

/// v1 context-window helper:
/// - count candidate messages
/// - if overflow: distill
/// - retry count once
/// - on repeat overflow: throw structured measured overflow error
public struct ConduitContextWindowRetrier: Sendable {
    public typealias Distiller = @Sendable ([Message], ConduitContextWindowOverflow) async throws -> [Message]

    private let tokenAccounting: ConduitTokenAccounting
    private let contextWindowLimit: Int
    private let architecture: ModelArchitectureInfo
    private let distiller: Distiller

    public init(
        tokenAccounting: ConduitTokenAccounting,
        contextWindowLimit: Int,
        architecture: ModelArchitectureInfo,
        distill: @escaping Distiller
    ) {
        self.tokenAccounting = tokenAccounting
        self.contextWindowLimit = max(1, contextWindowLimit)
        self.architecture = architecture
        distiller = distill
    }

    public static func requireArchitecture(
        tokenAccounting: ConduitTokenAccounting,
        contextWindowLimit: Int,
        architecture: ModelArchitectureInfo?,
        distill: @escaping Distiller
    ) throws -> ConduitContextWindowRetrier {
        guard let architecture else {
            throw ConduitBridgeError.architectureInfoMissing
        }
        return ConduitContextWindowRetrier(
            tokenAccounting: tokenAccounting,
            contextWindowLimit: contextWindowLimit,
            architecture: architecture,
            distill: distill
        )
    }

    public func prepareMessages(_ messages: [Message]) async throws -> [Message] {
        _ = architecture // Required explicit injection for v1; no auto-detection path.

        let initialTokens = try await tokenAccounting.countMessages(messages)
        guard initialTokens > contextWindowLimit else {
            return messages
        }

        let initialOverflow = ConduitContextWindowOverflow(
            limit: contextWindowLimit,
            initialTokens: initialTokens,
            retriedTokens: initialTokens
        )
        let distilled = try await distiller(messages, initialOverflow)
        let retriedTokens = try await tokenAccounting.countMessages(distilled)

        guard retriedTokens > contextWindowLimit else {
            return distilled
        }

        throw ConduitBridgeError.contextWindowOverflow(
            ConduitContextWindowOverflow(
                limit: contextWindowLimit,
                initialTokens: initialTokens,
                retriedTokens: retriedTokens
            )
        )
    }
}
