## 0.1.0

- Resolve CLI file and folder arguments against the requested root before
  session, IDE bridge or shared-pool routing; use native Windows separators.
- Fix Windows test fixtures and cover stale endpoint recovery on Windows.
- Recover dead Windows endpoints when connection failure is reported through
  Win32 refusal or the short connection deadline; retain live-owner endpoints.
- Add README development checks and bilingual troubleshooting/removal steps.
- Resolve symlinks in the Dart executable recorded in session, pool and budget
  identities, so a symlinked SDK (for example FVM) and its target match.
- `dana stop` no longer refuses a session whose identity differs; shutdown is
  authenticated by the endpoint token.

- Multi-root pool: the pool registry now follows joins, leaves and LRU
  evictions, so a later project discovers the pool's real root set.
- Multi-root pool: memory-driven eviction waits (up to 10 s) for a removed
  root's memory to be released before deciding to evict another, instead of
  evicting every idle root on a stale sample.
- Retire the PowerShell/C# windows-job backend and native helper sidecars;
  select windows-ffi-job for Windows process-tree ownership.
- Add generated CLI help and release validation/publishing workflows.

- Added a root-scoped persistent analyzer session.
- Added `dana check` fast and full modes.
- Added automatic session startup, `dana status`, and `dana stop`.
- Added analyzer idle waiting and file fingerprint validation.
- Added SDK and project configuration identity validation for endpoints.
- Added concurrent session startup protection and atomic endpoint publication.
- Added Windows analyzer process-tree cleanup during shutdown.
- Added `SessionClient` with disk-backed checks and explicit overlays.
- Added integration coverage for reuse, overlays, errors, shutdown, and
  concurrent startup.
- Added authenticated IDE bridge discovery and reuse with `--reuse-ide
  auto|never|require`; the companion-free proxy implementation lives in
  `analysis_server_proxy`.
- Extended automatic session startup waiting to five minutes so slow analyzer
  plugin initialization does not cause a false `69` connection failure.

