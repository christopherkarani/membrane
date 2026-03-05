# Membrane

**Intelligent context management for LLMs.** Membrane is a composable, actor-based pipeline that compresses, budgets, and pages context so your model sees exactly what matters -- nothing more, nothing less.

---

## The Problem

Large language models have finite context windows. Your application has system prompts, conversation history, long-term memory, tool definitions, retrieval results, and binary data -- all competing for the same token budget. Naively truncating context loses critical information. Stuffing everything in wastes tokens and degrades output quality.

Membrane solves this with a 5-stage pipeline that intelligently decides what stays, what gets compressed, and what gets paged out.

## How It Works

```
ContextRequest
      |
  [ Intake ]     Resolve pointers, load tools, retrieve context
      |
  [ Budget ]     Allocate tokens across 9 domain buckets
      |
  [ Compress ]   Distill history, tier retrieval, prune tools
      |
  [ Page ]       Evict low-importance slices under pressure
      |
  [ Emit ]       Format the final model request
      |
PlannedRequest
```

Every stage is an **Actor** conforming to a single protocol:

```swift
public protocol MembraneStage: Actor, Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable
    func process(_ input: Input, budget: ContextBudget) async throws -> Output
}
```

Stages are composable and optional. Plug in only what you need.

## Quick Start

### Installation

Add Membrane to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Membrane", from: "0.1.0"),
]
```

Then add the targets you need:

```swift
.target(
    name: "MyApp",
    dependencies: [
        "Membrane",          // Core pipeline + stages
        // "MembraneWax",    // Persistent storage via Wax
        // "MembraneHive",   // Checkpoint/restore via Hive
        // "MembraneConduit" // Token counting via Conduit
    ]
)
```

### Basic Usage

```swift
import Membrane
import MembraneCore

// 1. Define a budget
let budget = ContextBudget(totalTokens: 4096, profile: .foundationModels4K)

// 2. Build the pipeline with the stages you need
let pipeline = MembranePipeline.foundationModels(
    budget: budget,
    intake: myIntakeStage,
    compress: myCompressStage
)

// 3. Prepare context for your model
let request = ContextRequest(
    userInput: "Summarize the last meeting",
    history: conversationSlices,
    memories: memorySlices,
    tools: toolManifests,
    toolPlan: .jit(index: myToolIndex),
    retrieval: retrievalSlices,
    pointers: memoryPointers
)

let planned = try await pipeline.prepare(request)
// planned.prompt, planned.systemPrompt, planned.toolPlan, planned.budget
```

### Model Profiles

Membrane ships with presets for common context sizes:

```swift
// On-device / Apple Foundation Models (4K tokens)
let pipeline = MembranePipeline.foundationModels(budget: budget)

// Open models with larger context (8K+)
let pipeline = MembranePipeline.openModel(
    budget: ContextBudget(totalTokens: 8192, profile: .openModel8K)
)

// Cloud models (200K)
let budget = ContextBudget(totalTokens: 200_000, profile: .cloud200K)
```

## Architecture

### The Pipeline

| Stage | Protocol | Input | Output | Purpose |
|-------|----------|-------|--------|---------|
| **Intake** | `IntakeStage` | `ContextRequest` | `ContextWindow` | Resolve pointers, load tools, RAPTOR retrieval |
| **Budget** | `BudgetStage` | `ContextWindow` | `BudgetedContext` | Allocate tokens across domain buckets |
| **Compress** | `CompressStage` | `BudgetedContext` | `CompressedContext` | Distill history, select tiers, prune tools |
| **Page** | `PageStage` | `CompressedContext` | `PagedContext` | Evict low-importance slices |
| **Emit** | `EmitStage` | `PagedContext` | `PlannedRequest` | Format the final prompt |

### Multi-Tier Compression

Context slices are assigned compression tiers with different token multipliers:

| Tier | Multiplier | Use Case |
|------|-----------|----------|
| `full` | 1.0x | Critical content -- system prompts, recent turns |
| `gist` | 0.25x | Summarized content -- older history, background context |
| `micro` | 0.08x | Minimal reference -- entity names, timestamps, topic markers |

### Token Budget Algebra

Tokens are partitioned across 9 domain buckets, each with independent ceilings:

```
system | history | memory | tools | retrieval | toolIO | outputReserve | protocolOverhead | safetyMargin
```

Budget profiles define the allocation strategy. Custom profiles are supported for fine-grained control.

### Built-In Stages

**Intake:**
- `PointerResolver` -- Resolves `MemoryPointer` references to large external data (documents, matrices, images)
- `JITToolLoader` -- Just-in-time tool loading based on relevance
- `RAPTORRetriever` -- Hierarchical tree-based retrieval with budget-aware traversal

**Budget:**
- `UnifiedBudgetAllocator` -- Deterministic bucket allocation across all 9 domains
- `GQAMemoryEstimator` -- KV cache memory estimation for GQA model architectures

**Compress:**
- `CSODistiller` -- Distills conversation into a Context State Object (entities, decisions, facts, open questions)
- `SurrogateTierSelector` -- Multi-tier compression selection for retrieval slices
- `ToolPruner` -- Usage-based tool manifest pruning

**Page:**
- `MemGPTPager` -- MemGPT-inspired eviction of low-importance slices, preserving recent history

### Custom Stages

Implement any stage protocol to add your own logic:

```swift
public actor MyCustomCompressor: CompressStage {
    public func process(
        _ input: BudgetedContext,
        budget: ContextBudget
    ) async throws -> CompressedContext {
        // Your compression logic here
    }
}
```

## Modules

| Module | Purpose | Dependencies |
|--------|---------|-------------|
| **MembraneCore** | Types, protocols, budget algebra | swift-collections |
| **Membrane** | Pipeline orchestrator + built-in stages | MembraneCore |
| **MembraneWax** | Persistent storage via [Wax](https://github.com/christopherkarani/Wax) -- RAPTOR index, pointer store | Membrane, Wax |
| **MembraneHive** | Checkpoint/restore via [Hive](https://github.com/christopherkarani/Hive) -- save and resume pipeline state | Membrane, HiveCore |
| **MembraneConduit** | Token counting via [Conduit](https://github.com/christopherkarani/Conduit) -- accurate token accounting, retry logic | Membrane, Conduit |

## Requirements

- Swift 6.2+
- macOS 26+ / iOS 26+

## Design Principles

- **Actor-isolated** -- Every stage is an Actor. No shared mutable state. Safe by construction.
- **Deterministic** -- Identical inputs produce identical outputs. Sorting is stable, algorithms are seeded.
- **Composable** -- Mix and match stages. Skip what you don't need. Write your own.
- **Bounded** -- Collections have maximum counts. CSO distillation caps entities at 50, decisions at 20, facts at 30. No unbounded growth.
- **Recoverable** -- Errors carry recovery strategies (`compressMore`, `evictAndRetry`, `offloadToDisk`, `fail`), not just messages.

## Part of the AIStack

Membrane is one layer in a larger on-device AI infrastructure:

| Layer | Role |
|-------|------|
| [Conduit](https://github.com/christopherkarani/Conduit) | Multi-provider LLM client with token counting |
| **Membrane** | Context management pipeline |
| [Wax](https://github.com/christopherkarani/Wax) | On-device memory and RAG |
| [Hive](https://github.com/christopherkarani/Hive) | State persistence and checkpointing |

## License

MIT
