# Plan
- [x] Read /Users/chriskarani/.claude/plans/rustling-hugging-treasure.md lines ~1780-2316 to extract definitions/spec for Tasks 8-11 (JITToolLoader, PointerResolver+PointerStore, ToolPruner, SurrogateTierSelector).
- [x] Audit workspace for ToolPlan/ContextWindow/Stage protocols and related tests to understand current type expectations.
- [ ] Map identified contracts to the requested Tasks 8-11 and note interface/architectural risks.
- [ ] Draft recommendations for keeping implementations minimal and deterministic, capturing necessary references.
- [ ] Review RAPTOR retriever/node/tests focusing on deterministic ordering, token budget handling, stop-on-exhaustion semantics.
- [ ] Summarize findings for the user, highlighting regressions or pass-through residual risks.

## Task 19 Feasibility Analysis
- [x] Identify Task 19 goals (speculative scheduler + verifier/rollback) and relevant MLXLMCommon primitives within /Users/chriskarani/CodingProjects/AIStack/Conduit.
- [x] Assess current Conduit architecture for integration points, deterministic constraints, and failure recovery hooks needed for the scheduler/verifier.
- [ ] Draft deterministic architecture proposal covering scheduling flow, verifier/rollback, kill switch/auto-disable, telemetry, and benchmark plan with thresholds.
- [ ] Capture outstanding risks, dependencies, and verification steps for user review.

- [ ] Wax Task 21: List APIs for frame roles, metadata, payload storage, HybridSearch.rrfFusion, canonical encodings/compression, retrieval filtering.
- [ ] Wax Task 21: List APIs for frame roles, metadata, payload storage, HybridSearch.rrfFusion, canonical encodings/compression, retrieval filtering.

## Hive Task 22 Checkpoint API Investigation
- [ ] Inspect /Users/chriskarani/CodingProjects/AIStack/Hive for checkpoint channel/state APIs relevant to MembraneHive Task 22.
- [ ] Trace how schema-declared checkpointed Data channels are defined, persisted, loaded, and restored across files.
- [ ] Compile a response listing concrete file paths, types, and functions addressing the above.

## MembraneConduit Task 20 Token Counting
- [ ] Identify relevant files in /Users/chriskarani/CodingProjects/AIStack/Conduit that define or reference `TokenCounter` plus related token counting APIs.
- [ ] Extract concrete type/protocol signatures, associatedtype constraints, and counting methods (for plain text and message arrays), noting file paths.
- [ ] Confirm interpretations and prepare response listing only file paths and signatures.

## Task 23 Swarm Integration Points
- [ ] Confirm Task 23 requirements (prompt/tool schema boundary, tool-result boundary, agent environment feature gating, task-local toggles, fallback behavior, Hive checkpoint wiring) and assumptions before starting analysis.
- [ ] Research /Users/chriskarani/CodingProjects/AIStack/Swarm for files/types/functions tied to each required boundary and gating point.
- [ ] Document concrete file paths/types/functions that relate to prompt schema, tool results, environment gating, task toggles, fallback flows, and Hive checkpoints.
- [ ] Note where Membrane adapters or internal tools should hook in, clearly indicating insertion spots and integration rationale.
- [ ] Summarize findings for the user including integration recommendations and references to verification steps.

## Swarm Membrane Task 22/23 Audit
- [x] Confirm Task 23 and Task 22 Swarm wiring requirements, including prompt/tool schema boundaries, tool-result routing, gating toggles, fallback behavior, and Hive checkpoint hooks.
- [x] Inspect `Package.swift`, `Sources/Swarm/Agents/Agent.swift`, `Sources/Swarm/DSL/Core/AgentEnvironment.swift`, `Sources/Swarm/Integration/Membrane/*`, `Sources/Swarm/HiveSwarm/HiveAgents.swift`, `Tests/SwarmTests/MembraneIntegrationTests.swift`, and `Tests/HiveSwarmTests/MembraneHiveCheckpointTests.swift` to map implemented wiring.
- [x] Cross-reference implementations against the requirements list and note missing wiring, unimplemented toggles, or absent gating points.
- [x] Draft a concise report outlining implemented requirements, remaining gaps, and suggested next actions.

# Review
- [ ] Pending review notes.

# Lessons
- [ ] Pending lessons (will update if issues arise).

## Phase 6 Audit (Tasks 22-24)
- [ ] Review Phase 6 Task 22-24 requirements and map them to the relevant modules and tests.
- [ ] Audit MembraneHive checkpoint adapter, Wax sources, Conduit bridge foundation, and MembraneTests suites to document current coverage.
- [ ] Enumerate satisfied requirements, remaining gaps, and precise file-level next actions.
- [ ] Summarize findings and prepare response for the user.

## Swarm Agent Init Try Audit
- [ ] Understand where Agent/ReActAgent initializers are invoked inside Swarm tests and note compile failures requiring try (research).
- [ ] Produce deterministic list of failing test file paths plus occurrence counts for missing try handling.
- [ ] Draft safe regex/patch strategy for wrapping initializer calls with try and describe mitigation risks.
