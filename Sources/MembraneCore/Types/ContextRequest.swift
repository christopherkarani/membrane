public struct ContextRequest: Sendable {
    public let userInput: String
    public let tools: [ToolManifest]
    public let toolPlan: ToolPlan
    public let history: [ContextSlice]
    public let memories: [ContextSlice]
    public let retrieval: [ContextSlice]
    public let pointers: [MemoryPointer]

    public init(
        userInput: String,
        tools: [ToolManifest] = [],
        toolPlan: ToolPlan = .allowAll,
        history: [ContextSlice] = [],
        memories: [ContextSlice] = [],
        retrieval: [ContextSlice] = [],
        pointers: [MemoryPointer] = []
    ) {
        self.userInput = userInput
        self.tools = tools
        self.toolPlan = toolPlan
        self.history = history
        self.memories = memories
        self.retrieval = retrieval
        self.pointers = pointers
    }
}
