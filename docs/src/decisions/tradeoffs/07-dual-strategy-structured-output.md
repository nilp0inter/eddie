# Dual-strategy structured output with caller-selected strategy

**The decision.** Structured output extraction exposes two strategies — tool-call and native (`response_format`) — and the caller chooses which to use at each call site, rather than auto-selecting or hardcoding one.

## Why this and not the alternatives

Three designs were considered:

1. **Tool-call only.** The simplest option — every model supports tool calling. But some providers and models handle `response_format` with json_schema more reliably (fewer refusals, better schema adherence, no "I'll call the tool" preamble text). Locking to tool-call would leave performance on the table for those models.

2. **Native only.** Cleaner wire format (no fake tool), but `response_format` with `json_schema` is not universally supported — older or smaller models may ignore the constraint entirely, returning free-form text. Tool-call is the safer fallback.

3. **Auto-detect from model metadata.** Would hide the choice from callers, but model capabilities change across providers and versions. Maintaining a capabilities table or probing the model at runtime adds complexity and a new failure mode for marginal gain.

The dual-strategy approach keeps both paths available with no auto-detection overhead. The caller — who knows which model and provider they're targeting — makes the choice. Both strategies share the same validation pipeline and retry loop, so the maintenance cost of supporting two is low (the divergence is in request building and response routing, about 30 lines each).

## What it costs

- Two code paths through request building and response validation, each with slightly different retry message shapes (tool-call echoes a `RetryPart`; native sends a `UserPart`). A bug in one path can hide if tests only exercise the other.
- Callers must understand the distinction and choose correctly. A wrong choice (e.g., native strategy against a model that ignores `response_format`) produces confusing failures.
- The `Strategy` enum appears in every `extract` call signature, adding a parameter that could feel like boilerplate for projects that always use the same strategy.

## What would make us reconsider

- If OpenAI and all major providers standardise on a single structured output mechanism that works reliably everywhere, the unused strategy becomes dead code.
- If we add streaming structured output (partial validation), the two strategies may diverge enough that the shared pipeline becomes forced — at that point, splitting into separate modules might be cleaner.
- If Eddie gains a model registry or capability system (Phase 6 multi-agent), auto-detection could be revisited since the infrastructure to query model capabilities would already exist.
