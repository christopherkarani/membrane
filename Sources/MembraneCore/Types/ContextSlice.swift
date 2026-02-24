import Foundation

public struct ContextSlice: Sendable, Equatable {
    public let content: String
    public let tokenCount: Int
    public let importance: Double
    public let source: ContextSource
    public let tier: CompressionTier
    public let timestamp: ContinuousClock.Instant

    public init(
        content: String,
        tokenCount: Int,
        importance: Double,
        source: ContextSource,
        tier: CompressionTier,
        timestamp: ContinuousClock.Instant
    ) {
        self.content = content
        self.tokenCount = tokenCount
        self.importance = importance
        self.source = source
        self.tier = tier
        self.timestamp = timestamp
    }
}
