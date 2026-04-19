# Dynamic-to-JSON re-encoding via Erlang FFI

**The decision.** When structured output needs to strip the `$schema` key from a sextant-generated JSON Schema or pass a schema as a Dynamic parameter to glopenai, it round-trips through `json.to_string` → `json.parse` → Erlang `json:encode/1` FFI rather than operating directly on the `json.Json` AST.

## Why this and not the alternatives

Gleam's `json.Json` type is opaque — there is no public API to inspect or transform a `json.Json` value (e.g., remove a key from an object, or extract it as a Dynamic for glopenai). Two alternatives were considered:

1. **Build the schema manually without sextant.** Skip `sextant.to_json` entirely and construct the JSON Schema as a `json.object(...)` directly, omitting `$schema` from the start. This works but throws away sextant's type-safe schema generation, requiring manual schema construction that can drift from the validation schema.

2. **Patch gleam_json upstream.** Add a `json.to_dynamic` or `json.remove_key` function. This would be the clean solution but depends on upstream acceptance and a new release cycle.

The FFI round-trip reuses the same `dynamic_to_json` pattern that glopenai already uses in its codec module (`glopenai_codec_ffi.erl`), so it's a proven approach in this codebase's dependency graph. The performance cost (serialise → parse → filter → re-serialise) is negligible because JSON schemas are small and extraction happens once per LLM call, not in a tight loop.

## What it costs

- A second FFI function (`eddie_ffi.dynamic_to_json`) that duplicates `glopenai_codec_ffi.dynamic_to_json`. Both call Erlang's `json:encode/1` but live in different modules.
- The round-trip through string serialisation is conceptually wasteful and can silently reorder object keys (Erlang maps don't preserve insertion order). This doesn't affect correctness — JSON object key order is not significant — but it makes debugging schema output slightly harder.
- The `strip_dollar_schema` function decodes to `Dict(String, Dynamic)`, losing nested type information. If future schema manipulation needs to inspect nested values (e.g., removing `$defs`), the approach would need to be recursive.

## What would make us reconsider

- If `gleam_json` adds a `json.to_dynamic` function or any form of JSON value inspection, the FFI and the round-trip can be eliminated entirely.
- If sextant adds an option to omit the `$schema` key from `to_json` output, `strip_dollar_schema` can be deleted.
- If Eddie needs to do more complex schema transformations (inlining `$defs`, recursive reference resolution for strict mode), the string-based round-trip won't scale and a proper JSON AST walker will be needed.
