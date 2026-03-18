# Starlight

## Build & Test
- `nim c -r tests/test_<name>.nim` — run a single test
- Run all tests: `for f in tests/test_*.nim; do nim c -r "$f"; done`

## Code Style (Nim)
- Multi-line proc signatures: each parameter on its own line, 2-space indent, trailing comma after last param
- Single-line proc signatures are fine if total line ≤ 100 characters
- Never use empty collection literals (`@[]`, `initHashSet()`, etc.) as default parameter values — use `default(T)`
- Single pragma stays on one line: `): ReturnType {.async: (raises: [CatchableError]).} =`
- Prefer `seq[T]` over `openArray[T]` in public API params for consistency (e.g., `extensions`, `middleware`)
- `sets` is not re-exported from `types.nim` — modules that need it import directly
