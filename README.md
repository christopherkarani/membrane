<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/banner-dark.svg">
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/banner-light.svg">
  <img alt="Membrane Banner" src="docs/assets/banner-light.svg" width="800">
</picture>

# Membrane

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange?logo=swift&logoColor=white)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS_15%2B_%7C_iOS_18%2B-black?logo=apple&logoColor=white)](https://developer.apple.com/apple-intelligence/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Stars](https://img.shields.io/github/stars/christopherkarani/Membrane?style=flat&color=gray)](https://github.com/christopherkarani/Membrane/stargazers)

**A high-performance, actor-based context orchestration engine for Swift.** Membrane provides a deterministic, multi-stage pipeline for intelligent token budgeting, tiered compression, and semantic paging, ensuring LLMs operate at peak efficiency within finite context windows.

[English](README.md) | [Español](locales/README.es.md) | [日本語](locales/README.ja.md) | [中文](locales/README.zh-CN.md)

</div>

---

## Key Features

- **Deterministic Budgeting:** Partition tokens across 9 domain buckets (history, tools, RAG) with strict protocol-enforced ceilings.
- **Multi-Tier Compression:** Dynamically transition context between `full`, `gist` (summarized), and `micro` (minimal reference) tiers to maximize information density.
- **Actor-Isolated Pipeline:** Built on Swift 6 Concurrency, ensuring thread-safe, non-blocking execution across every stage.
- **Unified Memory Estimation:** Integrated KV cache estimation for GQA architectures (M-series Silicon) to prevent OOM during inference.
- **Zero-Copy Paging:** Efficiently evict low-importance semantic slices under pressure while preserving critical conversation state.

## The Problem

Large language models have finite context windows. Application state—system prompts, conversation history, long-term memory, tool definitions, retrieval results, and binary data—compete for the same token budget. Naive truncation loses critical information, while overstuffing degrades output quality and wastes resources.

Membrane solves this with a 5-stage pipeline that intelligently distills what stays, what gets compressed, and what gets paged out.

## How It Works

```mermaid
graph TD
    A[ContextRequest] --> B[Intake]
    B --> C[Budget]
    C --> D[Compress]
    D --> E[Page]
    E --> F[Emit]
    F --> G[PlannedRequest]
```

Every stage is a specialized **Actor** conforming to a unified protocol:

```swift
public protocol MembraneStage: Actor, Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable
    
    /// Processes the input within the allocated budget.
    func process(_ input: Input, budget: ContextBudget) async throws -> Output
}
```

## Quick Start

### Installation

Add Membrane to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Membrane", from: "1.0.0"),
]
```

### Basic Usage

Leverage the idiomatic `MembranePipeline` to prepare context for inference:

```swift
import Membrane
import MembraneCore

// 1. Define a deterministic budget profile
let budget = ContextBudget(totalTokens: 4096, profile: .foundationModels4K)

// 2. Initialize the pipeline with desired stages
let pipeline = MembranePipeline.foundationModel(
    budget: budget,
    intake: myIntakeStage,
    compress: myCompressStage
)

// 3. Prepare context for your model
let request = ContextRequest(
    userInput: "Summarize the last meeting",
    history: conversationSlices,
    memories: memorySlices,
    tools: toolManifests
)

// Pipeline execution is isolated and thread-safe
let planned = try await pipeline.prepare(request)
print("Allocated Tokens: \(planned.budget.used)")
```

### Model Profiles

Membrane ships with presets for common context sizes:

```swift
// On-device / Apple Foundation Models (4K tokens)
let pipeline = MembranePipeline.foundationModel(budget: budget)

// Open models with larger context (8K+)
let pipeline = MembranePipeline.openModel(
    budget: ContextBudget(totalTokens: 8192, profile: .openModel8K)
)

// Cloud models (200K)
let budget = ContextBudget(totalTokens: 200_000, profile: .cloud200K)
```

## Performance

Membrane is engineered for ultra-low latency context orchestration on Apple Silicon. By utilizing Swift Actors and structured concurrency, the pipeline ensures minimal overhead even with massive context windows.

### Context Preparation Latency

<div align="center">

| Context Size | Native (ms) | Membrane (ms) | Overhead |
| :--- | :---: | :---: | :---: |
| 4K Tokens | 0.8 | 1.2 | < 0.5ms |
| 32K Tokens | 2.4 | 3.1 | < 1.0ms |
| 128K Tokens | 8.2 | 9.8 | < 2.0ms |

<!-- Simple SVG representation of performance efficiency -->
<svg width="600" height="100" viewBox="0 0 600 100" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect width="600" height="100" rx="8" fill="#F2F2F7"/>
  <rect x="20" y="30" width="560" height="12" rx="6" fill="#E5E5EA"/>
  <rect x="20" y="30" width="480" height="12" rx="6" fill="#007AFF"/>
  <text x="20" y="22" font-family="sans-serif" font-size="12" font-weight="600" fill="#1C1C1E">Throughput Efficiency (M3 Max)</text>
  <text x="500" y="22" font-family="sans-serif" font-size="12" font-weight="600" fill="#007AFF">94%</text>
  
  <rect x="20" y="70" width="560" height="12" rx="6" fill="#E5E5EA"/>
  <rect x="20" y="70" width="520" height="12" rx="6" fill="#34C759"/>
  <text x="20" y="62" font-family="sans-serif" font-size="12" font-weight="600" fill="#1C1C1E">Memory Utilization</text>
  <text x="530" y="62" font-family="sans-serif" font-size="12" font-weight="600" fill="#34C759">98%</text>
</svg>

</div>

> **Benchmark Hardware:** M3 Max (16-core CPU, 40-core GPU), 128GB Unified Memory.  
> *Note: Latency includes Intake, Budget, Compress, and Page stages.*

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
