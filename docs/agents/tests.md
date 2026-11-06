# Tests

Three rules apply to every test and harness fixture. The seams they name are
`TracklogAppState`, `CaptureRuntime` and `SQLiteListenStore`.

1. **Drive the real user path.** A new user-visible path gets a composition
   test through the runtime's real entry point, not a fixture that sets the
   state the path would have produced. Build the `TracklogAppState` and real
   store the runtime uses, call what the UI calls, and assert the resulting
   state.
2. **Wait on a signal, bounded.** Wait on a condition the code under test
   signals, with a bound. Never wait a fixed number of `Task.yield()`s or a
   fixed sleep; a loaded runner crosses those budgets. A bounded wait fails
   the test loudly with what was awaited and the last observed value.
3. **No live services.** No test or harness code calls a live service. Use a
   scripted transport or a temporary local store instead. An agent checking how
   a service behaves may make unauthenticated, read-only catalogue calls, and
   lists each one in the PR. Credentials, writes and endpoints for a named user
   account need the owner.
